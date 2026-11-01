-- The client learns a wafer's depth only when the player feels it bind, never before.

local cfg = Config.lockpick
local Rig = Lockpick.rig

if not cfg.enabled then return end

Mirror.allowProps('tr_lp_')

local POSITIONS = #Rig.wafers
local SET_SLACK = 150 -- µm the client's reading may be off (network, rounding)
local MAX_LOCKS = 2000

local locks = {}    ---@type table<string, table> by plate: the same car keeps the same lock
local lockCount = 0
local sessions = {} ---@type table<integer, table>

local excluded, modelDifficulty = {}, {}
for _, name in ipairs(cfg.excludeModels) do excluded[joaat(name)] = true end
for name, tier in pairs(cfg.modelDifficulty) do modelDifficulty[joaat(name)] = tier end

local function shuffled(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function newLock(tierName)
    local tier = cfg.difficulty[tierName] or cfg.difficulty[cfg.defaultDifficulty]
    local positions = {}
    for i = 1, POSITIONS do positions[i] = i end
    shuffled(positions)

    local lock = { tier = tier, present = {}, depth = {}, order = {}, used = os.time() }
    for i = 1, math.min(tier.wafers, POSITIONS) do
        local pos = positions[i]
        lock.present[pos] = true
        lock.depth[pos] = math.random(Rig.depths)
        lock.order[i] = pos -- positions are shuffled, so this is a random binding order
    end
    return lock
end

local function lockFor(vehicle, class)
    local plate = TR.keys.plate(vehicle)
    local key = plate ~= '' and plate or ('net:%d'):format(NetworkGetNetworkIdFromEntity(vehicle))

    local lock = locks[key]
    if not lock then
        if lockCount >= MAX_LOCKS then
            locks, lockCount = {}, 0
        end
        lock = newLock(modelDifficulty[GetEntityModel(vehicle)] or cfg.classDifficulty[class] or cfg.defaultDifficulty)
        locks[key], lockCount = lock, lockCount + 1
    end

    lock.used = os.time()
    return lock
end

local function binding(s)
    for _, pos in ipairs(s.lock.order) do
        if not s.set[pos] then return pos end
    end
end

local function isLocked(vehicle)
    return GetVehicleDoorLockStatus(vehicle) > 1
end

local function nearVehicle(src, vehicle)
    local ped = GetPlayerPed(src)
    return #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) <= 6.0 and GetVehiclePedIsIn(ped, false) == 0
end

-- Ends the attempt when it's no longer valid.
local function current(src)
    local s = sessions[src]
    if not s then return nil, 'no_session' end

    local reason
    if os.time() - s.started > cfg.timeLimit then
        reason = 'expired'
    elseif not DoesEntityExist(s.vehicle) then
        reason = 'vehicle_gone'
    elseif not nearVehicle(src, s.vehicle) then
        reason = 'moved_away'
    elseif s.locked and not isLocked(s.vehicle) then
        reason = 'unlocked' -- someone opened it another way
    end

    if reason then
        sessions[src] = nil
        return nil, reason
    end

    return s
end

-- A new grip starts from scratch, so requests from an earlier grip are stale.
---@return boolean fresh
local function grip(s, epoch)
    if epoch == 0 then return true end
    if epoch < s.epoch then return false end
    if epoch > s.epoch then
        s.epoch, s.set, s.jammed = epoch, {}, nil
    end
    return true
end

local function alarm(src, s, reason)
    TriggerEvent('tr_minigames:lockpick:alarm', src, NetworkGetNetworkIdFromEntity(s.vehicle), GetEntityCoords(s.vehicle), reason)
    Alerts.send(src, 'lockpickAlarm', s.vehicle)
end

local function snap(src, s)
    sessions[src] = nil

    local lost = false
    if cfg.item and math.random() < cfg.breakChance then
        lost = TR.inventory.removeItem(src, cfg.item, 1)
    end

    Entity(s.vehicle).state:set('tr_lock_jam', os.time() + cfg.jamTime, true)
    alarm(src, s, 'failed')
    TR.log.info('%s snapped a pick in %s', GetPlayerName(src), TR.keys.plate(s.vehicle))
    return lost
end

local function open(src, s)
    sessions[src] = nil

    local vehicle = s.vehicle
    SetVehicleDoorsLocked(vehicle, 1)
    -- Keys scripts that keep the lock in a state bag (qbx) would lock it again on their next sync.
    Entity(vehicle).state:set('doorslockstate', 1, true)

    local chance = cfg.classAlarm[s.class] or cfg.defaultAlarm
    local armed = math.random() < chance
    if armed then alarm(src, s, 'opened') end

    local plate = TR.keys.plate(vehicle)
    TriggerEvent('tr_minigames:lockpick:picked', src, NetworkGetNetworkIdFromEntity(vehicle), plate)
    TR.log.info('%s picked the lock of %s', GetPlayerName(src), plate)
    return armed
end

TR.callback.register('tr_minigames:lockpick:start', function(src, netId, door, class)
    if sessions[src] and current(src) then return false, 'busy' end

    local wanted = door == 'bike' -- a bike's lock is its ignition
    for _, allowed in ipairs(cfg.doors) do wanted = wanted or allowed == door end
    if not wanted then return false, 'no_lock' end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'no_lock' end
    local kind = GetVehicleType(vehicle)
    if not cfg.vehicleTypes[kind] or excluded[GetEntityModel(vehicle)] then return false, 'wrong_vehicle' end
    if (door == 'bike') ~= (kind == 'bike') then return false, 'wrong_vehicle' end
    if not nearVehicle(src, vehicle) then return false, 'too_far' end
    if GetPedInVehicleSeat(vehicle, -1) ~= 0 then return false, 'occupied' end

    local jam = Entity(vehicle).state.tr_lock_jam
    if type(jam) == 'number' and jam > os.time() then return false, 'jammed' end

    local locked = isLocked(vehicle)
    if not (cfg.devMode and TR.player.isAdmin(src)) then
        if not locked then return false, 'not_locked' end
        if TR.keys.hasKeys(src, vehicle) then return false, 'has_keys' end
    end

    if cfg.item and not TR.inventory.hasItem(src, cfg.item) then return false, 'no_item' end

    -- Checked against another player's game, which may take a moment, so the car and player are checked again after.
    class = Vehicles.class(src, vehicle, class)
    if sessions[src] then return false, 'busy' end
    if not DoesEntityExist(vehicle) then return false, 'no_lock' end
    if kind == 'bike' and class == 13 then return false, 'wrong_vehicle' end -- a bicycle

    local lock = lockFor(vehicle, class)
    Mirror.start(src, vehicle, { active = function() return sessions[src] ~= nil end, maxDuration = cfg.timeLimit + 10 })
    sessions[src] = {
        vehicle = vehicle,
        door = door,
        class = class,
        lock = lock,
        locked = locked,
        started = os.time(),
        strikes = 0,
        epoch = 0,
        set = {},
    }

    return true, {
        maxStrikes = cfg.maxStrikes,
        overset = lock.tier.overset / 1000, -- metres
        speed = lock.tier.speed / 1000,     -- metres per second
    }
end, {
    schema = {
        { type = 'integer', min = 1 },
        { type = 'string', max = 8, pattern = '^[%l_]+$' },
        { type = 'integer', min = 0, max = 22 },
    },
    rateLimit = { max = 2, window = 2000 },
})

local function positionArg() return { type = 'integer', min = 1, max = POSITIONS } end
local function epochArg() return { type = 'integer', min = 0, max = 100000 } end

-- Answers 'empty', 'spring', 'binding' (with its depth), 'set' (with its depth) or 'stuck'.
TR.callback.register('tr_minigames:lockpick:probe', function(src, pos, epoch)
    local s, reason = current(src)
    if not s then return false, reason end
    if not grip(s, epoch) then return 'stale' end

    local lock = s.lock
    if not lock.present[pos] then return 'empty' end
    if epoch == 0 then return 'spring' end
    if s.jammed == pos then return 'stuck', lock.depth[pos] end
    if s.set[pos] then return 'set', lock.depth[pos] end
    if not s.jammed and binding(s) == pos then return 'binding', lock.depth[pos] end
    return 'spring'
end, {
    schema = { positionArg(), epochArg() },
    rateLimit = { max = 12, window = 1000 },
})

-- lift: µm
TR.callback.register('tr_minigames:lockpick:set', function(src, pos, epoch, lift)
    local s, reason = current(src)
    if not s then return false, reason end
    if epoch == 0 or epoch ~= s.epoch or s.jammed or binding(s) ~= pos then return 'slipped' end

    local line = math.floor(s.lock.depth[pos] * Rig.depthStep * 1e6 + 0.5)
    if lift < line - SET_SLACK or lift > line + s.lock.tier.overset * 1000 + SET_SLACK then return 'slipped' end

    s.set[pos] = true
    if binding(s) then return 'set' end

    if os.time() - s.started < cfg.minTime then
        TR.guard.flag(src, 'tr_minigames:lockpick: picked faster than possible')
        sessions[src] = nil
        return false, 'try_again'
    end

    return 'open', open(src, s)
end, {
    schema = { positionArg(), epochArg(), { type = 'integer', min = 0, max = 20000 } },
    rateLimit = { max = 4, window = 1000 },
})

TR.callback.register('tr_minigames:lockpick:overset', function(src, pos, epoch)
    local s, reason = current(src)
    if not s then return false, reason end
    if epoch == 0 or epoch ~= s.epoch or not s.lock.present[pos] then return 'nothing' end
    if not (s.set[pos] or binding(s) == pos) then return 'nothing' end

    s.set[pos] = nil
    s.jammed = pos
    return 'jammed'
end, {
    schema = { positionArg(), epochArg() },
    rateLimit = { max = 4, window = 1000 },
})

-- Only ever hurts the player, so the client may report it.
TR.callback.register('tr_minigames:lockpick:bend', function(src)
    local s, reason = current(src)
    if not s then return false, reason end

    s.strikes = s.strikes + 1
    if s.strikes >= cfg.maxStrikes then
        return 'snapped', s.strikes, snap(src, s)
    end
    return 'bent', s.strikes
end, {
    schema = { positionArg() },
    rateLimit = { max = 2, window = 1000 },
})

TR.callback.register('tr_minigames:lockpick:cancel', function(src)
    sessions[src] = nil
    return true
end, {
    schema = {},
    rateLimit = { max = 2, window = 1000 },
})

AddEventHandler('playerDropped', function()
    sessions[source] = nil
end)

-- Event for dispatch scripts: 'tr_minigames:lockpick:alarm' (src, netId, coords, reason: 'failed' or 'opened')

-- Event for logs, XP or police scripts: 'tr_minigames:lockpick:picked' (src, netId, plate)

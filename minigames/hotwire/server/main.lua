-- The server picks which wire does what, counts strikes and decides when the engine starts.

local cfg = Config.hotwire
local Rig = Hotwire.rig

if not cfg.enabled then return end

Mirror.allowProps('tr_hw_')

local sessions = {} ---@type table<integer, table>
local wired = {} ---@type table<integer, { roles: string[], stripped: table<integer, boolean> }>

AddEventHandler('entityRemoved', function(entity) wired[entity] = nil end)

local ROLES = { 'battery', 'ignition', 'starter', 'accessory' } -- every other wire is dead
local BIKE_ROLES = { 'battery', 'ignition', 'accessory' } -- the starter is the button on the bars
local READINGS = { battery = 'steady', ignition = 'pulse', starter = 'flicker', accessory = 'dim', dead = 'none' }
local WIRES = #Rig.wires

local excluded = {}
for _, name in ipairs(cfg.excludeModels) do excluded[joaat(name)] = true end

local function shuffledRoles(bike)
    local count, names = bike and #Rig.bike.wires or WIRES, bike and BIKE_ROLES or ROLES
    local order = {}
    for i = 1, count do order[i] = i end

    for i = count, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end

    local roles = {}
    for i = 1, count do roles[order[i]] = names[i] or 'dead' end
    return roles
end

-- A bike has fewer wires than the schema allows.
local function known(s, ...)
    for _, wire in ipairs({ ... }) do
        if not s.roles[wire] then return false end
    end
    return true
end

---@return integer? vehicle the vehicle src is driving, if netId points at it
local function drivenVehicle(src, netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return end
    if GetPedInVehicleSeat(vehicle, -1) ~= GetPlayerPed(src) then return end

    return vehicle
end

-- Ends the attempt when it's no longer valid.
local function current(src, needCover)
    local s = sessions[src]
    if not s then return nil, 'no_session' end

    local reason
    if os.time() - s.started > cfg.timeLimit then
        reason = 'expired'
    elseif not DoesEntityExist(s.vehicle) or GetPedInVehicleSeat(s.vehicle, -1) ~= GetPlayerPed(src) then
        reason = 'left_vehicle'
    elseif needCover and not s.coverOff then
        return nil, 'no_session'
    end

    if reason then
        sessions[src] = nil
        return nil, reason
    end

    return s
end

local function fail(src, s)
    sessions[src] = nil

    local broke = false
    if cfg.item and math.random() < cfg.breakChance then
        broke = TR.inventory.removeItem(src, cfg.item, 1)
    end

    Alerts.send(src, 'hotwireAlarm', s.vehicle)
    TR.log.info('%s failed to hotwire %s', GetPlayerName(src), TR.keys.plate(s.vehicle))
    return broke
end

-- Returns reason (or 'failed'), strikes, itemBroke.
local function strike(src, s, reason)
    s.strikes = s.strikes + 1

    if s.strikes >= cfg.maxStrikes then
        return 'failed', s.strikes, fail(src, s)
    end

    return reason, s.strikes
end

local function wireArg()
    return { type = 'integer', min = 1, max = WIRES }
end

TR.callback.register('tr_minigames:hotwire:start', function(src, netId, class)
    if sessions[src] and current(src) then return false, 'busy' end

    local vehicle = drivenVehicle(src, netId)
    if not vehicle then return false, 'not_driver' end
    local kind = GetVehicleType(vehicle)
    if not cfg.vehicleTypes[kind] or excluded[GetEntityModel(vehicle)] then return false, 'wrong_vehicle' end
    local bike = kind == 'bike'

    local state = Entity(vehicle).state

    if not (cfg.devMode and TR.player.isAdmin(src)) then
        if TR.keys.hasKeys(src, vehicle) then return false, 'has_keys' end
        if GetIsVehicleEngineRunning(vehicle) then
            return false, state.tr_hotwired and 'already_hotwired' or 'engine_running'
        end
    end

    -- Turned off after a hotwire: it has to be wired again.
    if state.tr_hotwired and not GetIsVehicleEngineRunning(vehicle) then state:set('tr_hotwired', false, true) end

    if cfg.item and not TR.inventory.hasItem(src, cfg.item) then return false, 'no_item' end

    if bike then
        -- Checked against another player's game, which may take a moment, so the bike and rider are checked again.
        class = Vehicles.class(src, vehicle, class)
        if sessions[src] then return false, 'busy' end
        if not drivenVehicle(src, netId) then return false, 'not_driver' end
        if class == 13 then return false, 'wrong_vehicle' end -- a bicycle
    end

    local crank = cfg.crank
    local opens = math.random(crank.earliest, crank.latest)
    -- The cover stays off once unscrewed, and after a hotwire the wires stay found and stripped.
    local coverOff = state.tr_hotwire_cover == true
    local before = coverOff and wired[vehicle] or nil
    local roles = before and before.roles or shuffledRoles(bike)
    local stripped, wires, twisted = {}, {}, nil
    if before then
        local battery, ignition
        for wire in pairs(before.stripped) do
            stripped[wire] = true
            wires[#wires + 1] = { wire = wire, reading = READINGS[roles[wire]] }
            if roles[wire] == 'battery' then battery = wire elseif roles[wire] == 'ignition' then ignition = wire end
        end
        twisted = battery and ignition and { battery, ignition } or nil
    end

    Mirror.start(src, vehicle, { active = function() return sessions[src] ~= nil end, maxDuration = cfg.timeLimit + 10 })
    sessions[src] = {
        vehicle = vehicle,
        bike = bike,
        started = os.time(),
        roles = roles,
        rewire = coverOff,
        rewired = before ~= nil,
        stripped = stripped,
        strikes = 0,
        coverOff = coverOff,
        twisted = twisted ~= nil,
        crank = { opens = opens, closes = opens + crank.window },
    }

    return true, {
        crank = sessions[src].crank,
        maxStrikes = cfg.maxStrikes,
        coverOff = coverOff,
        wires = wires,
        twisted = twisted, -- { battery wire, ignition wire }
    }
end, {
    schema = { { type = 'integer', min = 1 }, { type = 'integer', min = 0, max = 22 } },
    rateLimit = { max = 2, window = 2000 },
})

TR.callback.register('tr_minigames:hotwire:cover', function(src)
    local s, reason = current(src)
    if not s then return false, reason end

    s.coverOff = true
    Entity(s.vehicle).state:set('tr_hotwire_cover', true, true)
    return true
end, {
    schema = {},
    rateLimit = { max = 2, window = 1000 },
})

TR.callback.register('tr_minigames:hotwire:probe', function(src, wire)
    local s, reason = current(src, true)
    if not s then return false, reason end
    if not known(s, wire) then return nil, 'invalid_args' end

    return true, READINGS[s.roles[wire]]
end, {
    schema = { wireArg() },
    rateLimit = { max = 6, window = 1000 },
})

TR.callback.register('tr_minigames:hotwire:strip', function(src, wire)
    local s, reason = current(src, true)
    if not s then return false, reason end
    if not known(s, wire) then return nil, 'invalid_args' end

    s.stripped[wire] = true
    return true
end, {
    schema = { wireArg() },
    rateLimit = { max = 4, window = 1000 },
})

-- Only ever hurts the player, so the client may report it.
TR.callback.register('tr_minigames:hotwire:nick', function(src)
    local s, reason = current(src, true)
    if not s then return false, reason end

    return strike(src, s, 'nicked')
end, {
    schema = { wireArg() },
    rateLimit = { max = 2, window = 1000 },
})

TR.callback.register('tr_minigames:hotwire:twist', function(src, a, b)
    local s, reason = current(src, true)
    if not s then return false, reason end
    if a == b or s.twisted or not known(s, a, b) or not (s.stripped[a] and s.stripped[b]) then return 'nothing' end

    local ra, rb = s.roles[a], s.roles[b]

    if (ra == 'battery' and rb == 'ignition') or (ra == 'ignition' and rb == 'battery') then
        s.twisted = true
        return 'twisted'
    end

    if ra == 'battery' or rb == 'battery' then
        return strike(src, s, 'short')
    end

    return 'nothing'
end, {
    schema = { wireArg(), wireArg() },
    rateLimit = { max = 3, window = 1000 },
})

local function crank(src, s, held)
    if held > s.crank.closes then return strike(src, s, 'overcrank') end
    if held < s.crank.opens then return 'sputter' end

    local minTime = s.rewired and cfg.minReconnectTime or s.rewire and cfg.minRewireTime
        or s.bike and cfg.minBikeTime or cfg.minTime
    if os.time() - s.started < minTime then
        TR.guard.flag(src, 'tr_minigames:hotwire: finished faster than possible')
        sessions[src] = nil
        return false, 'try_again'
    end

    sessions[src] = nil
    wired[s.vehicle] = { roles = s.roles, stripped = s.stripped }
    Entity(s.vehicle).state:set('tr_hotwired', true, true)
    -- Only some keys scripts (zyke_vehiclekeys) can run an engine without keys; the rest keep it off, so give them
    if cfg.giveKeys or not TR.keys.startEngine(src, s.vehicle) then
        TR.keys.giveKeys(src, s.vehicle)
    end
    Alerts.send(src, 'hotwired', s.vehicle)
    TR.log.info('%s hotwired %s', GetPlayerName(src), TR.keys.plate(s.vehicle))

    return 'started'
end

TR.callback.register('tr_minigames:hotwire:crank', function(src, wire, held)
    local s, reason = current(src, true)
    if not s then return false, reason end
    if s.bike or not s.twisted or not s.stripped[wire] or s.roles[wire] ~= 'starter' then return 'nothing' end

    return crank(src, s, held)
end, {
    schema = { wireArg(), { type = 'integer', min = 0, max = 60000 } },
    rateLimit = { max = 3, window = 1000 },
})

-- A bike's start button, held for `held` ms.
TR.callback.register('tr_minigames:hotwire:button', function(src, held)
    local s, reason = current(src, true)
    if not s then return false, reason end
    if not s.bike or not s.twisted then return 'nothing' end

    return crank(src, s, held)
end, {
    schema = { { type = 'integer', min = 0, max = 60000 } },
    rateLimit = { max = 3, window = 1000 },
})

TR.callback.register('tr_minigames:hotwire:cancel', function(src)
    sessions[src] = nil
    return true
end, {
    schema = {},
    rateLimit = { max = 2, window = 1000 },
})

AddEventHandler('playerDropped', function()
    sessions[source] = nil
end)

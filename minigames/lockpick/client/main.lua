local cfg = Config.lockpick
local function t(key, vars) return TR.locale.t('lockpick.' .. key, vars) end

if not cfg.enabled then return end

local busy = false

local function notify(key, kind)
    TR.notify.send({ description = t(key), type = kind or 'error' })
end

-- The alarm natives need control of the car.
local function soundAlarm(vehicle)
    CreateThread(function()
        NetworkRequestControlOfEntity(vehicle)
        local deadline = GetGameTimer() + 1000
        while not NetworkHasControlOfEntity(vehicle) and GetGameTimer() < deadline do Wait(0) end

        SetVehicleAlarm(vehicle, true)
        SetVehicleAlarmTimeLeft(vehicle, cfg.alarmTime * 1000)
        StartVehicleAlarm(vehicle)
    end)
end

local function armAlarm(vehicle, door)
    CreateThread(function()
        local index = Lockpick.doorIndex[door] -- nil on a bike: it goes off when someone gets on
        local deadline = GetGameTimer() + 60000

        while GetGameTimer() < deadline and DoesEntityExist(vehicle) do
            local opened = index and GetVehicleDoorAngleRatio(vehicle, index) > 0.05
            if opened or GetVehiclePedIsIn(PlayerPedId(), false) == vehicle then
                return soundAlarm(vehicle)
            end
            Wait(100)
        end
    end)
end

local function pick(vehicle, door)
    if busy then return end
    if TR.cache.vehicle then return end -- in a car the same key hotwires instead

    if not vehicle then vehicle, door = Lockpick.nearestLock() end
    if not vehicle then return notify('no_lock') end

    busy = true
    TR.ui.textui.hide('tr_minigames:lockpick')
    local ok, data = TR.callback.await('tr_minigames:lockpick:start', VehToNet(vehicle), door, GetVehicleClass(vehicle))

    if not ok then
        busy = false
        return notify(data or 'try_again')
    end

    local result, extra = Lockpick.run(vehicle, door, data)
    busy = false

    if result == 'opened' then
        SetVehicleDoorsLocked(vehicle, 1)
        notify('opened', 'success')
        if extra then armAlarm(vehicle, door) end
    elseif result == 'failed' then
        soundAlarm(vehicle)
        notify('failed')
        if extra then notify('item_lost', 'warning') end
    elseif result == 'cancelled' then
        notify('cancelled', 'info')
    else
        notify(result or 'try_again')
    end
end

RegisterCommand(cfg.command, function() pick() end, false)
RegisterKeyMapping(cfg.command, t('keybind'), 'keyboard', cfg.key)

-- For an inventory's "use" action, e.g. ox_inventory: client = { export = 'tr_minigames.lockpick' }
exports('lockpick', function() pick() end)

if cfg.prompt then
    CreateThread(function()
        local PROMPT = 'tr_minigames:lockpick'

        while true do
            local vehicle
            if not busy and not TR.cache.vehicle then
                vehicle = Lockpick.nearestLock()
                if vehicle and (not Lockpick.isLocked(vehicle) or (cfg.item and not TR.inventory.hasItem(cfg.item))) then
                    vehicle = nil
                end
            end

            if vehicle then
                TR.ui.textui.show(PROMPT, {
                    key = TR.ui.keyOf(cfg.command, cfg.key),
                    text = t('prompt_pick'),
                    sub = cfg.item and t('prompt_item') or nil,
                })
            else
                TR.ui.textui.hide(PROMPT)
            end

            Wait(250)
        end
    end)
end

-- Not on tr_core's own interaction, which would offer it at every car.
local hasTarget, targetSystem = pcall(TR.system, 'target')
if cfg.target and hasTarget and targetSystem ~= 'tr_core' then
    local bones = {}
    for _, door in ipairs(cfg.doors) do bones[#bones + 1] = 'handle_' .. door end
    if cfg.vehicleTypes.bike then
        bones[#bones + 1] = 'forks_u'
        bones[#bones + 1] = 'handlebars'
    end

    TR.target.addGlobalVehicle({
        {
            name = 'tr_minigames:lockpick',
            label = t('target'),
            icon = 'fa-solid fa-key',
            distance = cfg.reach + 0.5,
            bones = bones,
            items = cfg.item or nil,
            canInteract = function(entity)
                if busy or not Lockpick.isLocked(entity) then return false end
                return not IsThisModelABike(GetEntityModel(entity)) or Lockpick.isBike(entity)
            end,
            onSelect = function() pick() end,
        },
    })
end

-- /lockpick_rig <back> <up> [out]: prints a line for Config.lockpick.vehicleFits
if cfg.devMode then
    RegisterCommand('lockpick_rig', function(_, args)
        local game = Lockpick.current
        local vehicle, door
        if game then
            vehicle, door = game.vehicle, game.door
        else
            vehicle, door = Lockpick.nearestLock()
        end
        if not vehicle then return print('[lockpick] stand at the door or bike you want to fit') end

        local model = Lockpick.modelName(vehicle)
        if door == 'bike' then
            local fit, source = Lockpick.fit(model)
            return print(('[lockpick] %s uses the %s fit; move it with /lockpick_fitall %s'):format(model,
                fit.x and source or 'bone', model))
        end

        local back, up, out = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])

        if back and up then
            local current = Lockpick.fit(model)
            if current.x then current = Config.lockpick.rig end
            Lockpick.liveFits[model] = { back = back, up = up, out = out or current.out }
            if game then game.scene:setPlacement(Lockpick.placement(vehicle, door)) end
        end

        local fit, source = Lockpick.fit(model)
        print(('[lockpick] %s uses the %s fit'):format(model, source))
        if fit.x then
            return print('[lockpick] it is a measured fit; adjust it with /lockpick_fitall ' .. model)
        end
        local line = ("['%s'] = { back = %.3f, up = %.3f, out = %.3f },"):format(model, fit.back, fit.up, fit.out)
        print('[lockpick] add to Config.lockpick.vehicleFits: ' .. line)
        TR.notify.send({ description = line, type = 'info' })
    end, false)

    -- /lockpick_cam <x> <y> <z> <targetX> <targetY> <targetZ>
    RegisterCommand('lockpick_cam', function(_, args)
        local n = {}
        for i = 1, 6 do n[i] = tonumber(args[i]) end

        local game = Lockpick.current
        local cam = game and game.cam or cfg.camera
        if n[6] then
            cam.pos, cam.target = vec3(n[1], n[2], n[3]), vec3(n[4], n[5], n[6])
            if game then game.scene:moveCamera(cam.pos, cam.target) end
        end

        print(('[lockpick] camera %.3f %.3f %.3f -> %.3f %.3f %.3f'):format(cam.pos.x, cam.pos.y, cam.pos.z,
            cam.target.x, cam.target.y, cam.target.z))
    end, false)
end

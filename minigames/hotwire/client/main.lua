local cfg = Config.hotwire
local function t(key, vars) return TR.locale.t('hotwire.' .. key, vars) end

if not cfg.enabled then return end

local busy = false

local function notify(key, kind)
    TR.notify.send({ description = t(key), type = kind or 'error' })
end

local function hotwire()
    if busy then return end

    local vehicle = TR.cache.vehicle
    if not vehicle then return end -- on foot the same key picks door locks
    local bike = Hotwire.isBike(vehicle)
    if TR.cache.seat ~= -1 then return notify(bike and 'not_rider' or 'not_driver') end
    if not Hotwire.canTry(vehicle) or (bike and not Hotwire.bikeFit(vehicle)) then return notify('wrong_vehicle') end

    busy = true
    TR.ui.textui.hide('tr_minigames:hotwire')
    local ok, data = TR.callback.await('tr_minigames:hotwire:start', VehToNet(vehicle), GetVehicleClass(vehicle))

    if not ok then
        busy = false
        return notify(data or 'try_again')
    end

    local result, extra = Hotwire.run(vehicle, data)
    busy = false

    if result == 'started' then
        notify('started', 'success')
    elseif result == 'failed' then
        notify('failed')
        if extra then notify('item_broke', 'warning') end
    elseif result == 'cancelled' then
        notify('cancelled', 'info')
    else
        notify(result or 'try_again')
    end
end

RegisterCommand(cfg.command, hotwire, false)
RegisterKeyMapping(cfg.command, t('keybind'), 'keyboard', cfg.key)

-- A hotwired car whose engine was turned off can't be started either: it has to be wired again.
CreateThread(function()
    local PROMPT = 'tr_minigames:hotwire'

    while true do
        local vehicle = TR.cache.vehicle

        if vehicle and TR.cache.seat == -1 and not busy and not GetIsVehicleEngineRunning(vehicle)
            and not TR.keys.hasKeys(vehicle) and Hotwire.canTry(vehicle) then
            TR.ui.textui.show(PROMPT, {
                key = TR.ui.keyOf(cfg.command, cfg.key),
                text = t(Hotwire.isBike(vehicle) and 'prompt_hotwire_bike' or 'prompt_hotwire'),
                sub = cfg.item and t('prompt_item') or nil,
            })
        else
            TR.ui.textui.hide(PROMPT)
        end

        Wait(250)
    end
end)

-- /hotwire_rig <x> <y> <z> [pitch]: prints a line for Config.hotwire.vehicleFits, or on a bike for bikeFits (the
-- switch block's middle in the bike's space)
if cfg.devMode then
    local function vec(p) return ('vec3(%.4f, %.4f, %.4f)'):format(p.x, p.y, p.z) end

    local function printBikeFit(vehicle)
        local model = Hotwire.modelName(vehicle)
        local fit, source = Hotwire.bikeFit(vehicle)
        if not fit then return print('[hotwire] ' .. model .. ' has no hbgrip_r bone') end

        local function cam(c) return ('{ %s, %s }'):format(vec(c[1]), vec(c[2])) end
        local swing = fit.swing and (' swing = %.1f,'):format(fit.swing) or ''
        local line = ("['%s'] = { switch = %s, bar = %s,%s open = %s, wires = %s, button = %s },"):format(
            model, vec(fit.switch), vec(fit.bar), swing, cam(fit.open), cam(fit.wires), cam(fit.button))
        print(('[hotwire] %s uses the %s fit; a changed fit takes effect from the next attempt'):format(model, source))
        print('[hotwire] add to Config.hotwire.bikeFits: ' .. line)
        TR.notify.send({ description = line, type = 'info' })
    end

    local function setBikeFit(vehicle, key, value)
        local model = Hotwire.modelName(vehicle)
        cfg.bikeFits[model] = cfg.bikeFits[model] or {}
        cfg.bikeFits[model][key] = value
    end

    RegisterCommand('hotwire_rig', function(_, args)
        local vehicle = TR.cache.vehicle
        if not vehicle then return print('[hotwire] sit in the car you want to fit') end

        if Hotwire.isBike(vehicle) then
            local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
            if Hotwire.bikeFit(vehicle) and x and y and z then setBikeFit(vehicle, 'switch', vec3(x, y, z)) end
            return printBikeFit(vehicle)
        end

        local model, class = Hotwire.modelName(vehicle), GetVehicleClass(vehicle)
        local current = Hotwire.fit(model, class)
        local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])

        if x and y and z then
            cfg.vehicleFits[model] = { offset = vec3(x, y, z), pitch = tonumber(args[4]) or current.pitch }
            local game = Hotwire.current
            if game then game.scene:setPlacement(Hotwire.placement(vehicle)) end
        end

        local fit, source = Hotwire.fit(model, class)
        local o = fit.offset
        print(('[hotwire] %s (class %d) uses the %s fit'):format(model, class, source))
        local line = ("['%s'] = { offset = vec3(%.3f, %.3f, %.3f), pitch = %.1f },"):format(model, o.x, o.y, o.z, fit.pitch)
        print('[hotwire] add to Config.hotwire.vehicleFits: ' .. line)
        TR.notify.send({ description = line, type = 'info' })
    end, false)

    -- /hotwire_cam <x> <y> <z> <targetX> <targetY> <targetZ>; on a bike in the switch block's space (rig.lua `bike`)
    RegisterCommand('hotwire_cam', function(_, args)
        local n = {}
        for i = 1, 6 do n[i] = tonumber(args[i]) end

        local game = Hotwire.current
        local wires = game and game.stage ~= 'screws'

        local vehicle = TR.cache.vehicle
        if vehicle and Hotwire.isBike(vehicle) then
            if n[6] then
                local cam = { vec3(n[1], n[2], n[3]), vec3(n[4], n[5], n[6]) }
                local stage = game and game.stage
                setBikeFit(vehicle, (stage == 'open' or stage == 'button') and stage or 'wires', cam)
                if game and game.bike then game.scene:moveCamera(game:toRig(cam[1]), game:toRig(cam[2])) end
            end
            return printBikeFit(vehicle)
        end
        local cam = cfg.camera

        if n[6] then
            local pos, target = vec3(n[1], n[2], n[3]), vec3(n[4], n[5], n[6])
            if wires then cam.wiresPos, cam.wiresTarget = pos, target else cam.pos, cam.target = pos, target end
            if game then game.scene:moveCamera(pos, target) end
        end

        local pos, target = wires and cam.wiresPos or cam.pos, wires and cam.wiresTarget or cam.target
        print(('[hotwire] %s camera %.3f %.3f %.3f -> %.3f %.3f %.3f'):format(wires and 'wires' or 'cover',
            pos.x, pos.y, pos.z, target.x, target.y, target.z))
    end, false)
end

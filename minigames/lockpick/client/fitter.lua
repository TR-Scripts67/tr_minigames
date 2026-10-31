-- /lockpick_fitall [all | review | bikes [all] | <model>] (dev mode; saving needs an admin)

local cfg = Config.lockpick

if not cfg.enabled or not cfg.devMode then return end

local Rig = Lockpick.rig
local DOOR = 'dside_f'
local LEVER_OPEN, SHUTTER_OPEN = 52.0, 88.0 -- as when picking
local WIDE = 4.0                            -- times further out
local KEY = { save = 191, skip = 194, stop = 200, wide = 26, reset = 45 }

-- No door lock, or not worth fitting. Asking for a model by name still fits it.
local SKIP_CLASS = {
    [8] = true, [13] = true, [14] = true, [15] = true, [16] = true, [21] = true,
    [10] = true, [11] = true, [17] = true, [18] = true, [19] = true, [20] = true, [22] = true,
}

local running = false
local scene
local spawned
local home

local function say(text)
    print('[lockpick fit] ' .. text)
end

Lockpick.dev = Lockpick.dev or {}
local Dev = Lockpick.dev

function Dev.carModels(keep)
    return DevCars.models(SKIP_CLASS, function(model) return keep(model, Lockpick.savedFits[model]) end)
end

local function bikeModels(keep)
    local list = {}
    for _, name in ipairs(GetAllVehicleModels()) do
        local model = name:lower()
        if Lockpick.isBikeModel(joaat(model)) and keep(model) then list[#list + 1] = model end
    end
    table.sort(list)
    return list
end

-- arg: nil (not fitted yet), 'all', 'review', 'bikes' (then nil or 'all') or a model
local function models(arg, more)
    if arg == 'bikes' then return bikeModels(function(model) return more == 'all' or not Lockpick.savedFits[model] end) end
    if arg == 'review' then return Dev.carModels(function(_, saved) return saved and saved.check end) end
    if arg and arg ~= 'all' then return { arg:lower() } end
    return Dev.carModels(function(_, saved) return arg == 'all' or not saved end)
end

local function cleanup()
    TR.ui.hud.hide()
    if spawned and DoesEntityExist(spawned) then DeleteEntity(spawned) end
    if scene then scene:destroy() end
    spawned, scene = nil, nil

    local ped = PlayerPedId()
    if home then SetEntityCoordsNoOffset(ped, home.x, home.y, home.z, false, false, false) end
    home = nil
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
end

Dev.spawn = DevCars.spawn

function Dev.spawnTool(scene, housing)
    scene:spawn('bezel', housing or 'tr_lp_bezel')
    scene:spawn('plug', 'tr_lp_plug')
    scene:spawn('shutter', 'tr_lp_shutter', Rig.shutterHinge, Mat.axis('x', SHUTTER_OPEN))
    scene:spawn('lishi', 'tr_lp_lishi')
    scene:spawn('pick', 'tr_lp_lishi_pick', vec3(0.0, Rig.wafers[#Rig.wafers] - Rig.tip.y, 0.0))
    local swing = Mat.axis('z', -LEVER_OPEN)
    scene:spawn('lever', 'tr_lp_lishi_lever', Rig.leverPivot - Mat.apply(swing, Rig.leverPivot), swing)
end

-- What saving keeps: a bike nobody moved yet keeps where its bones put the lock.
local function shownFit(vehicle, model)
    if Lockpick.isBike(vehicle) then
        local fit, source = Lockpick.bikeFit(vehicle)
        if fit then return fit, source end
    end
    return Lockpick.fit(model)
end

local function hud(vehicle, model, index, total, wide)
    local fit, source = shownFit(vehicle, model)
    local function mm(v) return ('%d mm'):format(math.floor(v * 1000 + 0.5)) end

    local tools = { { label = model, progress = ('%d / %d'):format(index, total), active = true } }
    if fit.x then
        tools[2] = { label = 'X', progress = mm(fit.x) }
        tools[3] = { label = 'Y', progress = mm(fit.y) }
        tools[4] = { label = 'Z', progress = mm(fit.z) }
    else
        tools[2] = { label = 'Back', progress = mm(fit.back) }
        tools[3] = { label = 'Up', progress = mm(fit.up) }
        tools[4] = { label = 'Out', progress = mm(fit.out) }
    end
    tools[5] = { label = 'Fit', progress = fit.check and (source .. ', check') or fit.auto and (source .. ', auto') or source }

    TR.ui.hud.set({
        tools = tools,
        hint = {
            text = 'Fit the lock',
            keys = {
                { key = 'Arrows', label = 'Move' },
                { key = 'Q/E', label = 'Out / in' },
                { key = 'Scroll', label = 'Tilt' },
                { key = 'Z/X', label = 'Tilt left / right' },
                { key = 'Shift', label = '1 mm' },
                { key = 'C', label = wide and 'Close view' or 'Wide view' },
                { key = 'R', label = 'Undo' },
                { key = 'Enter', label = 'Save' },
                { key = '⌫', label = 'Skip' },
                { key = 'Esc', label = 'Stop' },
            },
        },
    })
end

local function fitOne(scene, vehicle, model, door, cam, index, total)
    local wide = false

    local function place()
        local offset, pitch, yaw = Lockpick.placement(vehicle, door)
        if offset then scene:setPlacement(offset, pitch, yaw) end
    end

    local function aim()
        if wide then scene:moveCamera(cam.pos * WIDE, cam.target) else scene:moveCamera(cam.pos, cam.target) end
    end

    while true do
        DisableAllControlActions(0)

        local moved = Lockpick.nudged(model, vehicle, true)
        if moved then
            Lockpick.liveFits[model] = moved
            place()
        end

        if IsDisabledControlJustPressed(0, KEY.reset) then
            Lockpick.liveFits[model] = nil
            place()
        elseif IsDisabledControlJustPressed(0, KEY.wide) then
            wide = not wide
            aim()
        elseif IsDisabledControlJustPressed(0, KEY.save) then
            local fit = {}
            for k, v in pairs((shownFit(vehicle, model))) do fit[k] = v end
            fit.check = nil
            local ok, err = TR.callback.await('tr_minigames:lockpick:saveFit', model, fit)
            if ok then
                Lockpick.savedFits[model] = fit
                Lockpick.liveFits[model] = nil
                say('saved ' .. model)
                return 'saved'
            end
            TR.notify.send({ description = 'Not saved: ' .. tostring(err), type = 'error' })
        elseif IsDisabledControlJustPressed(0, KEY.skip) then
            Lockpick.liveFits[model] = nil
            return 'skipped'
        elseif IsDisabledControlJustPressed(0, KEY.stop) then
            Lockpick.liveFits[model] = nil
            return 'stop'
        end

        scene:update()
        scene:torch(cfg.torch or 0.6)
        hud(vehicle, model, index, total, wide)
        Wait(0)
    end
end

local function run(arg, more)
    local list = models(arg, more)
    if #list == 0 then
        return say(arg == 'bikes' and 'every bike already has a saved fit (use /lockpick_fitall bikes all to redo them)'
            or 'every car already has a saved fit (use /lockpick_fitall all to redo them)')
    end
    say(('%d cars to fit'):format(#list))

    local ped = PlayerPedId()
    local at, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    home = at
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityVisible(ped, false, false)

    local saved, skipped = 0, 0

    for index, wanted in ipairs(list) do
        local vehicle = Dev.spawn(wanted, at, heading)
        spawned = vehicle

        if not vehicle then
            say(wanted .. ': could not load the model, skipped')
            skipped = skipped + 1
        else
            local model = Lockpick.modelName(vehicle)
            local door = Lockpick.isBike(vehicle) and 'bike' or DOOR
            local offset, pitch, yaw = Lockpick.placement(vehicle, door)

            if not offset then
                say(model .. (door == 'bike' and ': no forks_u or handlebars bone, skipped' or ': no driver door handle or door bone, skipped'))
                skipped = skipped + 1
            else
                local housing, cam = 'tr_lp_bezel', cfg.camera
                if door == 'bike' then housing, cam = Rig.ignition.model, Lockpick.bikeCamera() end

                if not scene then
                    scene = Scene.new(vehicle, offset, pitch, yaw)
                    Dev.spawnTool(scene, housing)
                    scene:createCamera(cam.pos, cam.target, cam.fov)
                else
                    scene.entity = vehicle
                    scene:setPlacement(offset, pitch, yaw)
                    if scene:get('bezel').model ~= housing then scene:spawn('bezel', housing) end
                    scene:moveCamera(cam.pos, cam.target)
                end

                local result = fitOne(scene, vehicle, model, door, cam, index, #list)
                if result == 'saved' then saved = saved + 1 else skipped = skipped + 1 end

                if result == 'stop' then
                    DeleteEntity(vehicle)
                    spawned = nil
                    break
                end
            end

            if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
            spawned = nil
        end
    end

    cleanup()
    say(('done: %d saved, %d skipped'):format(saved, skipped))
end

RegisterCommand('lockpick_fitall', function(_, args)
    if running then return say('already fitting') end
    if Lockpick.current then return say('finish picking first') end
    if TR.cache.vehicle then return say('get out of the car first') end

    running = true
    CreateThread(function()
        local ok, err = pcall(run, args[1], args[2])
        running = false
        if not ok then
            cleanup()
            say('stopped by an error: ' .. tostring(err))
        end
    end)
end, false)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and running then cleanup() end
end)

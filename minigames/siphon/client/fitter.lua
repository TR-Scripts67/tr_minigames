-- /filler_fitall [all | review | <model>] (dev mode; saving needs an admin)
-- Models with the same body share a fit; fitting a copy by name makes it a fit of its own.

local cfg = Config.siphon

if not cfg.enabled or not cfg.devMode then return end

local FILLER = Siphon.rig.filler
local KEY = { save = 191, skip = 194, stop = 200, wide = 26, reset = 45, side = 23 }
local CLOSE = { pos = vec3(0.10, -0.40, 0.08), target = vec3(0.0, 0.0, 0.0), fov = 40.0 }
local WIDE = 5.0 -- times further out

local running = false
local scene
local spawned
local home

local function say(text)
    print('[filler fit] ' .. text)
end

Siphon.dev = Siphon.dev or {}
local Dev = Siphon.dev

-- the native needs game build 3258
function Dev.isElectric(hash)
    local ok, electric = pcall(GetIsVehicleElectric, hash)
    return ok and electric == true
end

-- Can't be siphoned, or not worth fitting. Asking for a model by name still fits it.
local SKIP_CLASS = { [10] = true, [11] = true, [17] = true, [18] = true, [19] = true, [20] = true, [22] = true }
for class, blocked in pairs(cfg.blockedClasses) do SKIP_CLASS[class] = blocked or SKIP_CLASS[class] end

-- Copies of another model's fit are left out: they follow that model.
function Dev.carModels(keep)
    return DevCars.models(SKIP_CLASS, function(model)
        local saved = Siphon.savedFits[model]
        return not Dev.isElectric(joaat(model)) and not (saved and saved.from) and keep(model, saved)
    end)
end

-- Same-size models (baller4, baller5) share a body: its size to the mm is the signature.

local sigs = {} -- model -> signature

-- nil if the model doesn't load
function Dev.signature(model)
    if sigs[model] then return sigs[model] end
    local saved = Siphon.savedFits[model]
    if saved and saved.sig then
        sigs[model] = saved.sig
        return saved.sig
    end
    local hash = joaat(model)
    if not IsModelInCdimage(hash) then return end
    local loaded = HasModelLoaded(hash)
    if not loaded then
        RequestModel(hash)
        local deadline = GetGameTimer() + 3000
        while not HasModelLoaded(hash) do
            if GetGameTimer() > deadline then return end
            Wait(0)
        end
    end
    local min, max = GetModelDimensions(hash)
    if not loaded then SetModelAsNoLongerNeeded(hash) end
    local function mm(v) return math.floor(v * 1000 + 0.5) end
    sigs[model] = ('%d,%d,%d/%d,%d,%d'):format(mm(min.x), mm(min.y), mm(min.z), mm(max.x), mm(max.y), mm(max.z))
    return sigs[model]
end

function Dev.twin(model)
    local sig = Dev.signature(model)
    if not sig then return end
    local names = {}
    for other in pairs(Siphon.savedFits) do names[#names + 1] = other end
    table.sort(names)
    for _, other in ipairs(names) do
        local fit = Siphon.savedFits[other]
        if other ~= model and not fit.from and Dev.signature(other) == sig then return other, fit end
    end
end

function Dev.save(model, fit)
    fit.sig = Dev.signature(model)
    local ok, err = TR.callback.await('tr_minigames:siphon:saveFit', model, fit)
    if ok then Siphon.savedFits[model] = fit end
    return ok, err
end

local function copyOf(source, fit)
    return { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw, auto = fit.auto, check = fit.check,
        both = fit.both, from = source }
end

function Dev.updateCopies(source)
    local fit, n = Siphon.savedFits[source], 0
    for model, saved in pairs(Siphon.savedFits) do
        if saved.from == source and Dev.save(model, copyOf(source, fit)) then n = n + 1 end
    end
    if n > 0 then say(('  and %d model%s with the same body'):format(n, n == 1 and '' or 's')) end
    return n
end

function Dev.copyTwin(model)
    local source, fit = Dev.twin(model)
    if source and Dev.save(model, copyOf(source, fit)) then
        say(('%s has the same body as %s: copied its fit'):format(model, source))
        return source
    end
end

function Dev.bone(vehicle)
    for _, name in ipairs({ 'petroltank', 'petroltank_l', 'petroltank_r' }) do
        local bone = GetEntityBoneIndexByName(vehicle, name)
        if bone ~= -1 then return GetWorldPositionOfEntityBone(vehicle, bone), name end
    end
end

function Dev.spawnFiller(s)
    s:spawn('filler', 'tr_sf_filler')
    s:spawn('flap', 'tr_sf_flap', FILLER.flapHinge)
    s:spawn('fuelcap', 'tr_sf_fuelcap', FILLER.cap.seat, FILLER.cap.rot)
end

-- arg: nil (not fitted yet), 'all', 'review' or a model
local function models(arg)
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

local function hud(model, index, total, fit, source, wide, both)
    local function mm(v) return ('%d mm'):format(math.floor(v * 1000 + 0.5)) end
    local function deg(v) return ('%.1f°'):format(v) end

    TR.ui.hud.set({
        tools = {
            { label = model, progress = ('%d / %d'):format(index, total), active = true },
            { label = 'X', progress = mm(fit.x) },
            { label = 'Y', progress = mm(fit.y) },
            { label = 'Z', progress = mm(fit.z) },
            { label = 'Tilt', progress = deg(fit.pitch) },
            { label = 'Turn', progress = deg(fit.yaw) },
            { label = 'Fit', progress = fit.check and (source .. ', check') or fit.auto and (source .. ', auto') or source },
            { label = 'Sides', progress = both and 'both (mirrored)' or 'this one' },
        },
        hint = {
            text = 'Fit the filler on the car\'s fuel door',
            keys = {
                { key = 'WASD', label = 'Move (hold)' },
                { key = 'Q/E', label = 'Out / in' },
                { key = 'Scroll', label = 'Tilt' },
                { key = 'Z/X', label = 'Turn' },
                { key = 'Shift', label = 'Fine' },
                { key = 'F', label = 'Other side' },
                { key = 'C', label = wide and 'Close view' or 'Wide view' },
                { key = 'R', label = 'Undo' },
                { key = 'Enter', label = 'Save' },
                { key = '⌫', label = 'Skip' },
                { key = 'Esc', label = 'Stop' },
            },
        },
    })
end

local function fitOne(vehicle, model, index, total)
    local wide = false
    local side = -1 -- F flips it

    local function shown()
        local fit, source = Siphon.fit(model)
        if fit then return fit, source end
        local bone = Dev.bone(vehicle)
        return Siphon.guessFit(vehicle, side), bone and 'bone' or 'guess'
    end

    local function place()
        local fit = shown()
        if fit then scene:setPlacement(vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw) end
    end

    local function aim()
        if wide then scene:moveCamera(CLOSE.pos * WIDE, CLOSE.target) else scene:moveCamera(CLOSE.pos, CLOSE.target) end
    end

    place()
    aim()

    while true do
        DisableAllControlActions(0)
        HideHudAndRadarThisFrame()

        local moved = Siphon.nudged(model, vehicle, side)
        if moved then
            Siphon.liveFits[model] = moved
            place()
        end

        if IsDisabledControlJustPressed(0, KEY.reset) then
            Siphon.liveFits[model] = nil
            place()
        elseif IsDisabledControlJustPressed(0, KEY.side) then
            local fit = Siphon.fit(model)
            if fit then
                Siphon.liveFits[model] = Siphon.mirrorFit(fit)
            else
                side = -side
                if Dev.bone(vehicle) then
                    -- The bone fixes the guess's side: mirror it into a live fit instead.
                    local guess = shown()
                    if guess then Siphon.liveFits[model] = Siphon.mirrorFit(guess) end
                end
            end
            place()
        elseif IsDisabledControlJustPressed(0, KEY.wide) then
            wide = not wide
            aim()
        elseif IsDisabledControlJustPressed(0, KEY.save) then
            local fit = shown()
            if fit then
                local saving = { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw, both = not Dev.bone(vehicle) or nil }
                local ok, err = Dev.save(model, saving)
                if ok then
                    Siphon.liveFits[model] = nil
                    say('saved ' .. model)
                    Dev.updateCopies(model)
                    return 'saved'
                end
                TR.notify.send({ description = 'Not saved: ' .. tostring(err), type = 'error' })
            end
        elseif IsDisabledControlJustPressed(0, KEY.skip) then
            Siphon.liveFits[model] = nil
            return 'skipped'
        elseif IsDisabledControlJustPressed(0, KEY.stop) then
            Siphon.liveFits[model] = nil
            return 'stop'
        end

        local bone = Dev.bone(vehicle)
        if bone then
            DrawMarker(28, bone.x, bone.y, bone.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.006, 0.006, 0.006, 255, 220, 0, 200,
                false, false, 2, false, nil, nil, false)
        end

        scene:update()
        scene:torch(0.6)
        local fit, source = shown()
        if fit then hud(model, index, total, fit, source, wide, not bone) end
        Wait(0)
    end
end

local function run(arg)
    local list = models(arg)
    if #list == 0 then return say('every car already has a saved fit (use /filler_fitall all to redo them)') end
    say(('%d cars to fit'):format(#list))

    local ped = PlayerPedId()
    local at, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    home = at
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityVisible(ped, false, false)

    local saved, skipped = 0, 0

    -- Asked for one model by name: fit that one, even if a model with the same body has a fit.
    local named = arg and arg ~= 'all' and arg ~= 'review'
    local copied = 0

    for index, wanted in ipairs(list) do
        local twin = not named and not Siphon.savedFits[wanted] and Dev.copyTwin(wanted)
        local vehicle = not twin and DevCars.spawn(wanted, at, heading) or nil
        spawned = vehicle

        if twin then
            copied = copied + 1
        elseif not vehicle then
            say(wanted .. ': could not load the model, skipped')
            skipped = skipped + 1
        else
            local model = Siphon.modelName(vehicle)
            local start = Siphon.fit(model) or Siphon.guessFit(vehicle, -1)

            if not start then
                say(model .. ': no petroltank bone and no rear wheel to guess from, skipped')
                skipped = skipped + 1
            else
                local offset = vec3(start.x, start.y, start.z)
                if not scene then
                    scene = Scene.new(vehicle, offset, start.pitch, start.yaw)
                    Dev.spawnFiller(scene)
                    scene:createCamera(CLOSE.pos, CLOSE.target, CLOSE.fov)
                else
                    scene.entity = vehicle
                    scene:setPlacement(offset, start.pitch, start.yaw)
                end

                local result = fitOne(vehicle, model, index, #list)
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
    say(('done: %d saved, %d copied from a model with the same body, %d skipped'):format(saved, copied, skipped))
end

RegisterCommand('filler_fitall', function(_, args)
    if running then return say('already fitting') end
    if Siphon.current then return say('finish siphoning first') end
    if TR.cache.vehicle then return say('get out of the car first') end

    running = true
    CreateThread(function()
        local ok, err = pcall(run, args[1])
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

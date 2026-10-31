-- Lock space: origin at the plug's face, +Y into the door, +Z up.

local cfg = Config.lockpick

Lockpick = Lockpick or {}

local SIDE = { dside_f = -1, dside_r = -1, pside_f = 1, pside_r = 1 }
Lockpick.doorIndex = { dside_f = 0, pside_f = 1, dside_r = 2, pside_r = 3 }

function Lockpick.modelName(vehicle)
    return GetEntityArchetypeName(vehicle):lower()
end

-- live: being tuned right now, until a restart. saved: from minigames/lockpick/fits.json.
-- A fit is { back, up, out } from the handle's bone, or { x, y, z, pitch, yaw } in the car's space (measured).
Lockpick.liveFits = {}
Lockpick.savedFits = {}
Lockpick.fitDoor = 'dside_f' -- the door measured fits are for

---@return table fit, string source
function Lockpick.fit(model)
    if Lockpick.liveFits[model] then return Lockpick.liveFits[model], 'live' end
    if Lockpick.savedFits[model] then return Lockpick.savedFits[model], 'saved' end
    if cfg.vehicleFits[model] then return cfg.vehicleFits[model], 'config' end
    return cfg.rig, 'default'
end

CreateThread(function()
    -- On a restart the server side may not be up yet: ask again a few times.
    for _ = 1, 5 do
        local fits = TR.callback.await('tr_minigames:lockpick:fits')
        if type(fits) == 'table' then
            for model, fit in pairs(fits) do Lockpick.savedFits[model] = fit end
            return
        end
        Wait(3000)
    end
end)

RegisterNetEvent('tr_minigames:lockpick:fitSaved', function(model, fit)
    Lockpick.savedFits[model] = fit
end)

-- 5 mm a press, 1 mm with Shift held
local NUDGE = {
    { 174, 'back', -1 }, { 175, 'back', 1 }, -- arrow left / right: along the door
    { 172, 'up', 1 }, { 173, 'up', -1 },     -- arrow up / down
    { 44, 'out', 1 }, { 38, 'out', -1 },     -- Q / E: out of / into the door
}

-- 1 degree a press, a quarter with Shift held
local TURN = {
    { 111, 'pitch', -1 }, { 112, 'pitch', 1 }, -- numpad 8 / 5: tip the face up / down
    { 108, 'yaw', -1 }, { 109, 'yaw', 1 },     -- numpad 4 / 6: turn the face forward / back
}
-- Fitters only: picking uses the wheel to move the pick.
local WHEEL = {
    { 241, 'pitch', -1 }, { 242, 'pitch', 1 }, -- scroll up / down: tip the face up / down
    { 20, 'yaw', -1 }, { 73, 'yaw', 1 },       -- Z / X: tilt the face left (to the car's front) / right
}

local function mm(v) return math.floor(v * 1000 + 0.5) / 1000 end

local function fitAxes(fit)
    return Mat.mul(Mat.axis('z', fit.yaw), Mat.axis('x', fit.pitch))
end

local function startFit(model, vehicle)
    return vehicle and Lockpick.isBike(vehicle) and Lockpick.bikeFit(vehicle) or Lockpick.fit(model)
end

function Lockpick.nudged(model, vehicle, wheel)
    local fine = IsDisabledControlPressed(0, 21)
    local tilt = vehicle and Lockpick.isBike(vehicle) and 90.0 or 60.0 -- a yoke's face looks up
    local turns = TURN
    if wheel then
        turns = {}
        for _, n in ipairs(TURN) do turns[#turns + 1] = n end
        for _, n in ipairs(WHEEL) do turns[#turns + 1] = n end
    end
    for _, n in ipairs(turns) do
        if IsDisabledControlJustPressed(0, n[1]) then
            local fit = startFit(model, vehicle)
            if not fit.x then
                -- Not `vehicle and placement(...)`: that would keep only the first of its results.
                if not vehicle then return end
                local offset, pitch, yaw = Lockpick.placement(vehicle, Lockpick.fitDoor)
                if not offset then return end
                fit = { x = offset.x, y = offset.y, z = offset.z, pitch = pitch, yaw = yaw }
            end
            local turned = { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw }
            turned[n[2]] = turned[n[2]] + n[3] * (fine and 0.25 or 1.0)
            turned.pitch = Clamp(turned.pitch, -tilt, tilt)
            return turned
        end
    end

    local step = fine and 0.001 or 0.005
    for _, n in ipairs(NUDGE) do
        if IsDisabledControlJustPressed(0, n[1]) then
            local fit = startFit(model, vehicle)

            if fit.x then
                -- In lock space: back is +X (towards the car's rear on the driver's side), out is -Y.
                local axes = fitAxes(fit)
                local dir = n[2] == 'back' and axes.x or n[2] == 'up' and axes.z or axes.y * -1.0
                local p = vec3(fit.x, fit.y, fit.z) + dir * (n[3] * step)
                return { x = p.x, y = p.y, z = p.z, pitch = fit.pitch, yaw = fit.yaw }
            end

            local moved = { back = fit.back, up = fit.up, out = fit.out }
            moved[n[2]] = mm(moved[n[2]] + n[3] * step)
            return moved
        end
    end
end

local function handle(vehicle, door)
    local spot = Scene.boneOffset(vehicle, 'handle_' .. door)
    if spot then return spot end

    local hinge = Scene.boneOffset(vehicle, 'door_' .. door)
    if hinge then return hinge + vec3(0.0, -0.62, 0.05) end -- most of the way back, below the window
end

local function facing(door)
    local yaw = SIDE[door] < 0 and -90.0 or 90.0
    return yaw, Mat.axis('z', yaw)
end

---@return vector3? hit, vector3? normal both in vehicle space
local function surface(vehicle, spot, into)
    local from = GetOffsetFromEntityInWorldCoords(vehicle, spot.x - into.x * 0.25, spot.y - into.y * 0.25, spot.z - into.z * 0.25)
    local to = GetOffsetFromEntityInWorldCoords(vehicle, spot.x + into.x * 0.2, spot.y + into.y * 0.2, spot.z + into.z * 0.2)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 2, PlayerPedId(), 7)
    local _, hit, at, normal, entity = GetShapeTestResult(ray)
    if not hit or entity ~= vehicle then return end

    local rot = Mat.fromEuler(GetEntityRotation(vehicle, 2))
    return GetOffsetFromEntityGivenWorldCoords(vehicle, at.x, at.y, at.z), Vec.unrotate(rot, normal)
end

---@return vector3? offset, number pitch, number yaw
function Lockpick.placement(vehicle, door)
    if door == 'bike' then return Lockpick.bikePlacement(vehicle) end
    local fit = Lockpick.fit(Lockpick.modelName(vehicle))
    if fit.x and door == Lockpick.fitDoor then return vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw end
    if fit.x then fit = cfg.rig end

    local spot = handle(vehicle, door)
    if not spot then return end
    local yaw, rot = facing(door)
    local pitch = 0.0
    spot = spot + vec3(0.0, -fit.back, fit.up)

    local hit, normal = surface(vehicle, spot, rot.y)
    if hit then
        local depth = Vec.dot(hit - spot, rot.y)
        if math.abs(depth) < 0.12 then spot = spot + rot.y * depth end

        if cfg.followSurface then
            local into = Vec.normalize(normal * -1.0)
            pitch = Clamp(math.deg(math.asin(Clamp(into.z, -1.0, 1.0))), -25.0, 25.0)
            local turned = math.deg(math.atan(-into.x, into.y))
            yaw = yaw + Clamp(math.deg(AngleDelta(math.rad(yaw), math.rad(turned))), -30.0, 30.0)
        end
    end

    rot = Mat.mul(Mat.axis('z', yaw), Mat.axis('x', pitch))
    return spot - rot.y * fit.out, pitch, yaw
end

function Lockpick.lockCoords(vehicle, door)
    local fit = Lockpick.fit(Lockpick.modelName(vehicle))
    if fit.x and door == Lockpick.fitDoor then return GetOffsetFromEntityInWorldCoords(vehicle, fit.x, fit.y, fit.z) end
    if fit.x then fit = cfg.rig end

    local spot = handle(vehicle, door)
    if not spot then return end

    return GetOffsetFromEntityInWorldCoords(vehicle, spot.x, spot.y - fit.back, spot.z + fit.up)
end

local function outside(vehicle, door, coords)
    local lock = Lockpick.lockCoords(vehicle, door)
    if not lock then return false end

    local me = GetOffsetFromEntityGivenWorldCoords(vehicle, coords.x, coords.y, coords.z)
    local at = GetOffsetFromEntityGivenWorldCoords(vehicle, lock.x, lock.y, lock.z)
    return (me.x - at.x) * SIDE[door] > 0.1, #(coords - lock)
end

---@return integer? vehicle, string? door, number? distance
function Lockpick.nearestDoor()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local best, bestVehicle, bestDoor = cfg.reach, nil, nil

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(GetEntityCoords(vehicle) - coords) < 6.0 then
            for _, door in ipairs(cfg.doors) do
                local isOutside, distance = outside(vehicle, door, coords)
                if isOutside and distance < best then
                    best, bestVehicle, bestDoor = distance, vehicle, door
                end
            end
        end
    end

    return bestVehicle, bestDoor, bestVehicle and best or nil
end

-- lock status 2 and up: locked, locked for players, breakable, ...
function Lockpick.isLocked(vehicle)
    return GetVehicleDoorLockStatus(vehicle) > 1
end

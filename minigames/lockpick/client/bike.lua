-- Bike lock space: as a door's, with +Y into the ignition. Stock bikes have measured fits (dev/tools/trbike/fit.py).

local cfg = Config.lockpick
local Rig = Lockpick.rig

-- Every bike has its ignition on the top yoke. In lock space, from the bike's left: it mirrors to the player's side.
local CAMERA = { pos = vec3(-0.136, -0.269, 0.071), target = vec3(0.0, -0.045, 0.002), fov = 46.0 }

-- From the forks_u bone, for bikes without a measured fit.
local YOKE_AHEAD = 0.028 -- in front of the steering axis
local YOKE_HEIGHT = 0.131 -- up the axis, when the bike has no grips
local RAKE = 25.0 -- degrees, when it has no front wheel
local STAND_OUT = 0.6 -- from the lock to the player, across the bike: in front of the lock is the tank or the seat

local excluded = {}
for _, name in ipairs(cfg.excludeModels) do excluded[joaat(name)] = true end

-- Not by class 8 alone: police bikes are class 18. Bicycles (13) have no ignition.
function Lockpick.isBikeModel(model)
    return IsThisModelABike(model) and GetVehicleClassFromName(model) ~= 13 and not excluded[model]
end

function Lockpick.isBike(vehicle) return Lockpick.isBikeModel(GetEntityModel(vehicle)) end

local function head(vehicle)
    return Scene.boneOffset(vehicle, 'forks_u') or Scene.boneOffset(vehicle, 'handlebars')
end

local function grips(vehicle)
    local left, right = Scene.boneOffset(vehicle, 'hbgrip_l'), Scene.boneOffset(vehicle, 'hbgrip_r')
    if left and right then return left, right end
end

local function facing(into)
    local yaw = (math.abs(into.x) + math.abs(into.y)) > 1e-6 and math.deg(math.atan(-into.x, into.y)) or 0.0
    return math.deg(math.asin(Clamp(into.z, -1.0, 1.0))), yaw
end

local function fromBones(vehicle)
    local at = head(vehicle)
    if not at then return end

    local wheel = Scene.boneOffset(vehicle, 'wheel_lf')
    local axis = wheel and Vec.normalize(at - wheel) or vec3(0.0, -math.sin(math.rad(RAKE)), math.cos(math.rad(RAKE)))
    local ahead = Vec.normalize(vec3(0.0, 1.0, 0.0) - axis * axis.y)
    local left, right = grips(vehicle)
    local height = left and Vec.dot((left + right) * 0.5 - at, axis) or YOKE_HEIGHT
    local pitch, yaw = facing(axis * -1.0)
    return at + axis * height + ahead * YOKE_AHEAD, pitch, yaw
end

---A measured fit, else one from the bones: a bike has no door fit. With the bars straight, as fits are measured.
---@return table? fit, string? source
function Lockpick.bikeFit(vehicle)
    local model = Lockpick.modelName(vehicle)
    local fit, source = Lockpick.fit(model)
    if fit.x then return fit, source end

    local offset, pitch, yaw = fromBones(vehicle)
    if offset then return { x = offset.x, y = offset.y, z = offset.z, pitch = pitch, yaw = yaw }, 'bones' end
end

-- The top yoke turns with the bars about the steering axis (the lock's -Y) through forks_u, and straight bars have
-- their grips square across the bike. Only the position follows: a scene can't roll.
local function steered(vehicle, offset, pitch, yaw)
    local pivot = head(vehicle)
    local left, right = grips(vehicle)
    if not (pivot and left) then return offset end

    local axis = Mat.mul(Mat.axis('z', yaw), Mat.axis('x', pitch)).y * -1.0
    local function frame(across)
        local x = Vec.normalize(across - axis * Vec.dot(across, axis))
        return { x = x, y = Vec.cross(axis, x), z = axis }
    end
    local straight, now = frame(vec3(1.0, 0.0, 0.0)), frame(right - left)
    return pivot + Mat.apply(now, Vec.unrotate(straight, offset - pivot))
end

---@return vector3? offset, number pitch, number yaw
function Lockpick.bikePlacement(vehicle)
    local fit = Lockpick.bikeFit(vehicle)
    if not fit then return end

    return steered(vehicle, vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw), fit.pitch, fit.yaw
end

local function reach(vehicle, coords)
    local offset = Lockpick.bikePlacement(vehicle)
    if not offset then return end
    return #(coords - GetOffsetFromEntityInWorldCoords(vehicle, offset.x, offset.y, offset.z))
end

---@return integer? vehicle, number? distance
function Lockpick.nearestBike()
    local coords = GetEntityCoords(PlayerPedId())
    local best, bestVehicle = cfg.reach, nil

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(GetEntityCoords(vehicle) - coords) < 4.0 and Lockpick.isBike(vehicle) then
            local distance = reach(vehicle, coords)
            if distance and distance < best then best, bestVehicle = distance, vehicle end
        end
    end

    return bestVehicle, bestVehicle and best or nil
end

---A car door or a bike, whichever lock is nearer.
---@return integer? vehicle, string? door, number? distance
function Lockpick.nearestLock()
    local vehicle, door, distance = Lockpick.nearestDoor()
    if not cfg.vehicleTypes.bike then return vehicle, door, distance end

    local bike, bikeDistance = Lockpick.nearestBike()
    if bike and not (vehicle and distance < bikeDistance) then return bike, 'bike', bikeDistance end
    return vehicle, door, distance
end

---@param onRight? boolean the player is on the bike's right: the view mirrors
function Lockpick.bikeCamera(onRight)
    if not onRight then return CAMERA end
    return { pos = vec3(-CAMERA.pos.x, CAMERA.pos.y, CAMERA.pos.z), target = vec3(-CAMERA.target.x, CAMERA.target.y, CAMERA.target.z), fov = CAMERA.fov }
end

---The housing, the camera and where the player stands: beside the lock, on the side they came from.
---@return string housing, table camera, vector3 stand in the bike's space
function Lockpick.bikeView(vehicle, offset)
    local me = GetEntityCoords(PlayerPedId())
    local onRight = GetOffsetFromEntityGivenWorldCoords(vehicle, me.x, me.y, me.z).x > offset.x

    return Rig.ignition.model, Lockpick.bikeCamera(onRight), offset + vec3(onRight and STAND_OUT or -STAND_OUT, 0.0, 0.0)
end

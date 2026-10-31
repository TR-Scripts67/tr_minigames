-- The right switch block (rig.lua `bike`) on each bike: measured on the stock ones (bikes.lua), from the grip bone on
-- the rest.

local cfg = Config.hotwire

local excluded = {}
for _, name in ipairs(cfg.excludeModels) do excluded[joaat(name)] = true end

-- Not by class 8 alone: police bikes are class 18. Bicycles (13) have no ignition.
function Hotwire.isBike(vehicle)
    return IsThisModelABike(GetEntityModel(vehicle)) and GetVehicleClass(vehicle) ~= 13
end

---Whether to offer a hotwire at all; the server decides the rest.
function Hotwire.canTry(vehicle)
    local model = GetEntityModel(vehicle)
    if excluded[model] or GetVehicleClass(vehicle) == 13 then return false end
    return not IsThisModelABike(model) or cfg.vehicleTypes.bike == true
end

local function fromBones(vehicle)
    local grip = Scene.boneOffset(vehicle, 'hbgrip_r')
    if not grip then return end

    local d = Hotwire.bikeDefaults
    return { switch = grip + d.switch, bar = d.bar, open = d.open, wires = d.wires, button = d.button }
end

---A measured fit, else one from the bones; Config.hotwire.bikeFits overrides either. With the bars straight.
---@return table? fit, string? source
function Hotwire.bikeFit(vehicle)
    local model = Hotwire.modelName(vehicle)
    local fit, source = Hotwire.bikes[model], 'measured'
    if not fit then fit, source = fromBones(vehicle), 'bones' end

    local own = cfg.bikeFits[model]
    if fit and own then
        local merged = {}
        for key, value in pairs(fit) do merged[key] = value end
        for key, value in pairs(own) do merged[key] = value end
        fit, source = merged, 'config'
    end
    return fit, source
end

---+X along the bar toward the grip, +Z up, the rider at -Y: tr_hw_bike_switch's space.
function Hotwire.barFrame(bar)
    local up = Vec.normalize(vec3(0.0, 0.0, 1.0) - bar * bar.z)
    return { x = bar, y = Vec.cross(up, bar), z = up }
end

---Where the lower half hangs off this bar, in switch space: the rig's hang is for a level bar, so it is turned about
---the middle wire's top to hang the way gravity pulls here, swung out toward the rider by swing degrees.
---@return vector3 hung, table hungRot
function Hotwire.bikeHang(frame, swing)
    local rig = Hotwire.rig.bike
    local down = Vec.unrotate(frame, vec3(0.0, 0.0, -1.0))
    local turn = Mat.mul(Mat.axis('y', math.deg(math.atan(-down.x, -down.z))), Mat.axis('x', -(swing or 0.0)))
    local top = rig.wires[2].top
    return top + Mat.apply(turn, rig.hung - top), Mat.mul(turn, Mat.axis('x', rig.hungPitch))
end

---The bike game's rig: the bike's axes at the switch block, turned so +Y looks from the wires camera at the wires. The
---cameras stay level and things fall straight down; S is the block's own rotation in it.
---@return table? rig
function Hotwire.bikeRig(vehicle)
    local fit = Hotwire.bikeFit(vehicle)
    if not fit then return end

    local frame = Hotwire.barFrame(fit.bar)
    local look = Mat.apply(frame, fit.wires[2] - fit.wires[1])
    local yaw = math.deg(math.atan(-look.x, look.y))
    local S = Mat.mul(Mat.axis('z', -yaw), frame)
    local function cam(c) return { Mat.apply(S, c[1]), Mat.apply(S, c[2]) } end
    local hung, hungRot = Hotwire.bikeHang(frame, fit.swing)

    return { offset = fit.switch, yaw = yaw, S = S, hung = hung, hungRot = hungRot, open = cam(fit.open),
        wires = cam(fit.wires), button = cam(fit.button) }
end

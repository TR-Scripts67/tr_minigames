local cfg = Config.hotwire

Hotwire = Hotwire or {}

function Hotwire.modelName(vehicle)
    return GetEntityArchetypeName(vehicle):lower()
end

---@return { offset: vector3, pitch: number } fit, string source
function Hotwire.fit(model, class)
    if cfg.vehicleFits[model] then return cfg.vehicleFits[model], 'model' end
    if cfg.classFits[class] then return cfg.classFits[class], 'class' end
    return cfg.rig, 'default'
end

---@return vector3
function Hotwire.anchor(vehicle)
    local wheel = Scene.boneOffset(vehicle, 'steeringwheel')
    if wheel then return wheel end

    -- No steering wheel bone: guess from the driver seat.
    return (Scene.boneOffset(vehicle, 'seat_dside_f') or vec3(-0.4, 0.0, 0.3)) + vec3(0.0, 0.45, 0.35)
end

---@return vector3 offset, number pitch
function Hotwire.placement(vehicle)
    local fit = Hotwire.fit(Hotwire.modelName(vehicle), GetVehicleClass(vehicle))
    return Hotwire.anchor(vehicle) + fit.offset, fit.pitch
end

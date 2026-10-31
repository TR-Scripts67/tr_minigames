DevCars = {}

function DevCars.models(skipClass, keep)
    local list = {}
    for _, name in ipairs(GetAllVehicleModels()) do
        local model = name:lower()
        local hash = joaat(model)
        if IsThisModelACar(hash) and not skipClass[GetVehicleClassFromName(hash)] and keep(model) then
            list[#list + 1] = model
        end
    end
    table.sort(list)
    return list
end

-- nil if the model doesn't load
function DevCars.spawn(model, at, heading)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then return end

    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return end
        Wait(0)
    end

    local vehicle = CreateVehicle(hash, at.x, at.y, at.z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    SetVehicleOnGroundProperly(vehicle)
    FreezeEntityPosition(vehicle, true)
    SetEntityInvincible(vehicle, true)
    SetVehicleDoorsLocked(vehicle, 2)
    SetVehicleDirtLevel(vehicle, 0.0)
    return vehicle
end

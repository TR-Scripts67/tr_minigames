TR.callback.register('tr_minigames:vehicleClass', function(model)
    if math.type(model) ~= 'integer' or not IsModelInCdimage(model) or not IsModelAVehicle(model) then return nil end
    return GetVehicleClassFromName(model)
end)

Alerts = {}

local last = {} ---@type table<string, integer> 'plate:kind' -> os.time() of the last alert

---@param src integer
---@param kind string a key of Config.police.alerts
---@param vehicle integer
---@return boolean sent
function Alerts.send(src, kind, vehicle)
    -- A config.lua kept from before 1.2.1 has no police block: no alerts then.
    local police = Config.police or {}
    local cfg = police.alerts and police.alerts[kind]
    if not cfg or cfg.enabled == false or not DoesEntityExist(vehicle) then return false end

    local plate = TR.keys.plate(vehicle)
    local key, now = ('%s:%s'):format(plate, kind), os.time()
    if last[key] and now - last[key] < (cfg.cooldown or 0) then return false end
    if math.random(100) > (cfg.chance or 100) then return false end
    last[key] = now

    local coords, radius = GetEntityCoords(vehicle), cfg.radius or 0
    if radius > 0 then
        -- Inner half of the area, so the car is always inside the circle police see.
        local angle, distance = math.random() * 2 * math.pi, math.sqrt(math.random()) * radius * 0.5
        coords = vector3(coords.x + math.cos(angle) * distance, coords.y + math.sin(angle) * distance, coords.z)
    end

    TR.dispatch.alert({
        coords = coords,
        title = TR.locale.t(('alerts.%s.title'):format(kind)),
        message = TR.locale.t(('alerts.%s.message'):format(kind), { plate = plate }),
        code = cfg.code,
        name = 'tr_minigames_' .. kind,
        jobs = police.jobs,
        priority = cfg.priority,
        time = cfg.time,
        source = src,
        blip = { sprite = cfg.sprite, color = cfg.color, radius = radius },
    })

    TriggerEvent('tr_minigames:alert', src, kind, NetworkGetNetworkIdFromEntity(vehicle), plate)
    return true
end

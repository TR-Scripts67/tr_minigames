-- No server native for vehicle class, and the player starting could lie, so another player's game is asked.

Vehicles = {}

local ASK_TIME = 3000 -- ms
local MAX_CLASS = 22

local known = {} ---@type table<integer, integer> model -> class

local function validClass(v)
    return math.type(v) == 'integer' and v >= 0 and v <= MAX_CLASS
end

-- At random so a cheat can't pick who answers.
local function someoneElse(src)
    local others = {}
    for _, id in ipairs(GetPlayers()) do
        local player = tonumber(id)
        if player and player ~= src then others[#others + 1] = player end
    end
    if #others > 0 then return others[math.random(#others)] end
end

function Vehicles.ask(player, model)
    local p = promise.new()
    -- Tables because a cfx promise ignores resolve(nil).
    CreateThread(function() p:resolve({ TR.callback.await('tr_minigames:vehicleClass', player, model) }) end)
    SetTimeout(ASK_TIME, function() p:resolve({}) end)
    local class = Citizen.Await(p)[1]
    if validClass(class) then return class end
end

-- Only logged when they differ: the one asked could be the one lying.
---@param claimed integer
function Vehicles.class(src, vehicle, claimed)
    local model = GetEntityModel(vehicle)
    local class = known[model]
    if class == nil then
        local player = someoneElse(src)
        class = player and Vehicles.ask(player, model)
        if class == nil then return claimed end
        known[model] = class
    end
    if class ~= claimed then
        TR.log.warn('%s (%d) said vehicle model %d is class %d, another player\'s game says %d', GetPlayerName(src), src,
            model, claimed, class)
    end
    return class
end

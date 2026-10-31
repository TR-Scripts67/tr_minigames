-- No natives here, so the tests can run it.

Siphon = Siphon or {}

local TAU = math.pi * 2

local Screw = {}
Screw.__index = Screw
Siphon.Screw = Screw

local TICK = math.rad(30)
local RATCHET = math.rad(40)  -- a fuel cap's ratchet, past tight

---@param turns number full turns between seated and free
---@param way 'off' | 'on'
---@param ratchet? boolean
---@param clicks? integer screwing on a ratchet cap: clicks needed to finish
function Screw.new(turns, way, ratchet, clicks)
    return setmetatable({
        turns = turns,
        way = way,
        ratchet = ratchet,
        clicks = clicks or 0,
        angle = 0.0,     -- radians
        ticks = 0,
        clicked = 0,
        tight = 0.0,     -- radians past tight
        done = false,
    }, Screw)
end

-- 0..1
function Screw:progress()
    return math.min(1.0, self.angle / (self.turns * TAU))
end

-- radians counter-clockwise from seated
function Screw:rotation()
    if self.way == 'off' then return self.angle end
    return (self.turns * TAU - self.angle)
end

local function tickEvents(self, events)
    local ticks = math.floor(self.angle / TICK)
    if ticks ~= self.ticks then
        events[#events + 1] = 'tick'
        self.ticks = ticks
    end
end

-- delta: counter-clockwise positive as the player sees it. Events: 'tick', 'ratchet', 'free', 'seated'.
---@param delta number
---@return string[] events
function Screw:turn(delta)
    local events = {}
    if self.done or delta == 0 then return events end
    local forward = self.way == 'off' and delta or -delta
    local full = self.turns * TAU

    local seated = (self.way == 'off' and self.angle <= 0.0) or (self.way == 'on' and self.angle >= full)
    local tighter = (self.way == 'off' and forward < 0) or (self.way == 'on' and forward > 0)
    if seated and tighter then
        if self.ratchet then
            self.tight = self.tight + math.abs(delta)
            while self.tight >= RATCHET do
                self.tight = self.tight - RATCHET
                events[#events + 1] = 'ratchet'
                if self.way == 'on' then
                    self.clicked = self.clicked + 1
                    if self.clicked >= self.clicks then
                        self.done = true
                        events[#events + 1] = 'seated'
                        return events
                    end
                end
            end
        elseif self.way == 'on' then
            self.done = true
            events[#events + 1] = 'seated'
        end
        return events
    end

    self.angle = math.max(0.0, math.min(full, self.angle + forward))
    tickEvents(self, events)
    if self.way == 'off' and self.angle >= full then
        self.done = true
        events[#events + 1] = 'free'
    elseif self.way == 'on' and self.angle >= full then
        events[#events + 1] = 'snug'
        if not self.ratchet then
            self.done = true
            events[#events + 1] = 'seated'
        end
    end
    return events
end

function Screw.delta(from, to)
    local d = to - from
    while d > math.pi do d = d - TAU end
    while d < -math.pi do d = d + TAU end
    return d
end

local Feed = {}
Feed.__index = Feed
Siphon.Feed = Feed

---@param opts { fuelAt?: number, bottom: number }
-- fuelAt: where the tip reaches the fuel. bottom: as far as it goes.
function Feed.new(opts)
    return setmetatable({
        fuelAt = opts.fuelAt or math.huge,
        bottom = opts.bottom,
        depth = 0.0,
        inFuel = false,
        atBottom = false,
    }, Feed)
end

-- ds: metres, negative pulls it out. Events: 'fuel', 'bottom'.
---@return string[] events
function Feed:push(ds)
    local events = {}
    if ds <= 0.0 then
        self.depth = math.max(0.0, self.depth + ds)
        if self.depth < self.fuelAt then self.inFuel = false end
        self.atBottom = false
        return events
    end

    self.depth = math.min(self.depth + ds, self.bottom)
    if self.depth >= self.bottom - 1e-9 then
        if not self.atBottom then events[#events + 1] = 'bottom' end
        self.atBottom = true
    end
    if not self.inFuel and self.depth >= self.fuelAt then
        self.inFuel = true
        events[#events + 1] = 'fuel'
    end
    return events
end

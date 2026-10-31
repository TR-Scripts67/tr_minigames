local cfg = Config.hotwire
local Rig = Hotwire.rig
local function t(key, vars) return TR.locale.t('hotwire.' .. key, vars) end


local Game = {}
Game.__index = Game

local SCREW_PITCH = 0.0035 -- metres per turn
local TIP_Y = Rig.wires[1].top.y + Rig.wires[1].tip.y
local UP = vec3(0.0, 0.0, 1.0)

local TOOLS = { 'probe', 'strippers', 'hand' }
local TOOL_MODELS = { probe = 'tr_hw_probe', strippers = 'tr_hw_strippers' }
local ANIM_DICT, ANIM = 'veh@std@ds@base', 'hotwire'

local KEY = { click = 24, tool = { 157, 158, 160 }, scrollUp = 241, scrollDown = 242, pause = 200, back = 194 }

local BIKE = Rig.bike

local function pathLength(path)
    local length = 0.0
    for k = 2, #path do length = length + Vec.length(path[k] - path[k - 1]) end
    return length
end

local function sound(name)
    TR.ui.sound.play(name, Config.volume)

    local game = Hotwire.current
    if game and game.mirror then game.mirror:sound(name) end
end

local LOOPS = { 'buzz', 'crank' } -- ids are 'hotwire:<loop>'

function Game.new(vehicle, session)
    local bike = Hotwire.isBike(vehicle) and Hotwire.bikeRig(vehicle) or nil
    local self = setmetatable({
        vehicle = vehicle,
        session = session,
        bike = bike,
        scene = bike and Scene.new(vehicle, bike.offset, 0.0, bike.yaw) or Scene.new(vehicle, Hotwire.placement(vehicle)),
        stage = bike and 'open' or 'screws',
        tool = 'screwdriver',
        strikes = 0,
        screws = {},
        wires = {},
        falling = {},
        running = true,
        now = GetGameTimer(),
        cursor = 1,
        advanced = {},
    }, Game)

    local defs = bike and self:bikeWires() or Rig.wires
    for i = 1, #Rig.screws do self.screws[i] = { turns = 0.0, out = false } end

    for i, def in ipairs(defs) do
        self.wires[i] = {
            def = def, length = pathLength(def.path), flop = bike and 0.0 or 80.0, sleeve = 0.0, tension = 0.0,
            bend = 0.0, bendGoal = 0.0, -- 0: its resting shape, 1: bent to reach endGoal
            attached = bike ~= nil, -- a bike's wires run into the lower half until they are cut
        }
        self:shapeWire(i)
    end

    return self
end

-- A bike's parts are placed in its switch block's space; a car's are in rig space already.
function Game:toRig(p) return self.S and Mat.apply(self.S, p) or p end

function Game:toRigRot(rot) return self.S and Mat.mul(self.S, rot) or rot end

function Game:setup()
    if self.bike then return self:setupBike() end

    local models = { 'tr_hw_column', 'tr_hw_shroud', 'tr_hw_screw', 'tr_hw_screwdriver', 'tr_hw_probe', 'tr_hw_probe_glow',
        'tr_hw_strippers', 'tr_hw_copper', 'tr_hw_twist' }
    for _, def in ipairs(Rig.wires) do
        models[#models + 1] = 'tr_hw_wire_' .. def.color
        models[#models + 1] = 'tr_hw_sleeve_' .. def.color
        models[#models + 1] = 'tr_hw_seg_' .. def.color
    end
    self.scene:preload(models)

    local scene = self.scene
    local cam = cfg.camera
    scene:spawn('column', 'tr_hw_column')

    if self.session.coverOff then
        -- Wired before and the engine was turned off: the cover is still off.
        for _, s in ipairs(self.screws) do s.out = true end
        for i, w in ipairs(self.wires) do
            w.flop = 0.0
            self:shapeWire(i)
        end
        self:spawnWires()
        self:startWires()
        self:restoreWires(self.session.wires, self.session.twisted)
        scene:createCamera(cam.wiresPos, cam.wiresTarget, cam.fov)
    else
        scene:spawn('shroud', 'tr_hw_shroud')
        for i in ipairs(Rig.screws) do scene:spawn('screw' .. i, 'tr_hw_screw', Rig.screws[i]) end
        scene:spawn('tool', 'tr_hw_screwdriver')
        scene:createCamera(cam.pos, cam.target, cam.fov)
    end

    SetVehicleEngineOn(self.vehicle, false, true, true)

    RequestAnimDict(ANIM_DICT)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(ANIM_DICT) and GetGameTimer() < deadline do Wait(0) end
    TaskPlayAnim(PlayerPedId(), ANIM_DICT, ANIM, 4.0, -4.0, -1, 49, 0.0, false, false, false)
end

function Game:cleanup()
    TR.ui.hud.hide()
    for _, id in ipairs(LOOPS) do TR.ui.sound.stop('hotwire:' .. id) end
    self.scene:destroy()
    StopAnimTask(PlayerPedId(), ANIM_DICT, ANIM, 2.0)
    RemoveAnimDict(ANIM_DICT)
end

-- Doesn't block the frame loop. cb gets the callback's results.
function Game:request(cb, name, ...)
    if self.pending then return end
    self.pending = true

    local args = table.pack(...)

    CreateThread(function()
        local result = table.pack(TR.callback.await(name, table.unpack(args, 1, args.n)))
        self.pending = false
        if not self.running or self.ending then return end

        if result[1] == nil then
            -- Not delivered (timeout, rate limit): nothing changed on the server.
            return self:flash(t(result[2] or 'try_again'), 'error')
        elseif result[1] == false then
            return self:finish(result[2] or 'no_session')
        end

        if result[1] == 'failed' then return self:fail(result[3]) end
        if math.type(result[2]) == 'integer' then self.strikes = result[2] end
        if cb then cb(table.unpack(result, 1, result.n)) end
    end)
end

function Game:finish(result, extra, delay)
    if self.ending then return end
    self.ending = true
    self.holding = nil
    self.result, self.extra = result, extra
    self.endAt = self.now + (delay or 0)
end

function Game:fail(itemBroke)
    sound('arc')
    self.strikes = self.session.maxStrikes
    self.scene:sparks(self:wireEnd(1), cfg.sparks, 2.0)
    SetVehicleAlarm(self.vehicle, true)
    SetVehicleAlarmTimeLeft(self.vehicle, cfg.alarmTime * 1000)
    StartVehicleAlarm(self.vehicle)
    self:finish('failed', itemBroke, 1500)
end

function Game:succeed()
    self:flash(t('started'), 'success', 2500)
    self.engineAt = self.now + 350
    self:finish('started', nil, 2200)
end

function Game:cancel()
    CreateThread(function() TR.callback.await('tr_minigames:hotwire:cancel') end)
    self:finish('cancelled')
end

---@param tone? 'default' | 'success' | 'error' | 'muted'
function Game:flash(text, tone, duration)
    TR.ui.hud.flash(text, tone, duration)
end

function Game:screwPos(i)
    return Rig.screws[i] + vec3(0.0, 0.0, -self.screws[i].turns * SCREW_PITCH)
end

local LINKS = 10
local LINK = Rig.segmentLength
local FORWARD = 0.012   -- metres toward the camera, in front of the other wires
local TWIST_GAP = 0.0068 -- metres between twisted wire centres: the insulation just touches
local TWIST_DROP = 0.006 -- metres from the insulation ends down to the copper twist
local LIFT = vec3(0.0, -0.015, 0.0)

-- A car's; a bike game sets its own (bikeWires).
Game.pieces = { wire = 'tr_hw_wire_', sleeve = 'tr_hw_sleeve_', seg = 'tr_hw_seg_', copper = 'tr_hw_copper', twist = 'tr_hw_twist',
    strippers = 'tr_hw_strippers' }
Game.links, Game.linkLength, Game.tipY, Game.twistGap = LINKS, LINK, TIP_Y, TWIST_GAP
Game.sleeveLength, Game.copperLength = Rig.sleeveLength, Rig.copperLength
Game.toolRest = vec3(0.0, TIP_Y - 0.02, -0.15)
Game.needed, Game.neededCount = { steady = true, pulse = true, flicker = true }, 3 -- battery, ignition, starter

local function resample(points, n)
    local lengths, total = { 0.0 }, 0.0
    for k = 2, #points do
        total = total + Vec.length(points[k] - points[k - 1])
        lengths[k] = total
    end

    local out, k = {}, 2
    for j = 0, n do
        local at = total * j / n
        while k < #points and lengths[k] < at do k = k + 1 end
        local span = lengths[k] - lengths[k - 1]
        out[j + 1] = Vec.lerp(points[k - 1], points[k], span > 1e-9 and (at - lengths[k - 1]) / span or 0.0)
    end
    return out
end

local function bezier(p0, p1, p2, p3, steps)
    local points = {}
    for j = 0, steps do
        local t = j / steps
        local u = 1.0 - t
        points[j + 1] = p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)
    end
    return points
end

local function bentShape(top, start, finish, length, arrive)
    local reach = finish - top
    local far = length * 0.97
    if Vec.length(reach) > far then finish = top + Vec.normalize(reach) * far end

    local bow = vec3(0.0, -math.min(0.03, math.abs(finish.x - top.x) * 0.35), 0.0)
    local up = arrive and arrive * -1.0 or vec3(0.0, 0.0, 1.0)

    -- Longer handles make the curve sag more; find the sag that matches the wire's length.
    local lo, hi = 0.0, length
    local points
    for _ = 1, 14 do
        local handle = (lo + hi) / 2
        -- The extra pull at the start brings it forward right from the connector, clear of its neighbours.
        points = bezier(top, top + start * handle + bow + LIFT, finish + up * handle + bow, finish, 24)
        if pathLength(points) > length then hi = handle else lo = handle end
    end
    return points
end

local function linkRot(along)
    local z = Vec.normalize(along) * -1.0
    local x = Vec.cross(vec3(0.0, 1.0, 0.0), z)
    x = Vec.length(x) > 1e-6 and Vec.normalize(x) or vec3(1.0, 0.0, 0.0)
    return { x = x, y = Vec.cross(z, x), z = z }
end

-- A bike's wires get as many links as their length takes, so a link never sticks out past the next at a bend.
function Game:linkCount(length)
    if not self.bike then return self.links end
    return Clamp(math.ceil(length / self.linkLength), 1, self.links)
end

function Game:shapeWire(i)
    local w = self.wires[i]
    local def = w.def
    local drop = Mat.axis('x', w.flop)
    local points

    if w.attached then
        local shape = self:attachedShape(def)
        points = resample(shape, self:linkCount(pathLength(shape)))
    else
        local links = self:linkCount(w.length)
        local rest = {}
        for k, p in ipairs(def.path) do rest[k] = def.top + Mat.apply(drop, p) end
        points = resample(rest, links)

        if w.bend > 0.001 and w.endPos then
            local bent = resample(bentShape(def.top, Vec.normalize(points[2] - points[1]), w.endPos, w.length, w.arrive), links)
            for k = 1, #points do points[k] = Vec.lerp(points[k], bent[k], w.bend) end
        end

        if self.shut and self.shut > 0.0 then
            local tucked, m = self:tuckedShape(i)
            if m > 0.0 then
                tucked = resample(tucked, links)
                for k = 1, #points do points[k] = Vec.lerp(points[k], tucked[k], m) end
            end
        end
    end

    w.points = points
    local along = Vec.normalize(points[#points] - points[#points - 1])
    -- A twisted wire's end follows its arrival angle so its copper meets the twist's middle.
    if w.arrive then along = Vec.lerp(along, w.arrive, w.bend) end
    w.rot = (w.bend > 0.001 or self.bike) and linkRot(along) or drop
end

function Game:wireRot(i) return self.wires[i].rot end

function Game:wireTip(i)
    local points = self.wires[i].points
    return points[#points]
end

function Game:reach(i, tip)
    local w = self.wires[i]
    w.endGoal = tip
    w.endPos = w.endPos or self:wireTip(i)
    w.bendGoal = 1.0
end

function Game:release(i)
    self.wires[i].bendGoal = 0.0
end

function Game:wireEnd(i)
    local w = self.wires[i]
    local depth = w.stripped and self.copperLength * 0.6 or self.sleeveLength
    return self:wireTip(i) + Mat.apply(self:wireRot(i), vec3(0.0, 0.0, -depth))
end

function Game:wirePoints(i)
    local points = {}
    for k, p in ipairs(self.wires[i].points) do points[k] = p end
    if not self.wires[i].attached then points[#points + 1] = self:wireEnd(i) end
    return points
end

function Game:hoverWire(maxPixels, filter)
    local best, index, point, along = maxPixels, nil, nil, nil

    for i, w in ipairs(self.wires) do
        if not filter or filter(w, i) then
            local d, p, a = self.scene:nearestOnLine(self:wirePoints(i), self.mx, self.my)
            if d < best then best, index, point, along = d, i, p, a end
        end
    end

    return index, point, along
end

function Game:hoverEnd(maxPixels, filter, sx, sy)
    local best, index = maxPixels, nil
    sx, sy = sx or self.mx, sy or self.my

    for i, w in ipairs(self.wires) do
        if not filter or filter(w, i) then
            local x, y = self.scene:project(self:wireEnd(i))
            if x then
                local d = Scene.pixels(x, y, sx, sy)
                if d < best then best, index = d, i end
            end
        end
    end

    return index
end

-- Wires hang at different lengths, so ends rarely line up; any part of the copper counts.
function Game:hoverCopper(maxPixels, exclude, sx, sy)
    local best, index = maxPixels, nil

    for j, w in ipairs(self.wires) do
        if j ~= exclude and w.stripped and not w.twisted then
            local tip = self:wireTip(j)
            local copper = { tip, tip + Mat.apply(self:wireRot(j), vec3(0.0, 0.0, -self.copperLength)) }
            local d = math.min(
                (self.scene:nearestOnLine(copper, self.mx, self.my)),
                sx and (self.scene:nearestOnLine(copper, sx, sy)) or math.huge
            )
            if d < best then best, index = d, j end
        end
    end

    return index
end

function Game:aimTool(pos, side)
    local from = self.scene:cameraPosition() + vec3(side or 0.06, 0.0, -0.05)
    return Mat.look(pos - from, UP)
end

function Game:controls()
    DisableAllControlActions(0)
    EnableControlAction(0, 249, true) -- push to talk
    HideHudAndRadarThisFrame()
    SetMouseCursorActiveThisFrame()
    SetMouseCursorSprite(self.cursor)
    -- Only by the column, where the driver's legs would block the view. A rider stays hidden once the camera is in:
    -- their hand is on the grip, right by the switch block.
    local near = Vec.length(self.scene.camPos - self.scene.camGoalPos) < 0.35
    self.riderHidden = self.riderHidden or (near and self.bike ~= nil)
    if near or self.riderHidden then SetEntityLocallyInvisible(PlayerPedId()) end

    self.mx, self.my = GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240)
    self.down = IsDisabledControlPressed(0, KEY.click)
    self.pressed = IsDisabledControlJustPressed(0, KEY.click)

    if self.ending then
        self.down, self.pressed = false, false
        return
    end

    if IsDisabledControlJustPressed(0, KEY.pause) or IsDisabledControlJustPressed(0, KEY.back) then
        return self:cancel()
    end

    if self.stage == 'wires' and not self.holding then
        for i, key in ipairs(KEY.tool) do
            if IsDisabledControlJustPressed(0, key) then self:setTool(TOOLS[i]) end
        end

        local index = 1
        for i, tool in ipairs(TOOLS) do if tool == self.tool then index = i end end
        if IsDisabledControlJustPressed(0, KEY.scrollDown) then self:setTool(TOOLS[index % #TOOLS + 1]) end
        if IsDisabledControlJustPressed(0, KEY.scrollUp) then self:setTool(TOOLS[(index - 2) % #TOOLS + 1]) end
    end
end

function Game:setTool(tool)
    if self.tool == tool then return end
    self.advanced[self.tool] = self.advanced[self.tool] or self:stepDone(self.tool)
    self.tool = tool
    for name in pairs(TOOL_MODELS) do self.scene:setVisible(name, name == tool) end
    self.scene:setVisible('glow', false)
    sound('click')
end

function Game:screwStep(dt)
    local scene = self.scene
    local h = self.holding

    if h and not self.down then
        self.holding, h = nil, nil
    end

    local hovered
    if not h then
        for i, s in ipairs(self.screws) do
            local x, y = scene:project(self:screwPos(i))
            if not s.out and x and Scene.pixels(x, y, self.mx, self.my) < 30 then hovered = i end
        end

        if hovered and self.pressed then
            h = { screw = hovered, speed = 0.0, wrong = 0.0, ticks = 0 }
            self.holding = h
        end
    end

    if h then self:turnScrew(h, dt) end

    local driver = scene:get('tool')
    if not driver then return end

    local target = h and h.screw or hovered
    self.ringScrew = target

    if target then
        -- On a screw: seated in its PH2 recess, almost in line with it like a real screwdriver. The lean
        -- pivots at the recess mouth so the tip fits exactly where it shows.
        local lean = Mat.axis('x', 6.0)
        driver.pos = self:screwPos(target) + vec3(0.0, 0.0, Rig.screwFace) + Mat.apply(lean, vec3(0.0, 0.0, Rig.driveDepth))
        driver.rot = Mat.mul(lean, Mat.axis('z', -self.screws[target].turns * 360.0))
    else
        -- Between screws the handle leans away so it doesn't hide the cover.
        driver.pos = scene:onPlane(self.mx, self.my, 'z', Rig.screws[1].z - 0.012)
        driver.rot = Mat.mul(Mat.axis('y', 15.0), Mat.axis('x', 28.0))
    end

    self.cursor = target and 3 or 1
end

function Game:turnScrew(h, dt)
    local s = self.screws[h.screw]
    local cx, cy = self.scene:project(self:screwPos(h.screw))
    if not cx then return end

    local w, hgt = GetActiveScreenResolution()
    local dx, dy = (self.mx - cx) * w, (self.my - cy) * hgt
    if dx * dx + dy * dy < 100 then return end -- too close to the centre to read a direction

    local angle = math.atan(dy, dx)

    if h.angle then
        -- Screen y points down, so a clockwise circle increases the angle.
        local loosen = -AngleDelta(h.angle, angle) / (math.pi * 2)
        s.turns = Clamp(s.turns + loosen, 0.0, cfg.screws.turns)
        h.speed = Lerp(h.speed, math.abs(loosen) / math.max(dt, 0.001), 0.15)

        if loosen < 0 then
            h.wrong = h.wrong - loosen
            if h.wrong > 0.5 then
                h.wrong = 0.0
                self:flash(t('wrong_way'), 'muted')
            end
        end

        local ticks = math.floor(s.turns * 8) -- a notch every eighth of a turn
        if ticks ~= h.ticks then
            h.ticks = ticks
            sound('tick')
        end

        if h.speed > cfg.screws.maxSpeed then
            s.turns = math.max(0.0, s.turns - 0.35)
            self.holding = nil
            self:flash(t('slipped'), 'error')
            sound('slip')
            ShakeCam(self.scene.cam, 'SMALL_EXPLOSION_SHAKE', 0.03)
            return
        end
    end

    h.angle = angle

    if s.turns >= cfg.screws.turns then
        s.out = true
        self.holding = nil
        self:drop('screw' .. h.screw)
        sound('screw_out')

        for _, other in ipairs(self.screws) do
            if not other.out then return end
        end

        self:request(function() self:openCover() end, 'tr_minigames:hotwire:cover')
    end
end

function Game:drop(id, push)
    local part = self.scene:get(id)
    if not part then return end
    self.falling[#self.falling + 1] = { id = id, vel = push or vec3(0.0, -0.05, 0.0), spin = math.random(-400, 400), age = 0.0 }
end

function Game:openCover()
    sound(self.bike and 'bike_pop' or 'cover')
    self.stage = 'opening'
    self.coverAge = 0.0
    self.scene:remove('tool')
    self.cursor = 1

    if self.bike then
        self.shutFrom, self.holding = self.shut, nil
        return self.scene:moveCamera(self.bike.wires[1], self.bike.wires[2])
    end
    local cam = cfg.camera
    self.scene:moveCamera(cam.wiresPos, cam.wiresTarget)
end

function Game:coverStep(dt)
    self.coverAge = self.coverAge + dt
    local k = math.min(self.coverAge / (self.bike and 0.6 or 0.9), 1.0)
    local shroud = self.scene:get('shroud')

    if self.bike then
        -- Falls fast, then the wires catch it and it swings.
        self:setShut(self.shutFrom * (1.0 - k) ^ 2)
        if k >= 1.0 then self.swingAge = 0.0 end
    elseif shroud then
        shroud.pos = vec3(0.0, -0.04 * k, -0.4 * k * k)
        shroud.rot = Mat.axis('x', -40.0 * k)
    end

    if (k > 0.3 or self.bike) and not self.wiresOut then
        self:spawnWires()
        if not self.bike then self.wiresAge = 0.0 end -- a bike's are held at both ends
    end

    if k >= 1.0 then
        self.scene:remove('shroud')
        self:startWires()
    end
end

function Game:spawnWires()
    self.wiresOut = true
    if self.bike then return end -- links only, drawn as they are shaped

    local scene = self.scene
    for i, w in ipairs(self.wires) do
        local color = w.def.color
        scene:spawn('wire' .. i, 'tr_hw_wire_' .. color, w.def.top, Mat.axis('x', w.flop))
        scene:spawn('sleeve' .. i, 'tr_hw_sleeve_' .. color, self:wireTip(i), self:wireRot(i))
    end
end

function Game:startWires()
    local scene = self.scene
    scene:spawn('probe', 'tr_hw_probe', self.toolRest)
    scene:spawn('strippers', self.pieces.strippers, self.toolRest)
    scene:spawn('glow', 'tr_hw_probe_glow')
    scene:setVisible('strippers', false)
    scene:setVisible('glow', false)
    self.tool = 'probe'
    self.stage = 'wires'
end

function Game:restoreWires(list, twisted)
    if type(list) ~= 'table' or #list == 0 then return end

    local scene = self.scene
    for _, entry in ipairs(list) do
        local i, w = entry.wire, self.wires[entry.wire]
        if w then
            w.reading, w.asked, w.stripped, w.attached = entry.reading, true, true, false
            self:shapeWire(i)
            scene:remove('sleeve' .. i)
            scene:spawn('copper' .. i, self.pieces.copper, self:wireTip(i), self:wireRot(i))
        end
    end

    if self:stepDone('probe') and self:stepDone('strippers') then
        self.advanced.probe, self.advanced.strippers = true, true
        self:setTool('hand')
        if type(twisted) == 'table' and self.wires[twisted[1]] and self.wires[twisted[2]] then
            self:joinWires(twisted[1], twisted[2])
            for _, i in ipairs(twisted) do
                local w = self.wires[i]
                w.bend, w.endPos = 1.0, w.endGoal
                self:shapeWire(i)
            end
            local top = (self:wireTip(twisted[1]) + self:wireTip(twisted[2])) * 0.5 + vec3(0.0, 0.0, -TWIST_DROP)
            self.scene:spawn('twist', self.pieces.twist, top)
            self.twistAge = 1.0
        end
        self:flash(t('rewired'), 'default', 2600)
    end
end

local function glowLevel(reading, now)
    if reading == 'steady' then return 1.0 end
    if reading == 'dim' then return 0.3 end
    if reading == 'pulse' then return 0.5 + 0.5 * math.sin(now / 160.0) end
    if reading == 'flicker' then return (math.floor(now / 55) * 7919) % 5 < 2 and 1.0 or 0.05 end
    return 0.0
end

-- Nearby players light the bulb from the hum's pattern, so it flickers in rhythm, not at the update rate.
Mirror.effects.hotwire = function(replica, now)
    local n, bulb, target = replica:find('tr_hw_probe_glow')
    if not n then return end

    local buzz = replica.loops.buzz
    local glow = buzz and glowLevel(buzz[2] and buzz[2].pattern, now) or 0.0
    target.ownVisibility = true
    replica.scene:setVisible(n, glow > 0.45)
    if glow > 0.02 then replica.scene:light(bulb.pos, 255, 170, 70, 0.12, 6.0 * glow) end
end

function Game:probeStep()
    local scene = self.scene
    local probe = scene:get('probe')
    local i, point = self:hoverWire(16)

    self.glow = 0.0
    self.probing = nil

    if i then
        local cam = scene:cameraPosition()
        probe.pos = point + Vec.normalize(cam - point) * 0.0035

        local w = self.wires[i]
        if self.pressed then sound('click') end
        if self.down then
            self.probing = w.reading or 'none'
            if w.reading == nil and not w.asked then
                w.asked = true
                self:request(function(_, reading) w.reading = reading end, 'tr_minigames:hotwire:probe', i)
            end
            self.glow = glowLevel(w.reading, self.now)
        end
    else
        probe.pos = scene:onPlane(self.mx, self.my, 'y', self.tipY - 0.008)
    end

    probe.rot = self:aimTool(probe.pos, 0.07)

    local glow = scene:get('glow')
    glow.pos = probe.pos + Mat.apply(probe.rot, Rig.probeBulb)
    glow.rot = probe.rot
    scene:setVisible('glow', self.glow > 0.45)
end

function Game:stripStep(dt)
    local scene = self.scene
    local tool = scene:get('strippers')
    local h = self.holding

    if h and not self.down then
        self.holding, h = nil, nil
    end

    if not h then
        local i = self:hoverWire(18, function(w) return not w.stripped end)

        if i and self.wires[i].attached then
            tool.pos = self:cutPoint(i)
            if self.pressed then self:cutWire(i) end
        elseif i then
            local w = self.wires[i]
            tool.pos = self:wireTip(i) + Mat.apply(self:wireRot(i), vec3(0.0, 0.0, -0.003 - w.sleeve))

            if self.pressed then
                if not scene:get('copper' .. i) then
                    scene:spawn('copper' .. i, self.pieces.copper, self:wireTip(i), self:wireRot(i))
                end
                local p = scene:onPlane(self.mx, self.my, 'y', self:wireTip(i).y)
                h = { wire = i, startZ = p.z + w.sleeve }
                self.holding = h
            end
        else
            tool.pos = scene:onPlane(self.mx, self.my, 'y', self.tipY - 0.008)
        end

        self.cursor = i and 3 or 1
    end

    if h then
        self.cursor = 4
        local w = self.wires[h.wire]
        local p = scene:onPlane(self.mx, self.my, 'y', self:wireTip(h.wire).y)
        local before = w.sleeve

        w.sleeve = math.max(w.sleeve, Clamp(h.startZ - p.z, 0.0, self.sleeveLength + 0.01))

        local speed = (w.sleeve - before) / math.max(dt, 0.001)
        local limit = cfg.strip.maxSpeed

        if speed > limit then
            w.tension = w.tension + (speed / limit - 1.0) * dt * 5.0
        else
            w.tension = math.max(0.0, w.tension - dt * 1.5)
        end

        tool.pos = self:wireTip(h.wire) + Mat.apply(self:wireRot(h.wire), vec3(0.0, 0.0, -0.003 - w.sleeve))

        if w.tension >= 1.0 then
            w.tension, w.sleeve = 0.0, 0.0
            self.holding = nil
            self:flash(t('nicked'), 'error')
            sound('nick')
            self:request(nil, 'tr_minigames:hotwire:nick', h.wire)
        elseif w.sleeve >= self.sleeveLength + 0.002 then
            w.stripped, w.tension = true, 0.0
            self.holding = nil
            self:drop('sleeve' .. h.wire)
            sound('snip')
            self:request(nil, 'tr_minigames:hotwire:strip', h.wire)
        end
    end

    tool.rot = self:aimTool(tool.pos, -0.07)
end

local function bare(w) return w.stripped and not w.twisted end

function Game:handStep()
    local h = self.holding

    if not h then
        local i = self:hoverEnd(26, bare)
        self.cursor = i and 3 or 1

        if i and self.pressed then
            self.holding = { wire = i }
        elseif self.pressed and self:hoverWire(16, function(w) return not w.stripped end) then
            self:flash(t('strip_first'), 'muted')
        end
        return
    end

    self.cursor = 4
    local scene = self.scene
    local w = self.wires[h.wire]

    local depth = w.stripped and self.copperLength * 0.6 or self.sleeveLength
    self:reach(h.wire, scene:onPlane(self.mx, self.my, 'y', self.tipY - FORWARD) + vec3(0.0, 0.0, depth))

    local ex, ey = scene:project(self:wireEnd(h.wire))
    if not ex then return end

    if not self.twistPoint then
        h.target = self:hoverCopper(30, h.wire, ex, ey)

        if not self.down then
            self.holding = nil
            self:release(h.wire)
            if h.target then
                local a, b = h.wire, h.target
                self:request(function(result) self:onTwist(result, a, b) end, 'tr_minigames:hotwire:twist', a, b)
            end
        end
        return
    end

    local tx, ty = scene:project(self.twistPoint)
    local contact = tx and math.min(Scene.pixels(ex, ey, tx, ty), Scene.pixels(self.mx, self.my, tx, ty)) < 32

    if contact and not h.crankStart then
        h.crankStart, h.nextSpark = self.now, 0
        ShakeCam(scene.cam, 'ROAD_VIBRATION_SHAKE', 0.4)
    end

    if h.crankStart then
        local held = self.now - h.crankStart

        if self.now >= h.nextSpark then
            h.nextSpark = self.now + math.random(90, 220)
            scene:sparks(self.twistPoint, cfg.sparks, 0.6)
        end

        if not contact or not self.down or held > self.session.crank.closes + 600 then
            local wire = h.wire
            StopCamShaking(scene.cam, false)
            self.holding = nil
            self:release(wire)
            self:request(function(result) self:onCrank(result, wire) end, 'tr_minigames:hotwire:crank', wire, math.floor(held))
        end
    elseif not self.down then
        self.holding = nil
        self:release(h.wire)
    end
end

function Game:joinWires(a, b)
    local wa, wb = self.wires[a], self.wires[b]
    local ra, rb = wa.def.top + wa.def.tip, wb.def.top + wb.def.tip

    local side = ra.x < rb.x and -1.0 or 1.0
    local z = math.max(self:wireTip(a).z, self:wireTip(b).z)
    local meet = vec3((ra.x + rb.x) / 2, self.tipY - FORWARD, z)
    -- A short wire (a bike's) only reaches a point beside where it hangs higher up.
    for _, w in ipairs({ wa, wb }) do
        local reach, flat = w.length * 0.95, meet - w.def.top
        local across = flat.x * flat.x + flat.y * flat.y
        if across < reach * reach then
            meet = vec3(meet.x, meet.y, math.max(meet.z, w.def.top.z - math.sqrt(reach * reach - across)))
        end
    end

    local half = self.twistGap / 2
    local lean = Vec.normalize(vec3(half, 0.0, -math.sqrt(self.copperLength ^ 2 - half * half)))
    wa.twisted, wb.twisted = true, true
    wa.arrive = vec3(-side * lean.x, 0.0, lean.z)
    wb.arrive = vec3(side * lean.x, 0.0, lean.z)
    self:reach(a, meet + vec3(side * half, 0.0, 0.0))
    self:reach(b, meet - vec3(side * half, 0.0, 0.0))
    self.twistWires = { a, b }
    self.twistAge = 0.0
end

function Game:onTwist(result, a, b)
    if result == 'twisted' then
        self:joinWires(a, b)
        self:flash(t('twisted'), 'success')
        sound('relay')
        if self.bike then self.closeAt = self.now + 900 end
    elseif result == 'short' then
        self.scene:sparks(self:wireEnd(a), cfg.sparks, 1.5)
        ApplyDamageToPed(PlayerPedId(), cfg.shockDamage, false)
        self:flash(t('short'), 'error')
        sound('arc')
    else
        self:flash(t('nothing'), 'muted')
    end
end

function Game:onCrank(result, wire)
    if result == 'started' then return self:succeed() end

    if result == 'overcrank' then
        if wire then self.scene:sparks(self:wireEnd(wire), cfg.sparks, 1.5) end
        self:flash(t(self.bike and 'overcrank_bike' or 'overcrank'), 'error')
        if not self.bike then sound('burn') end
    elseif result == 'sputter' then
        self:flash(t('sputter'), 'muted')
        sound(self.bike and 'bike_sputter' or 'sputter')
    else
        self:flash(t('nothing'), 'muted')
    end
end

local AUTO_DELAY = 900 -- ms

function Game:stepDone(tool)
    local found, stripped = self:progress()
    if tool == 'probe' then return found == self.neededCount end
    if tool == 'strippers' then return stripped == self.neededCount end
    return false
end

function Game:progress()
    local found, stripped = 0, 0
    for _, w in ipairs(self.wires) do
        if self.needed[w.reading] then
            found = found + 1
            if w.stripped then stripped = stripped + 1 end
        end
    end
    return found, stripped
end

function Game:autoAdvance()
    if self.stage ~= 'wires' or self.holding or self.pending then
        self.autoAt = nil
        return
    end

    local found, stripped = self:progress()
    local next, message
    if self.tool == 'probe' and found == self.neededCount and not self.advanced.probe then
        next, message = 'strippers', self.bike and 'next_strip_bike' or 'next_strip'
    elseif self.tool == 'strippers' and stripped == self.neededCount and not self.advanced.strippers then
        next, message = 'hand', 'next_hand'
    end

    if not next then
        self.autoAt = nil
        return
    end

    self.autoAt = self.autoAt or self.now + AUTO_DELAY
    if self.now < self.autoAt then return end

    self.autoAt = nil
    self.advanced[self.tool] = true
    self:setTool(next)
    self:flash(t(message), 'default', 2200)
end

function Game:drawWire(i)
    local scene, w = self.scene, self.wires[i]
    local whole = self.pieces.wire
    local wire = whole and scene:get('wire' .. i)
    if not self.wiresOut or (whole and not wire) then return end

    local bent = w.bend > 0.01 or not whole
    if bent and not w.links then
        w.links = true
        for n = 1, self.links do scene:spawn(('link%d_%d'):format(i, n), self.pieces.seg .. w.def.color) end
    end

    if wire then
        scene:setVisible('wire' .. i, not bent)
        wire.rot = Mat.axis('x', w.flop)
    end
    if not w.links then return end

    local points = w.points
    local count = #points - 1
    for n = 1, self.links do
        local id = ('link%d_%d'):format(i, n)
        local link = scene:get(id)
        if link then
            local shown = bent and n <= count
            scene:setVisible(id, shown)
            if shown then
                local rot = linkRot(points[n + 1] - points[n])
                link.rot = rot
                -- The last link ends at the insulation end so it never covers the copper.
                link.pos = n == count and points[n + 1] + Mat.apply(rot, vec3(0.0, 0.0, self.linkLength)) or points[n]
            end
        end
    end
end

function Game:animate(dt)
    local scene = self.scene
    if self.bike then self:animateBike(dt) end

    for i, s in ipairs(self.screws) do
        local part = not s.out and scene:get('screw' .. i)
        if part then
            part.pos = self:screwPos(i)
            part.rot = Mat.axis('z', -s.turns * 360.0)
        end
    end

    if self.wiresAge then
        self.wiresAge = self.wiresAge + dt
        local a = self.wiresAge
        local swing = 80.0 * math.exp(-4.5 * a)
        if swing < 0.05 then self.wiresAge = nil end
        for _, w in ipairs(self.wires) do w.flop = self.wiresAge and swing * math.cos(a * 9.0) or 0.0 end
    end

    -- Wires are only reshaped and redrawn when something changed: resting wires cost nothing.
    local k = Clamp(dt * 10.0, 0.0, 1.0)
    for i, w in ipairs(self.wires) do
        w.bend = Lerp(w.bend, w.bendGoal, Clamp(dt * 8.0, 0.0, 1.0))
        if w.bend < 0.002 and w.bendGoal == 0.0 then w.bend, w.endPos = 0.0, nil end
        if w.bend > 0.999 and w.bendGoal == 1.0 then w.bend = 1.0 end
        if w.endGoal and w.endPos then
            w.endPos = #(w.endPos - w.endGoal) < 1e-4 and w.endGoal or Vec.lerp(w.endPos, w.endGoal, k)
        end
        local shaped = w.shaped
        if not shaped or shaped.bend ~= w.bend or shaped.flop ~= w.flop or shaped.endPos ~= w.endPos
            or shaped.arrive ~= w.arrive or shaped.out ~= self.wiresOut or shaped.attached ~= w.attached
            or shaped.shut ~= self.shut or shaped.swing ~= self.swing or shaped.roll ~= self.roll then
            w.shaped = { bend = w.bend, flop = w.flop, endPos = w.endPos, arrive = w.arrive, out = self.wiresOut,
                attached = w.attached, shut = self.shut, swing = self.swing, roll = self.roll }
            self:shapeWire(i)
            self:drawWire(i)
        end

        local rot, tip = self:wireRot(i), self:wireTip(i)
        local sleeve, copper = scene:get('sleeve' .. i), scene:get('copper' .. i)

        if sleeve and not w.stripped then
            sleeve.pos = tip + Mat.apply(rot, vec3(0.0, 0.0, -w.sleeve))
            sleeve.rot = rot
        end
        if copper then
            copper.pos, copper.rot = tip, rot
        end
    end

    if self.twistAge then
        self.twistAge = self.twistAge + dt
        local a, b = self.twistWires[1], self.twistWires[2]
        local top = (self:wireTip(a) + self:wireTip(b)) * 0.5 + vec3(0.0, 0.0, -TWIST_DROP)
        self.twistPoint = top + vec3(0.0, 0.0, -0.008)

        if self.twistAge > 0.35 and not scene:get('twist') then
            scene:spawn('twist', self.pieces.twist, top)
            sound('click')
        end

        local twist = scene:get('twist')
        if twist then twist.pos = top end
    end

    for n = #self.falling, 1, -1 do
        local f = self.falling[n]
        local part = scene:get(f.id)
        f.age = f.age + dt

        if not part or f.age > 0.9 then
            scene:remove(f.id)
            table.remove(self.falling, n)
        else
            f.vel = f.vel + vec3(0.0, 0.0, -9.8 * dt)
            part.pos = part.pos + f.vel * dt
            part.rot = Mat.mul(part.rot, Mat.axis('x', f.spin * dt))
        end
    end

    if self.engineAt and self.now >= self.engineAt then
        self.engineAt = nil
        SetVehicleNeedsToBeHotwired(self.vehicle, false)
        SetVehicleEngineOn(self.vehicle, true, false, true)
    end
end

function Game:effects()
    local scene = self.scene
    scene:torch()

    if self.glow and self.glow > 0.02 and self.tool == 'probe' then
        local glow = scene:get('glow')
        if glow then scene:light(glow.pos, 255, 170, 70, 0.12, 6.0 * self.glow) end
    end
end

function Game:soundLoops()
    local h = self.holding
    local active = {}

    if not self.ending then
        if self.tool == 'probe' and self.probing then active.buzz = { 'buzz', { pattern = self.probing } } end

        if h and h.crankStart then active.crank = { self.bike and 'bike_crank' or 'crank' } end
    end

    for _, id in ipairs(LOOPS) do
        local loop = active[id]
        if loop then
            TR.ui.sound.loop('hotwire:' .. id, loop[1], loop[2], Config.volume)
        else
            TR.ui.sound.stop('hotwire:' .. id)
        end
    end

    if self.mirror then self.mirror:setLoops(active) end
end

-- Rounded so tiny camera drift doesn't resend the HUD every frame.
local function screen(x, y)
    return math.floor(x * 2000 + 0.5) / 2000, math.floor(y * 2000 + 0.5) / 2000
end

function Game:hint()
    local keys = { { key = 'ESC', label = t('give_up') } }
    if self.stage == 'screws' then return { text = t('hint_screws'), keys = keys } end
    if self.stage == 'open' then return { text = t('hint_open'), keys = keys } end
    if self.stage == 'close' then return { text = t('hint_close'), keys = keys } end
    if self.stage == 'button' then return { text = t('hint_button'), keys = keys } end
    if self.stage ~= 'wires' then return end

    table.insert(keys, 1, { key = '1-3', label = t('switch_tool') })

    if self.tool == 'probe' then
        return { text = t('hint_probe'), sub = t(self.bike and 'legend_bike' or 'legend'), keys = keys }
    end
    if self.tool == 'strippers' then return { text = t(self:anyAttached() and 'hint_cut' or 'hint_strippers'), keys = keys } end
    return { text = t(self.twistPoint and 'hint_crank' or 'hint_twist'), keys = keys }
end

function Game:markers()
    local markers = {}

    local function add(marker, pos)
        local x, y = self.scene:project(pos)
        if not x then return end
        marker.x, marker.y = screen(x, y)
        markers[#markers + 1] = marker
    end

    if self.stage == 'wires' then
        for i, w in ipairs(self.wires) do
            if w.reading and not w.twisted then
                -- Not cut yet: by the middle of the wire, where the three are furthest apart.
                local at = w.attached and w.points[math.ceil(#w.points / 2)] or self:wireEnd(i) + vec3(0.0, 0.0, -0.012)
                add({ id = 'reading' .. i, kind = 'label', text = t('reading_' .. w.reading) }, at)
            end
        end
    end

    if self.stage == 'screws' and self.ringScrew then
        local turns = self.screws[self.ringScrew].turns
        add({ id = 'screw', kind = 'ring', spin = true, progress = math.floor(turns / cfg.screws.turns * 28) / 28 },
            self:screwPos(self.ringScrew))
    end

    local held = self.holding
    if held and held.target and self.tool == 'hand' then
        add({ id = 'target', kind = 'ring', progress = 1.0 }, self:wireEnd(held.target))
    end

    return #markers > 0 and markers or nil
end

function Game:meter()
    local h = self.holding
    if h and h.wire and self.tool == 'strippers' then
        local tension = math.floor(self.wires[h.wire].tension * 50 + 0.5) / 50
        return { value = tension, tone = tension > 0.6 and 'danger' or 'accent' }
    elseif h and h.crankStart then
        -- The page fills the bar by itself; a new crankStart restarts it.
        local crank = self.session.crank
        local scale = crank.closes + 800
        return { label = t('crank'), zone = { crank.opens / scale, crank.closes / scale }, duration = scale, run = h.crankStart }
    end
end

function Game:draw()
    if self.ending then return TR.ui.hud.hide() end

    local tools
    if self.stage == 'wires' then
        local found, stripped = self:progress()
        local counts = { probe = found, strippers = stripped }
        tools = {}
        for i, tool in ipairs(TOOLS) do
            local done = self:stepDone(tool)
            tools[i] = {
                key = tostring(i),
                label = t('tool_' .. tool),
                active = tool == self.tool,
                done = done,
                progress = not done and counts[tool] and ('%d/%d'):format(counts[tool], self.neededCount) or nil,
            }
        end
    end

    TR.ui.hud.set({
        hint = self:hint(),
        tools = tools,
        strikes = { label = t('strikes'), used = self.strikes, max = self.session.maxStrikes },
        meter = self:meter(),
        markers = self:markers(),
    })
end

function Game:stillDriving()
    local ped = PlayerPedId()
    return DoesEntityExist(self.vehicle) and GetPedInVehicleSeat(self.vehicle, -1) == ped and not IsEntityDead(ped)
end

function Game:loop()
    while true do
        local dt = GetFrameTime()
        self.now = GetGameTimer()

        if self.ending and self.now >= self.endAt then break end
        if not self.ending and not self:stillDriving() then
            CreateThread(function() TR.callback.await('tr_minigames:hotwire:cancel') end)
            self:finish('left_vehicle')
        end

        self:controls()
        if not self.ending then self:autoAdvance() end

        if not self.ending then
            if self.stage == 'screws' then
                self:screwStep(dt)
            elseif self.stage == 'open' then
                self:openStep(dt)
            elseif self.stage == 'opening' then
                self:coverStep(dt)
            elseif self.stage == 'close' then
                self:closeStep()
            elseif self.stage == 'button' then
                self:buttonStep()
            elseif self.tool == 'probe' then
                self:probeStep()
            elseif self.tool == 'strippers' then
                self:stripStep(dt)
            else
                self:handStep()
            end
        end

        self:animate(dt)
        self.scene:update()
        self:effects()
        self:draw()
        self:soundLoops()
        self.mirror:tick(self.now)
        Wait(0)
    end
end

-- A bike: the right switch block's lower half is pulled down off the bar and hangs on the stop switch's wires.
-- Battery and ignition are found, cut, stripped and twisted, then the half is pushed back onto the bar and the start
-- button held.

local BIKE_PIECES = { sleeve = 'tr_hw_bike_sleeve_', seg = 'tr_hw_bike_seg_', copper = 'tr_hw_bike_copper', twist = 'tr_hw_bike_twist',
    strippers = 'tr_hw_bike_strippers' }
local BIKE_NEEDED = { steady = true, pulse = true } -- battery, ignition: the starter is the button
local STUB = 0.012 -- metres of a cut wire left on the lower half
local CUT_SWING = -10.0 -- degrees a cut end swings out toward the camera, free of the stub
local TUCK = vec3(0.0, -0.015, -0.012) -- where the wire ends go in the lower half as it is pushed back on
local GRAB = vec3(0.0, -0.030, -0.020) -- where the mouse pulls the lower half from, under the start button
local GRAB_MARGIN = 0.003 -- metres round the lower half's box that still take it
local ORIGIN, DOWN = vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, -1.0)
local CLEAR, CLEAR_AT = 0.036, 0.4 -- metres the half goes straight down to clear GTA's own block, at this much of its way
local PULL = 110 -- pixels the mouse pulls the half down before its clips let go
local CREEP = 0.04 -- of its way off, how far it gives before then
local SWING = 12.0 -- degrees the half swings on its wires when they catch it
local ROLL_SPRING, ROLL_DAMPING = 200.0, 8.0 -- as it swings: turning over on what is left once wires are cut
local NEAR_CLIP = 0.02 -- metres: a scripted camera's default near clip cut into the block from 20 cm away

-- A wire between two ends that is longer than the gap: bowed out along bow until it is as long as the wire.
local function bowed(a, leave, b, arrive, length, bow)
    local handle = Vec.length(b - a) / 3.0
    local p1, p2 = a + leave * handle, b + arrive * handle
    local points = bezier(a, p1, p2, b, 16)
    if pathLength(points) >= length then return points end

    local lo, hi = 0.0, length
    for _ = 1, 14 do
        local k = (lo + hi) / 2
        points = bezier(a, p1 + bow * k, p2 + bow * k, b, 16)
        if pathLength(points) > length then hi = k else lo = k end
    end
    return points
end

local function trim(points, length)
    local out, total = { points[1] }, 0.0
    for k = 2, #points do
        local step = Vec.length(points[k] - points[k - 1])
        if total + step >= length then
            out[#out + 1] = Vec.lerp(points[k - 1], points[k], step > 1e-9 and (length - total) / step or 0.0)
            return out
        end
        total = total + step
        out[#out + 1] = points[k]
    end
    return out
end

local function reversed(points)
    local out = {}
    for k = #points, 1, -1 do out[#out + 1] = points[k] end
    return out
end

-- The lower half in switch space: on the bar at shut 1, hanging at 0. It goes straight down clear of GTA's own block
-- inside ours before it swings over to hang.
local function lowerPose(shut, hung, hungRot)
    local u = 1.0 - shut
    if u <= CLEAR_AT then return vec3(0.0, 0.0, -CLEAR * u / CLEAR_AT), Mat.identity() end

    local v = (u - CLEAR_AT) / (1.0 - CLEAR_AT)
    return Vec.lerp(vec3(0.0, 0.0, -CLEAR), hung, v), Mat.blend(Mat.identity(), hungRot, v)
end

-- swing turns it about where the middle wire leaves it, roll about where what holds it leaves the upper half; it
-- comes straight again as it goes back on.
function Game:setShut(shut)
    self.shut = shut
    local pos, rot = lowerPose(shut, self.bike.hung, self.bike.hungRot)
    if self.swing ~= 0.0 then
        local pivot, turn = pos + Mat.apply(rot, BIKE.wires[2].exit), Mat.axis('x', self.swing)
        pos, rot = pivot + Mat.apply(turn, pos - pivot), Mat.mul(turn, rot)
    end
    local roll = self.roll * Clamp(1.0 - shut / (1.0 - CLEAR_AT), 0.0, 1.0)
    if roll ~= 0.0 then
        local pivot, turn = self.rollPivot, Mat.axis('y', roll)
        pos, rot = pivot + Mat.apply(turn, pos - pivot), Mat.mul(turn, rot)
    end
    self.lowerPos, self.lowerRot = pos, rot
end

-- Held by the loom and the wires still on it: once they all leave it on one side of its centre of mass, it turns over
-- under the nearest of them.
function Game:settleRoll()
    local x, near = BIKE.centre.x, BIKE.loom
    local left, right = near.exit.x <= x, near.exit.x >= x
    for i, w in ipairs(self.wires) do
        local def = BIKE.wires[i]
        if w.attached then
            left, right = left or def.exit.x <= x, right or def.exit.x >= x
            if math.abs(def.exit.x - x) < math.abs(near.exit.x - x) then near = def end
        end
    end
    if left and right then
        self.rollGoal = 0.0
        return
    end

    local d = self.bike.hung + Mat.apply(self.bike.hungRot, BIKE.centre) - near.top
    local down = Vec.unrotate(self.S, DOWN)
    self.rollGoal = math.deg(AngleDelta(math.atan(d.x, d.z), math.atan(down.x, down.z)))
    self.rollPivotGoal = near.top
end

-- The mouse is over the lower half: the ray under it meets the half's box.
function Game:overLower()
    local origin, dir = self.scene:ray(self.mx, self.my)
    local o, d = self:fromLower(origin), Vec.unrotate(self.lowerRot, Vec.unrotate(self.S, dir))
    local near, far = 0.0, math.huge
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local lo, hi = BIKE.bounds[1][axis] - GRAB_MARGIN, BIKE.bounds[2][axis] + GRAB_MARGIN
        if math.abs(d[axis]) < 1e-9 then
            if o[axis] < lo or o[axis] > hi then return false end
        else
            local a, b = (lo - o[axis]) / d[axis], (hi - o[axis]) / d[axis]
            near, far = math.max(near, math.min(a, b)), math.min(far, math.max(a, b))
        end
    end
    return near <= far
end

function Game:toLower(p) return self:toRig(self.lowerPos + Mat.apply(self.lowerRot, p)) end

function Game:fromLower(p) return Vec.unrotate(self.lowerRot, Vec.unrotate(self.S, p) - self.lowerPos) end

-- From the whole wire, hanging, to just what spans the gap as the half goes back on: the rest is inside the halves.
function Game:attachedShape(def)
    local exit = self:toLower(def.exit)
    local length = Lerp(BIKE.wireLength, Vec.length(exit - def.top) * 1.05, self.shut)
    return bowed(def.top, self:toRig(DOWN), exit, Vec.normalize(def.top - exit), length, def.bow)
end

-- A cut wire's end pushed into the lower half with it, once the half comes near enough for it to reach; a twisted
-- pair goes in as it was twisted. Returns the shape and how far the wire has gone over to it, 0 to 1.
function Game:tuckedShape(i)
    local w = self.wires[i]
    local goal = self:toLower(TUCK + vec3((i - 2) * 0.005, 0.0, 0.0))
    if w.twisted then
        local a, b = self.wires[self.twistWires[1]], self.wires[self.twistWires[2]]
        goal = self:toLower(TUCK) + w.endGoal - (a.endGoal + b.endGoal) * 0.5
    end
    local gap = Vec.length(goal - w.def.top)
    local length = Lerp(w.length, gap * 1.05, self.shut)
    local shape = bowed(w.def.top, self:toRig(DOWN), goal, Vec.normalize(w.def.top - goal), length, w.def.bow)
    return shape, Clamp((w.length * 0.95 - gap) / (w.length * 0.25), 0.0, 1.0)
end

---Sets the bike's pieces in its rig. Returns its wires, each resting the way it hangs once cut.
function Game:bikeWires()
    self.S = self.bike.S
    self.pieces, self.needed, self.neededCount = BIKE_PIECES, BIKE_NEEDED, 2
    self.links, self.linkLength = math.ceil(BIKE.wireLength / BIKE.segmentLength) + 2, BIKE.segmentLength
    self.sleeveLength, self.copperLength, self.twistGap = BIKE.sleeveLength, BIKE.copperLength, BIKE.wireRadius * 2.0
    self.stubs, self.swing = {}, 0.0
    self.roll, self.rollVel, self.rollGoal, self.rollPivot, self.rollPivotGoal = 0.0, 0.0, 0.0, BIKE.loom.top, BIKE.loom.top
    self:setShut(0.0)

    local defs, tipY, tops = {}, 0.0, vec3(0.0, 0.0, 0.0)
    local bow = BIKE.wireBow
    -- Spread by x like the wires.
    self.loom = { top = self:toRig(BIKE.loom.top), exit = BIKE.loom.exit,
        bow = self:toRig(Vec.normalize(vec3(bow.x * BIKE.loom.top.x / BIKE.wires[3].top.x, bow.y, bow.z))) }
    for i, w in ipairs(BIKE.wires) do
        local def = { color = w.color, top = self:toRig(w.top), exit = w.exit, path = {},
            bow = self:toRig(Vec.normalize(vec3(bow.x * (i - 2), bow.y, bow.z))) }
        for k, p in ipairs(trim(self:attachedShape(def), BIKE.wireLength - STUB - self.sleeveLength)) do
            def.path[k] = p - def.top
        end
        def.tip = def.path[#def.path]
        tipY = tipY + (def.top.y + def.tip.y) / #BIKE.wires
        tops = tops + def.top * (1.0 / #BIKE.wires)
        defs[i] = def
    end
    self.tipY = tipY
    self.toolRest = tops + vec3(0.0, -0.03, -0.05)
    return defs
end

-- The fits are measured with the bars straight: wait for them to come back with the controls off.
function Game:straightenBars()
    local deadline = GetGameTimer() + 1500
    while math.abs(GetVehicleSteeringAngle(self.vehicle)) > 1.0 and GetGameTimer() < deadline do
        DisableAllControlActions(0)
        Wait(0)
    end
end

function Game:setupBike()
    local models = { 'tr_hw_bike_switch', 'tr_hw_bike_switch_lower', 'tr_hw_bike_start', 'tr_hw_bike_loom_seg', 'tr_hw_probe',
        'tr_hw_probe_glow', BIKE_PIECES.strippers, BIKE_PIECES.copper, BIKE_PIECES.twist }
    for _, w in ipairs(BIKE.wires) do
        models[#models + 1] = BIKE_PIECES.sleeve .. w.color
        models[#models + 1] = BIKE_PIECES.seg .. w.color
    end
    self.scene:preload(models)
    self:straightenBars()

    local scene, bike, session, fov = self.scene, self.bike, self.session, cfg.camera.fov
    -- Hotwired before and the engine turned off: the half is back on, battery and ignition twisted inside. Taken off
    -- and given up on: it still hangs.
    local hanging = session.coverOff and not session.twisted
    self:setShut(hanging and 0.0 or 1.0)

    scene:spawn('switch', 'tr_hw_bike_switch', ORIGIN, bike.S)
    scene:spawn('lower', 'tr_hw_bike_switch_lower')
    scene:spawn('start', 'tr_hw_bike_start')
    self:placeLower()

    if session.twisted then
        self.stage = 'button'
        scene:createCamera(bike.button[1], bike.button[2], fov)
        self:flash(t('rewired_bike'), 'default', 2600)
    elseif hanging then
        scene:createCamera(bike.wires[1], bike.wires[2], fov)
        self:spawnWires()
        self:startWires()
    else
        scene:createCamera(bike.open[1], bike.open[2], fov)
    end
    SetCamNearClip(scene.cam, NEAR_CLIP)

    SetVehicleEngineOn(self.vehicle, false, true, true)
end

-- Links along points, the last one ending on the last point.
function Game:layLinks(id, points, model, length)
    local scene = self.scene
    for n = 1, #points - 1 do
        local name = id .. n
        local link = scene:get(name) or scene:spawn(name, model)
        local rot = linkRot(points[n + 1] - points[n])
        link.rot = rot
        link.pos = n == #points - 1 and points[n + 1] + Mat.apply(rot, vec3(0.0, 0.0, length)) or points[n]
    end
end

-- Pushed back on, a stub bends up into the upper half with the rest.
function Game:drawStub(i)
    local n, exit = self:linkCount(STUB), BIKE.wires[i].exit
    local fold = Clamp(self.shut / (1.0 - CLEAR_AT), 0.0, 1.0)
    local points = {}
    for k, p in ipairs(resample(self.stubs[i], n)) do
        points[k] = self:toLower(Vec.lerp(p, exit + vec3(0.0, 0.0, STUB * (k - 1) / n), fold))
    end
    self:layLinks(('stub%d_'):format(i), points, self.pieces.seg .. self.wires[i].def.color, self.linkLength)
end

function Game:placeLower()
    local scene, rot = self.scene, self:toRigRot(self.lowerRot)
    local lower, start = scene:get('lower'), scene:get('start')
    lower.pos, lower.rot = self:toLower(ORIGIN), rot
    start.pos, start.rot = self:toLower(BIKE.start), rot
    for i in pairs(self.stubs) do self:drawStub(i) end
    self:layLinks('loom', resample(self:attachedShape(self.loom), self:linkCount(BIKE.wireLength)), 'tr_hw_bike_loom_seg',
        self.linkLength)
end

-- Where on the screen the mouse has to go to move the half from shut a to shut b: from, and the way as a unit.
function Game:screenWay(a, b)
    local pos, rot = lowerPose(a, self.bike.hung, self.bike.hungRot)
    local ax, ay = self.scene:project(self:toRig(pos + Mat.apply(rot, GRAB)))
    pos, rot = lowerPose(b, self.bike.hung, self.bike.hungRot)
    local bx, by = self.scene:project(self:toRig(pos + Mat.apply(rot, GRAB)))
    if not ax or not bx then return end

    local w, hgt = GetActiveScreenResolution()
    local dx, dy = (bx - ax) * w, (by - ay) * hgt
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1.0 then return end
    return { x = dx / length, y = dy / length, length = length }
end

-- Held on the half, the mouse pulls it down the way it comes off; its clips give a little, then let go. Let go before
-- that and it springs back.
function Game:openStep(dt)
    if self.pending then return end
    local scene, h = self.scene, self.holding

    if h and not self.down then
        self.holding, h = nil, nil
    end

    if not h then
        self:setShut(math.min(1.0, self.shut + dt * CREEP * 5.0))
        local over = scene:cameraSettled() and self:overLower()
        self.cursor = over and 3 or 1
        local way = over and self.pressed and self:screenWay(1.0, 1.0 - CREEP)
        if way then self.holding = { x = self.mx, y = self.my, shut = self.shut, way = way } end
        return
    end

    self.cursor = 4
    local w, hgt = GetActiveScreenResolution()
    local pulled = ((self.mx - h.x) * w * h.way.x + (self.my - h.y) * hgt * h.way.y) / PULL
    self:setShut(Clamp(h.shut - pulled * CREEP, 1.0 - CREEP, 1.0))

    if self.shut <= 1.0 - CREEP then
        self.holding = nil
        self:request(function() self:openCover() end, 'tr_minigames:hotwire:cover')
    end
end

function Game:anyAttached()
    for _, w in ipairs(self.wires) do
        if w.attached then return true end
    end
    return false
end

function Game:cutPoint(i)
    local points = trim(self.wires[i].points, BIKE.wireLength - STUB)
    return points[#points]
end

-- The cut end keeps the shape it hung in and swings out free of the stub, which stays on the lower half.
function Game:cutWire(i)
    local w = self.wires[i]
    local stub = {}
    for k, p in ipairs(trim(reversed(self:attachedShape(w.def)), STUB)) do stub[k] = self:fromLower(p) end
    self.stubs[i] = stub
    self:drawStub(i)

    w.attached, w.swingAge = false, 0.0
    self:shapeWire(i)
    self.scene:spawn('sleeve' .. i, self.pieces.sleeve .. w.def.color, self:wireTip(i), self:wireRot(i))
    self:settleRoll()
    sound('snip')
end

function Game:hideTools()
    for name in pairs(TOOL_MODELS) do self.scene:setVisible(name, false) end
    self.scene:setVisible('glow', false)
end

-- Held on the half, the mouse pushes it along its way back up as far as it moves on the screen; let go, it drops.
function Game:closeStep()
    local h = self.holding

    if h and not self.down then
        self.holding, h = nil, nil
    end

    if not h then
        local over = self:overLower()
        self.cursor = over and 3 or 1
        local way = over and self.pressed and self:screenWay(0.0, 1.0)
        if way then self.holding = { x = self.mx, y = self.my, shut = self.shut, way = way } end
        return
    end

    self.cursor = 4
    local w, hgt = GetActiveScreenResolution()
    local pushed = ((self.mx - h.x) * w * h.way.x + (self.my - h.y) * hgt * h.way.y) / h.way.length
    self:setShut(Clamp(h.shut + pushed, 0.0, 1.0))

    if self.shut >= 0.97 then
        sound('bike_snap')
        self:toSwitch()
    end
end

function Game:buttonFace()
    return self:toLower(BIKE.start)
end

function Game:pressButton(down)
    local button = self.scene:get('start')
    if not button then return end
    button.pos = self:toLower(BIKE.start + vec3(0.0, down and BIKE.startTravel or 0.0, 0.0))
    sound('bike_button')
end

function Game:toSwitch()
    self.swing, self.swingAge = 0.0, nil
    self:setShut(1.0)
    self.stage, self.holding = 'button', nil
    self.scene:moveCamera(self.bike.button[1], self.bike.button[2])
end

function Game:buttonStep()
    local scene, h = self.scene, self.holding

    if not h then
        local x, y = scene:project(self:buttonFace())
        local over = x and scene:cameraSettled() and Scene.pixels(x, y, self.mx, self.my) < 30
        self.cursor = over and 3 or 1
        if over and self.pressed then
            self.holding = { crankStart = self.now }
            self:pressButton(true)
            ShakeCam(scene.cam, 'ROAD_VIBRATION_SHAKE', 0.4)
        end
        return
    end

    self.cursor = 4
    local held = self.now - h.crankStart
    if not self.down or held > self.session.crank.closes + 600 then
        StopCamShaking(scene.cam, false)
        self.holding = nil
        self:pressButton(false)
        self:request(function(result) self:onCrank(result) end, 'tr_minigames:hotwire:button', math.floor(held))
    end
end

function Game:animateBike(dt)
    if self.closeAt and self.now >= self.closeAt then
        self.closeAt = nil
        self.stage, self.holding = 'close', nil
        self:hideTools()
    end

    if self.stage == 'close' and not self.holding and self.shut > 0.0 then
        self:setShut(math.max(0.0, self.shut - dt * 2.5))
        if self.shut == 0.0 then self.swingAge = 0.0 end
    end

    if self.swingAge then
        self.swingAge = self.swingAge + dt
        local a = self.swingAge
        if a >= 1.2 or self.holding then
            self.swing, self.swingAge = 0.0, nil
        else
            self.swing = SWING * math.exp(-4.0 * a) * math.sin(14.0 * a)
        end
        self:setShut(self.shut)
    end

    if self.roll ~= self.rollGoal or self.rollVel ~= 0.0 then
        local step = math.min(dt, 0.05)
        self.rollVel = self.rollVel + ((self.rollGoal - self.roll) * ROLL_SPRING - self.rollVel * ROLL_DAMPING) * step
        self.roll = self.roll + self.rollVel * step
        self.rollPivot = Vec.lerp(self.rollPivot, self.rollPivotGoal, Clamp(step * 8.0, 0.0, 1.0))
        if math.abs(self.rollGoal - self.roll) < 0.05 and math.abs(self.rollVel) < 0.5 then
            self.roll, self.rollVel, self.rollPivot = self.rollGoal, 0.0, self.rollPivotGoal
        end
        self:setShut(self.shut)
    end

    for _, w in ipairs(self.wires) do
        if w.swingAge then
            w.swingAge = w.swingAge + dt
            local a = w.swingAge
            w.flop = CUT_SWING * (1.0 - math.exp(-4.0 * a) * math.cos(10.0 * a))
            if a > 1.5 then w.flop, w.swingAge = CUT_SWING, nil end
        end
    end

    if self.shut ~= self.placedShut or self.swing ~= self.placedSwing or self.roll ~= self.placedRoll then
        self.placedShut, self.placedSwing, self.placedRoll = self.shut, self.swing, self.roll
        self:placeLower()
    end
end

Hotwire.Game = Game -- for tests

-- result: 'started', 'failed' (extra: the item broke), 'cancelled' or why the attempt ended
---@return string result, any extra
function Hotwire.run(vehicle, session)
    local game = Game.new(vehicle, session)
    game.mirror = Mirror.sender(game.scene, 'hotwire')
    game.scene.mirror = game.mirror
    Hotwire.current = game
    local ok, err = pcall(function()
        game:setup()
        game:loop()
    end)

    game.running = false
    Hotwire.current = nil
    game.mirror:stop()
    game:cleanup()

    if not ok then
        TR.log.error('hotwire minigame failed: %s', err)
        CreateThread(function() TR.callback.await('tr_minigames:hotwire:cancel') end)
        return tostring(err):find('model') and 'missing_models' or 'try_again'
    end

    return game.result, game.extra
end

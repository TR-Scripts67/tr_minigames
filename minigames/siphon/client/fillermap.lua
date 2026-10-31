-- Flank space as in the probe: u along the car, v up, h out of the flank.
-- h nil is missing: s.hole (a gap, the wheel arch, glass) or s.blocked (something in the way).

FillerMap = {}

local TURN = math.atan(0.5) -- rows at this angle: a seam along or up the car crosses each row somewhere else
local RIM = 0.012           -- a gap shows only under the rim; under the rest it's hidden
local RING_IN = 0.0015      -- metres in from the rim
local RING_STEP = 0.0025    -- so a panel gap running out from under the bezel can't slip between
local CLEAR = 0.008         -- so its markers and the ring's can go in one look
local SEAM = 0.0012         -- metres off the paint's own curve under the rim: a lip, a body line, a seam
local ROOM_STEP = 0.01      -- an opening, glass or a flare can't slip between

local SEED = 0.05           -- metres: the skin grows from the outermost paint of columns this close to the usual level
local LEAN = 0.8            -- of the spacing (under 40 degrees)
local CLIMB, BEND = 1.7, 0.012 -- 60 degrees where the surface goes on as it was going
local STEEP = 1.19          -- 50 degrees: over the shoulder
local GAP = 0.25            -- metres over the tyre: the wheel arch's top
local LIFTED = 0.60         -- on a lifted body
-- From where the 36 hand fits are.
local BEHIND = 0.9          -- tyre radii behind the wheel's middle
local FORWARD = 0.4         -- and never less
local OVER_ARCH = 0.15      -- metres over the wheel arch's top
local UNDER_TOP = 0.085     -- metres under the panel's top at least
local AHEAD, BACK, UP = 0.12, 0.25, 0.035 -- each costs the same (how far the hand fits are from there each way)

local NEAR = 0.2            -- metres along and up the flank
local PAST_BONE = 0.15      -- metres past it (the frame, the cab through a door opening are further)
local FLAT = 10.0           -- a mm off a plane under the bezel costs as much as a cm further from the bone
local ROWS = 0.07           -- metres from the height of the place nearest the bone

local function median(list)
    if #list == 0 then return end
    table.sort(list)
    local n = #list
    if n % 2 == 1 then return list[(n + 1) // 2] end
    return (list[n // 2] + list[n // 2 + 1]) * 0.5
end

-- The bezel rests on the middle of a bulge. nil if too few samples.
local function lift(samples, c, radius)
    if #samples < 10 then return end
    local coef = DoorMap.leastSquares(samples, function(u, v)
        local du, dv = u - c.u, v - c.v
        return { 1.0, du, dv, du * du, du * dv, dv * dv }
    end, function() return true end)
    if not coef then return end
    local p, q, r = coef[4], coef[5], coef[6]
    local most = p + r - math.sqrt((p - r) ^ 2 + q * q) -- the most convex way: h = most / 2 * t^2 along it
    return math.max(0.0, -most) * radius * radius * 0.5
end

-- add(s) puts a sample in, skip(s) never go in. steep: also up a steep panel where it goes on as it was going.
local function grow(map, queue, isIn, add, skip, steep)
    local step, at = map.step, map.at
    local carry = math.max(0.02, step * LEAN)
    local function sample(i, j)
        local column = at[i]
        return column and column[j]
    end
    local function joins(s, n, di, dj)
        if not n or isIn(n) or not n.h or skip(n) then return false end
        local rise = math.abs(n.h - s.h)
        if rise <= carry then return true end
        if not steep or rise > step * CLIMB then return false end
        local behind = sample(s.i - di, s.j - dj)
        if behind and isIn(behind) and behind.h and math.abs(n.h - (2.0 * s.h - behind.h)) <= BEND then return true end
        local past = sample(n.i + di, n.j + dj)
        return past ~= nil and past.h ~= nil and not skip(past) and math.abs(past.h - 2.0 * n.h + s.h) <= BEND
    end
    local ways = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
    repeat
        local grew, head = false, 1
        while head <= #queue do
            local s = queue[head]
            head = head + 1
            for _, way in ipairs(ways) do
                local n = sample(s.i + way[1], s.j + way[2])
                if joins(s, n, way[1], way[2]) then
                    add(n)
                    grew = true
                    queue[#queue + 1] = n
                end
            end
        end
        -- Again from all of it, so a sample in line with skin joins whichever way the growth got there.
        queue = {}
        if grew then
            for _, s in ipairs(map.samples) do
                if isIn(s) then queue[#queue + 1] = s end
            end
        end
    until not grew
end

-- A map this coarse can't see a tight curve or a body line; the close look can, and then tries the others.
local function withOthers(fitting, opts)
    local best = fitting[1]
    best.others = {}
    local apart = opts.apart or 0.12
    for _, c in ipairs(fitting) do
        if #best.others >= (opts.others or 2) then break end
        local alone = (c.u - best.u) ^ 2 + (c.v - best.v) ^ 2 >= apart * apart
        for _, o in ipairs(best.others) do
            if (c.u - o.u) ^ 2 + (c.v - o.v) ^ 2 < apart * apart then alone = false end
        end
        if alone then best.others[#best.others + 1] = c end
    end
    return best
end

-- Not on the tyre, the arch or its lip, a door or window opening, a crease or over the shoulder.
-- Nearest where a filler usually is: over the back of the arch, 15 cm over it, further back sooner than forward.
---@param map table
---@param wheel { u: number, v: number, r: number } the rear wheel's middle and its tyre's radius
---@param opts? { bezel?: number, room?: number, rough?: number, maxTilt?: number, maxTurn?: number, maxDown?: number, rearmost?: number }
---@return table? place { u, v, h, plane, cost, fits, target = { u, v }, archTop, arch, panelTop }, or nil and why (arch: 'lifted' or 'guessed' if not the usual)
function FillerMap.place(map, wheel, opts)
    opts = opts or {}
    local step, at = map.step, map.at
    local columns = #at
    local clear = (opts.bezel or 0.053) + (opts.room or 0.02) -- from the bezel's middle to anything that isn't skin
    local rough = opts.rough or 0.007
    local maxTilt = math.tan(math.rad(opts.maxTilt or 45.0))
    local maxTurn = math.tan(math.rad(opts.maxTurn or 35.0))
    local maxDown = math.tan(math.rad(opts.maxDown or opts.maxTilt or 45.0))
    local tyreTop = wheel.v + wheel.r

    -- The tyre, wheel well, door or window openings and the cabin are a step in from the skin. On a steep panel
    -- each row is more than that in from the last, so it also carries on in line with the skin behind.
    -- The tyre is never skin, however near the paint it is (or however far in the sill tucks).
    local function tyre(s)
        local u, v = s.h and s.u or s.gu, s.h and s.v or s.gv
        return (u - wheel.u) ^ 2 + (v - wheel.v) ^ 2 < (wheel.r + 0.01) ^ 2
    end
    local outer, all = {}, {}
    for i = 1, columns do
        for _, s in ipairs(at[i]) do
            s.skin = false
            if s.h and s.gv >= wheel.v + wheel.r * 0.5 and not tyre(s) and (not outer[i] or s.h > outer[i]) then outer[i] = s.h end
        end
        if outer[i] then all[#all + 1] = outer[i] end
    end
    local typical = median(all)
    if not typical then return nil, 'found no paint on the rear quarter' end
    local queue = {}
    for i = 1, columns do
        if outer[i] and outer[i] >= typical - SEED then
            for _, s in ipairs(at[i]) do
                if s.h and s.gv >= wheel.v + wheel.r * 0.5 and s.h >= outer[i] - 0.01 and not tyre(s) then
                    s.skin = true
                    queue[#queue + 1] = s
                end
            end
        end
    end
    grow(map, queue, function(s) return s.skin end, function(s) s.skin = true end, tyre, true)

    -- Anything that isn't skin is placed where its line of sight crosses the skin's usual depth.
    local function where(s)
        if s.skin then return s.u, s.v end
        local depth = -math.max(typical, s.h or typical)
        return s.gu + (s.du or 0.0) * depth, s.gv + (s.dv or 0.0) * depth
    end

    -- On a lifted body the gap over the tyre is far taller, so LIFTED is tried, else a guess.
    local tops, lifted, by = {}, {}, 0
    for i = 1, columns do
        local column = at[i]
        if math.abs(column[1].gu - wheel.u) <= wheel.r * 0.4 then
            by = by + 1
            for j, s in ipairs(column) do
                if s.gv > tyreTop and s.skin then
                    local below = column[j - 1]
                    local top = math.max(tyreTop, below and (s.gv + below.gv) * 0.5 or s.gv)
                    if s.gv <= tyreTop + GAP then
                        tops[#tops + 1] = top
                    elseif s.gv <= tyreTop + LIFTED then
                        local last = s
                        for k = j + 1, #column do
                            if not column[k].skin then break end
                            last = column[k]
                        end
                        if last.gv - s.gv + step >= 2.0 * clear then lifted[#lifted + 1] = top end
                    end
                    break
                end
            end
        end
    end
    local archTop, arch = median(tops), nil
    if not archTop and #lifted > 0 and #lifted * 2 >= by then archTop, arch = median(lifted), 'lifted' end
    if not archTop then archTop, arch = tyreTop + 0.06, 'guessed' end

    -- Only columns where the panel is tall enough for the bezel and its room: over a door opening there's just the lip.
    local targetU = wheel.u - BEHIND * wheel.r
    local panels = {}
    for i = 1, columns do
        local first, top
        for _, s in ipairs(at[i]) do
            if s.gv >= archTop - step * 0.5 then
                if not s.skin or (top and top.h - s.h > STEEP * math.max(0.001, s.v - top.v)) then break end
                first, top = first or s, s
            end
        end
        if top and top.gv - first.gv + step >= 2.0 * clear then panels[#panels + 1] = { u = top.gu, top = top.gv + step * 0.5 } end
    end
    table.sort(panels, function(a, b) return math.abs(a.u - targetU) < math.abs(b.u - targetU) end)
    local near = {}
    for k = 1, math.min(5, #panels) do near[k] = panels[k].top end
    local panelTop = median(near) or (archTop + 0.35)

    -- Skin's edge is somewhere between a skin sample and the next, so anything else has to be half a step further off.
    local need = clear + step * 0.5
    local target = { u = targetU, v = math.max(math.min(panelTop - UNDER_TOP, archTop + OVER_ARCH), archTop + need) }
    local u0, v0 = at[1][1].gu, at[1][1].gv
    local u1, v1 = at[columns][1].gu, at[1][#at[1]].gv
    local span = math.ceil((need + 0.05) / step) + 1 -- lines of sight seen at an angle land a few centimetres off their grid
    local fitting = {}
    for cu = math.max(u0 + need, opts.rearmost or -math.huge), math.min(u1 - need, wheel.u - wheel.r * FORWARD), 0.015 do
        for cv = tyreTop, math.min(v1 - need, panelTop), 0.015 do
            local ci, cj = math.floor((cu - u0) / step + 0.5) + 1, math.floor((cv - v0) / step + 0.5) + 1
            local under, whole = {}, true
            for i = math.max(1, ci - span), math.min(columns, ci + span) do
                local column = at[i]
                for j = math.max(1, cj - span), math.min(#column, cj + span) do
                    local s = column[j]
                    local su, sv = where(s)
                    if (su - cu) ^ 2 + (sv - cv) ^ 2 <= need * need then
                        if not s.skin then whole = false break end
                        under[#under + 1] = s
                    end
                end
                if not whole then break end
            end
            local plane = whole and #under >= 5 and DoorMap.fitPlane(under)
            -- plane.c > 0: it leans out going up, facing the ground
            if plane and plane.worst <= rough and -plane.c <= maxTilt and plane.c <= maxDown and math.abs(plane.b) <= maxTurn then
                fitting[#fitting + 1] = {
                    u = cu, v = cv, h = plane.a + plane.b * cu + plane.c * cv, plane = plane,
                    cost = ((cu - target.u) / (cu > target.u and AHEAD or BACK)) ^ 2 + ((cv - target.v) / UP) ^ 2 + plane.worst * 20.0,
                }
            end
        end
    end
    if #fitting == 0 then return nil, 'no plain panel on the rear quarter big enough for the filler' end
    table.sort(fitting, function(a, b) return a.cost < b.cost end)

    local best = withOthers(fitting, opts)
    best.fits, best.target, best.archTop, best.arch, best.panelTop = #fitting, target, archTop, arch, panelTop
    return best
end

-- A lorry's bone is on its side tank, at its end or inside it; the tank is a curve with straps and a step on it.
-- With opts.middle the place nearest the middle of that surface along the car wins (FillerMap.run).
---@param map table
---@param anchor { u: number, v: number, h: number }
---@param opts? { bezel?: number, room?: number, rough?: number, maxTilt?: number, maxTurn?: number, maxDown?: number, apart?: number, others?: number, middle?: boolean }
---@return table? place { u, v, h, cost, fits, away, target = { u, v }, tank, others }, or nil and why (away: how far the bone is from that surface; tank: FillerMap.run's, with opts.middle)
function FillerMap.nearest(map, anchor, opts)
    opts = opts or {}
    local step, at = map.step, map.at
    local columns = #at
    local clear = (opts.bezel or 0.053) + (opts.room or 0.02)
    local rough = opts.rough or 0.007
    local maxTilt = math.tan(math.rad(opts.maxTilt or 45.0))
    local maxTurn = math.tan(math.rad(opts.maxTurn or 35.0))
    local maxDown = math.tan(math.rad(opts.maxDown or opts.maxTilt or 45.0))

    local near = {}
    for _, s in ipairs(map.samples) do
        s.skin, s.piece = false, nil
        if s.h and s.h >= anchor.h - PAST_BONE and (s.u - anchor.u) ^ 2 + (s.v - anchor.v) ^ 2 <= NEAR * NEAR then
            s.away = math.sqrt((s.u - anchor.u) ^ 2 + (s.v - anchor.v) ^ 2 + (s.h - anchor.h) ^ 2)
            near[#near + 1] = s
        end
    end
    if #near == 0 then
        return nil, ('found no paint within %d cm of the bone (short of %d cm further into the car)'):format(math.floor(NEAR * 100 + 0.5), math.floor(PAST_BONE * 100 + 0.5))
    end
    table.sort(near, function(a, b) return a.away < b.away end)

    -- A step on the tank is one surface, its face another.
    local pieces = {}
    for _, seed in ipairs(near) do
        if not seed.piece then
            local k = #pieces + 1
            local piece = { seed, away = seed.away }
            seed.piece = k
            grow(map, { seed }, function(s) return s.piece == k end, function(s)
                s.piece = k
                piece[#piece + 1] = s
            end, function(s) return s.piece ~= nil and s.piece ~= k end)
            pieces[k] = piece
        end
    end

    -- As in FillerMap.place, anything not on it is where its line of sight crosses its usual depth.
    local need = clear + step * 0.5
    local span = math.ceil((need + 0.05) / step) + 1
    local u0, v0 = at[1][1].gu, at[1][1].gv
    local u1, v1 = at[columns][1].gu, at[1][#at[1]].gv
    local function quadratic(cu, cv)
        return function(u, v)
            local du, dv = u - cu, v - cv
            return { 1.0, du, dv, du * du, du * dv, dv * dv }
        end
    end
    local function places(k, piece)
        local fitting = {}
        local depths, lu, hu, lv, hv = {}, math.huge, -math.huge, math.huge, -math.huge
        for _, s in ipairs(piece) do
            depths[#depths + 1] = s.h
            lu, hu, lv, hv = math.min(lu, s.u), math.max(hu, s.u), math.min(lv, s.v), math.max(hv, s.v)
        end
        local typical = median(depths)
        local function where(s)
            if s.piece == k then return s.u, s.v end
            local depth = -math.max(typical, s.h or typical)
            return s.gu + (s.du or 0.0) * depth, s.gv + (s.dv or 0.0) * depth
        end
        for cu = math.max(u0, lu) + need, math.min(u1, hu) - need, 0.015 do
            for cv = math.max(v0, lv) + need, math.min(v1, hv) - need, 0.015 do
                local ci, cj = math.floor((cu - u0) / step + 0.5) + 1, math.floor((cv - v0) / step + 0.5) + 1
                local under, whole = {}, true
                for i = math.max(1, ci - span), math.min(columns, ci + span) do
                    local column = at[i]
                    for j = math.max(1, cj - span), math.min(#column, cj + span) do
                        local s = column[j]
                        local su, sv = where(s)
                        if (su - cu) ^ 2 + (sv - cv) ^ 2 <= need * need then
                            if s.piece ~= k then whole = false break end
                            under[#under + 1] = s
                        end
                    end
                    if not whole then break end
                end
                local terms = quadratic(cu, cv)
                local coef = whole and #under >= 10 and DoorMap.leastSquares(under, terms, function() return true end)
                if coef then
                    local worst, bezel = 0.0, {}
                    for _, s in ipairs(under) do
                        local t, h = terms(s.u, s.v), 0.0
                        for n = 1, 6 do h = h + coef[n] * t[n] end
                        worst = math.max(worst, math.abs(s.h - h))
                        if (s.u - cu) ^ 2 + (s.v - cv) ^ 2 <= (need - (opts.room or 0.02)) ^ 2 then bezel[#bezel + 1] = s end
                    end
                    -- leaning out going up: facing the ground
                    local turn, lean = coef[2], coef[3]
                    -- On a tank of flat faces, a face's middle beats the corner between two.
                    local plane = DoorMap.fitPlane(bezel)
                    if plane and worst <= rough and math.abs(turn) <= maxTurn and -lean <= maxTilt and lean <= maxDown then
                        fitting[#fitting + 1] = {
                            u = cu, v = cv, h = coef[1], worst = worst, flat = plane.worst,
                            cost = math.sqrt((cu - anchor.u) ^ 2 + (cv - anchor.v) ^ 2) + plane.worst * FLAT,
                        }
                    end
                end
            end
        end
        return fitting
    end

    local best, on
    for k, piece in ipairs(pieces) do
        local fitting = places(k, piece)
        if #fitting > 0 then
            table.sort(fitting, function(a, b) return a.cost < b.cost end)
            if not best or piece.away + fitting[1].cost < best.away + best.fitting[1].cost then
                best, on = { away = piece.away, fitting = fitting }, k
            end
        end
    end
    if not best then return nil, ('no smooth surface near the bone big enough for the filler (%d tried)'):format(#pieces) end
    local target, tank = { u = anchor.u, v = anchor.v }, nil
    if opts.middle then
        tank = FillerMap.run(map, on, best.fitting[1])
        if tank then
            target = { u = tank.middle, v = best.fitting[1].v }
            for _, c in ipairs(best.fitting) do
                c.cost = math.sqrt((c.u - target.u) ^ 2 + (c.v - target.v) ^ 2) + c.flat * FLAT
            end
            table.sort(best.fitting, function(a, b) return a.cost < b.cost end)
        end
    end
    local place = withOthers(best.fitting, opts)
    for _, s in ipairs(map.samples) do s.skin = s.piece == on end
    place.fits, place.away, place.target, place.tank = #best.fitting, best.away, target, tank
    return place
end

-- Returns { lo, hi, middle, rows, openLo, openHi } (open: ran to the map's end that way), or nil if no row has it.
-- One sample off the surface doesn't end it: a strap, a bolt.
function FillerMap.run(map, k, at)
    local step, cols = map.step, map.at
    local columns = #cols
    local function on(i, j) return i >= 1 and i <= columns and cols[i][j].piece == k end
    local los, his, openLo, openHi = {}, {}, 0, 0
    for j, s in ipairs(cols[1]) do
        local ci, nearest = nil, step * 1.5
        if math.abs(s.gv - at.v) <= ROWS then
            for i = 1, columns do
                local d = on(i, j) and math.abs(cols[i][j].u - at.u)
                if d and d < nearest then ci, nearest = i, d end
            end
        end
        if ci then
            local lo, hi = ci, ci
            while on(lo - 1, j) or on(lo - 2, j) do lo = on(lo - 1, j) and lo - 1 or lo - 2 end
            while on(hi + 1, j) or on(hi + 2, j) do hi = on(hi + 1, j) and hi + 1 or hi + 2 end
            los[#los + 1] = cols[lo][j].u - step * 0.5
            his[#his + 1] = cols[hi][j].u + step * 0.5
            if lo == 1 then openLo = openLo + 1 end
            if hi == columns then openHi = openHi + 1 end
        end
    end
    if #los == 0 then return end
    local rows = #los
    local lo, hi = median(los), median(his)
    return { lo = lo, hi = hi, middle = (lo + hi) * 0.5, rows = rows, openLo = openLo * 2 > rows, openHi = openHi * 2 > rows }
end

-- Worse for each sample a little further out without paint or off the bezel's plane (the arch's lip, a door's edge).
---@param map table a DoorMap grid, measured
---@param anchor { u: number, v: number }
---@param opts? { halfU?: number, halfV?: number, step?: number, radius?: number, room?: number, rough?: number, weight?: number, count?: number, apart?: number, maxTilt?: number, maxTurn?: number, uneven?: number }
---@return { u: number, v: number, distance: number, rough: number, plane: table }[]
function FillerMap.spots(map, anchor, opts)
    opts = opts or {}
    local halfU, halfV, step = opts.halfU or 0.07, opts.halfV or 0.045, opts.step or 0.01
    local radius, rough = opts.radius or 0.053, opts.rough or 0.006
    local count, apart = opts.count or 3, opts.apart or 0.025
    local maxTilt = math.tan(math.rad(opts.maxTilt or 45.0))
    local maxTurn = math.tan(math.rad(opts.maxTurn or 35.0))
    local reach = radius + map.step * 0.5 -- a sample this close stands for paint that may be under the rim
    local around = reach + (opts.room or 0.0)
    -- A slanting line of sight may find glass or an opening a little past where it was aimed.
    local keep = math.max(radius, radius + (opts.room or 0.0) - map.step * 0.5)

    local found = {}
    local nu, nv = math.floor(halfU / step + 1e-6), math.floor(halfV / step + 1e-6)
    for i = -nu, nu do
        for j = -nv, nv do
            local c = { u = anchor.u + i * step, v = anchor.v + j * step }
            local under, ring, maybe, whole = {}, {}, 0, true
            for _, s in ipairs(map.samples) do
                local du, dv = s.u - c.u, s.v - c.v
                local d2 = du * du + dv * dv
                if not s.h and d2 <= keep * keep then
                    whole = false
                    break
                elseif d2 <= reach * reach then
                    if s.h then under[#under + 1] = s else maybe = maybe + 1 end
                elseif d2 <= around * around then
                    if s.h then ring[#ring + 1] = s else maybe = maybe + 1 end
                end
            end
            local plane = whole and #under >= 6 and DoorMap.fitPlane(under)
            local curved = plane and opts.uneven and (lift(under, c, radius) or 0.0) > opts.uneven
            if plane and not curved and plane.worst <= rough and math.abs(plane.c) <= maxTilt and math.abs(plane.b) <= maxTurn then
                for _, s in ipairs(ring) do
                    if math.abs(s.h - (plane.a + plane.b * s.u + plane.c * s.v)) > rough then maybe = maybe + 1 end
                end
                c.distance = math.sqrt((i * step) ^ 2 + (j * step) ^ 2)
                c.rough, c.plane = plane.worst, plane
                c.rank = c.distance + plane.worst * (opts.weight or 8.0) + maybe * 0.01
                found[#found + 1] = c
            end
        end
    end
    table.sort(found, function(a, b) return a.rank < b.rank end)

    local out = {}
    for _, c in ipairs(found) do
        local alone = true
        for _, o in ipairs(out) do
            if (o.u - c.u) ^ 2 + (o.v - c.v) ^ 2 < apart * apart then alone = false break end
        end
        if alone then
            out[#out + 1] = c
            if #out >= count then break end
        end
    end
    return out
end

-- Refitted without what's far off it (a seam, a badge). floor: metres, default 1.5 mm. nil if too little was measured.
function FillerMap.surface(samples, c, radius, floor)
    local near = {}
    for _, s in ipairs(samples) do
        if s.h and (s.u - c.u) ^ 2 + (s.v - c.v) ^ 2 <= radius * radius then near[#near + 1] = s end
    end
    local terms
    if #near >= 10 then
        terms = function(u, v)
            local du, dv = u - c.u, v - c.v
            return { 1.0, du, dv, du * du, du * dv, dv * dv }
        end
    elseif #near >= 5 then
        terms = function(u, v) return { 1.0, u - c.u, v - c.v } end
    else
        return
    end
    local function value(coef, u, v)
        local t, h = terms(u, v), 0.0
        for k = 1, #coef do h = h + coef[k] * t[k] end
        return h
    end

    local coef
    local keep = function() return true end
    for _ = 1, 3 do
        local fit = DoorMap.leastSquares(near, terms, keep)
        if not fit then break end
        coef = fit
        local res = {}
        for k, s in ipairs(near) do res[k] = math.abs(s.h - value(fit, s.u, s.v)) end
        table.sort(res)
        local limit = math.max(floor or 0.0015, 3.0 * res[(#res + 1) // 2])
        keep = function(s) return math.abs(s.h - value(fit, s.u, s.v)) <= limit end
    end
    if not coef then return end
    return function(u, v) return value(coef, u, v) end
end

-- The lattice is laid from origin, the same on a flank, so spots close together share samples (cache).
-- Returns every sample and the ones not measured yet; gu, gv: where it was aimed.
function FillerMap.disc(cache, origin, c, radius, step, room)
    local cu, su = math.cos(TURN), math.sin(TURN)
    local du, dv = c.u - origin.u, c.v - origin.v
    local a0, b0 = (du * cu + dv * su) / step, (dv * cu - du * su) / step
    local n = math.ceil(radius / step) + 1
    local all, new = {}, {}
    local r = radius - RING_IN
    local inner = r - CLEAR

    -- Ring first: the probe packs its markers into fewer looks that way; a multiple of 12 so looks come round evenly.
    local count = 12 * math.ceil(2.0 * math.pi * r / RING_STEP / 12)
    for k = 1, count do
        local a = (k - 0.5) * 2.0 * math.pi / count
        local u, v = c.u + math.cos(a) * r, c.v + math.sin(a) * r
        local s = { u = u, v = v, gu = u, gv = v, ring = true }
        all[#all + 1] = s
        new[#new + 1] = s
    end
    if room and room > 0.0 then
        local out = radius + room
        local around = 12 * math.ceil(2.0 * math.pi * out / ROOM_STEP / 12)
        for k = 1, around do
            local a = (k - 0.5) * 2.0 * math.pi / around
            local u, v = c.u + math.cos(a) * out, c.v + math.sin(a) * out
            local s = { u = u, v = v, gu = u, gv = v, room = true }
            all[#all + 1] = s
            new[#new + 1] = s
        end
    end

    for a = math.floor(a0) - n, math.ceil(a0) + n do
        for b = math.floor(b0) - n, math.ceil(b0) + n do
            local u = origin.u + (a * cu - b * su) * step
            local v = origin.v + (a * su + b * cu) * step
            if (u - c.u) ^ 2 + (v - c.v) ^ 2 <= inner * inner then
                local key = a * 65536 + b
                local s = cache[key]
                if not s then
                    s = { u = u, v = v, gu = u, gv = v }
                    cache[key] = s
                    new[#new + 1] = s
                end
                all[#all + 1] = s
            end
        end
    end
    return all, new
end

-- Only the rim shows how it sits: under the rest, seams and dips are hidden.
-- bad: { u, v, kind } with kind 'blocked', 'hole', 'line' or 'gap'. score: lower is better.
---@return { ok: boolean, seat: table?, why: string?, score: number, holes: number, rimHoles: number, rimOff: number, rimGap: number, blocked: integer, roomOut: number, bad: table[] }
function FillerMap.judge(disc, c, radius, opts)
    opts = opts or {}
    local uneven = opts.uneven or 0.003
    local present, holes, blocked, rim, rimHoles, bad = {}, 0, 0, 0, 0, {}
    local under, around, out = 0, 0, 0
    for _, s in ipairs(disc) do
        local d = math.sqrt((s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2)
        local onRim = not s.room and d >= radius - RIM
        if onRim then rim = rim + 1 end
        if s.room then
            -- Round the bezel: an opening, glass, a flare or a lip more than the search's window off the paint.
            around = around + 1
            if not s.h then
                out = out + 1
                bad[#bad + 1] = { u = s.gu, v = s.gv, kind = s.blocked and 'blocked' or 'hole' }
            end
        elseif s.h then
            under = under + 1
            present[#present + 1] = s
        elseif s.blocked then
            under = under + 1
            blocked = blocked + 1
            bad[#bad + 1] = { u = s.gu, v = s.gv, kind = 'blocked' }
        else
            under = under + 1
            holes = holes + 1
            if onRim then
                rimHoles = rimHoles + 1
                bad[#bad + 1] = { u = s.gu, v = s.gv, kind = 'hole' }
            end
        end
    end

    local seat = #present >= 6 and DoorMap.seat(present, c, radius) or nil
    local smooth = #present >= 10 and FillerMap.surface(present, c, radius, 0.0006)
    local rimGap, off, rimPresent = 0.0, 0, 0
    for _, s in ipairs(present) do
        if (s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2 < (radius - RIM) ^ 2 then
            -- Hidden under this bezel, but a line or a seam here runs on: the next spot's rim keeps off it.
            if smooth and math.abs(s.h - smooth(s.u, s.v)) > (opts.seam or SEAM) then bad[#bad + 1] = { u = s.u, v = s.v, kind = 'line' } end
        else
            rimPresent = rimPresent + 1
            local du, dv = s.u - c.u, s.v - c.v
            local wrong
            if seat and du * du + dv * dv <= radius * radius then
                local gap = seat.a + seat.b * du + seat.c * dv - s.h
                rimGap = math.max(rimGap, gap)
                if gap > uneven then wrong = 'gap' end
            end
            if smooth and math.abs(s.h - smooth(s.u, s.v)) > (opts.seam or SEAM) then
                off = off + 1
                wrong = 'line'
            end
            if wrong then bad[#bad + 1] = { u = s.u, v = s.v, kind = wrong } end
        end
    end

    local v = {
        seat = seat, blocked = blocked, rimGap = rimGap, bad = bad,
        holes = under > 0 and holes / under or 1.0,
        rimHoles = rim > 0 and rimHoles / rim or 1.0,
        rimOff = rimPresent > 0 and off / rimPresent or 0.0,
        roomOut = around > 0 and out / around or 0.0,
    }
    if under == 0 then
        v.why = 'nothing measured there'
    elseif blocked > 0 then
        v.why = ('something stands out under the bezel (%d point%s)'):format(blocked, blocked == 1 and '' or 's')
    elseif v.rimHoles > (opts.holes or 0.02) then
        v.why = ('no paint under %d%% of the bezel\'s rim'):format(math.floor(v.rimHoles * 100 + 0.5))
    elseif out > 0 then
        v.why = ('no plain paint round %d%% of the bezel (an opening, glass, a flare or a lip close to it)'):format(math.max(1, math.floor(v.roomOut * 100 + 0.5)))
    elseif v.holes > 0.4 or not seat then
        v.why = ('no paint under %d%% of the bezel'):format(math.floor(v.holes * 100 + 0.5))
    elseif v.rimOff > (opts.off or 0.01) then
        v.why = ('a lip, a body line or a seam under %d%% of the bezel\'s rim'):format(math.floor(v.rimOff * 100 + 0.5))
    elseif rimGap > uneven then
        v.why = ('a gap of up to %.1f mm under the bezel\'s rim'):format(rimGap * 1000)
    end
    v.ok = v.why == nil
    v.score = blocked * 0.01 + v.rimHoles * 0.1 + v.roomOut * 0.05 + v.rimOff * 0.05 + (seat and rimGap or 0.05)
    return v
end

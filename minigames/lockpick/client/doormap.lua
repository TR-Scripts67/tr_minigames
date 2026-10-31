-- Door space: u along the car (+ is forward), v up, h out of the door.
-- h is nil where nothing was found (a gap, a hole, glass), blocked = true if something stood far out (a mirror).

DoorMap = {}

local FEATURE = 0.0035 -- metres off the skin that count as something else (handle, pocket, seam)

function DoorMap.grid(u0, u1, v0, v1, step)
    local map = { step = step, samples = {}, at = {} }
    local i = 0
    for u = u0, u1 + step * 0.5, step do
        i = i + 1
        local j = 0
        map.at[i] = {}
        for v = v0, v1 + step * 0.5, step do
            j = j + 1
            local s = { u = u, v = v, i = i, j = j, gu = u, gv = v } -- gu, gv: where on the grid (u, v move to the hit)
            map.samples[#map.samples + 1] = s
            map.at[i][j] = s
        end
    end
    return map
end

local function solve(a, b)
    local n = #b
    for c = 1, n do
        local p = c
        for r = c + 1, n do if math.abs(a[r][c]) > math.abs(a[p][c]) then p = r end end
        if math.abs(a[p][c]) < 1e-12 then return end
        a[c], a[p], b[c], b[p] = a[p], a[c], b[p], b[c]
        for r = c + 1, n do
            local f = a[r][c] / a[c][c]
            for k = c, n do a[r][k] = a[r][k] - f * a[c][k] end
            b[r] = b[r] - f * b[c]
        end
    end
    local x = {}
    for r = n, 1, -1 do
        local s = b[r]
        for k = r + 1, n do s = s - a[r][k] * x[k] end
        x[r] = s / a[r][r]
    end
    return x
end

local function leastSquares(samples, terms, keep)
    local n
    local ata, atb = {}, {}
    local count = 0
    for _, s in ipairs(samples) do
        if s.h and keep(s) then
            local t = terms(s.u, s.v)
            if not n then
                n = #t
                for r = 1, n do ata[r] = {}; atb[r] = 0.0; for c = 1, n do ata[r][c] = 0.0 end end
            end
            for r = 1, n do
                atb[r] = atb[r] + t[r] * s.h
                for c = 1, n do ata[r][c] = ata[r][c] + t[r] * t[c] end
            end
            count = count + 1
        end
    end
    if not n or count < n + 2 then return end
    return solve(ata, atb)
end
DoorMap.leastSquares = leastSquares -- also used by the siphon's FillerMap

local function evaluate(coef, terms, u, v)
    local t, h = terms(u, v), 0.0
    for k = 1, #coef do h = h + coef[k] * t[k] end
    return h
end

local function quadratic(u, v) return { 1.0, u, v, u * u, u * v, v * v } end
local function linear(u, v) return { 1.0, u, v } end

local function median(list)
    if #list == 0 then return 0.0 end
    table.sort(list)
    return list[(#list + 1) // 2]
end

---@return { height: fun(u: number, v: number): number }?
function DoorMap.fitSkin(map)
    -- Start from the plain median, then refit keeping only what's close to the last fit.
    local hs = {}
    for _, s in ipairs(map.samples) do if s.h then hs[#hs + 1] = s.h end end
    if #hs < 12 then return end

    local m = median(hs)
    local coef = { m, 0, 0, 0, 0, 0 }
    local limit = 0.012

    for _ = 1, 6 do
        local keep = function(s) return math.abs(s.h - evaluate(coef, quadratic, s.u, s.v)) < limit end
        coef = leastSquares(map.samples, quadratic, keep) or coef

        local res = {}
        for _, s in ipairs(map.samples) do
            if s.h then res[#res + 1] = math.abs(s.h - evaluate(coef, quadratic, s.u, s.v)) end
        end
        limit = math.max(0.0015, math.min(limit, median(res) * 3.0))
    end

    return { height = function(u, v) return evaluate(coef, quadratic, u, v) end }
end

local function tricube(d, radius)
    local x = d / radius
    if x >= 1.0 then return 0.0 end
    local t = 1.0 - x * x * x
    return t * t * t
end

-- Refits without what's far off the last fit, so a handle, knob or pocket doesn't pull it. nil if too little paint.
local function fitAround(near, gu, gv, radius, start)
    if #near < 12 then return end

    local res = {}
    for k, s in ipairs(near) do res[k] = math.abs(s.h - start[s]) end
    local sorted = { table.unpack(res) }
    table.sort(sorted)
    -- Wide enough at first for paint the start is well off (most of what's near is paint).
    local limit = math.max(0.012, 2.0 * sorted[math.max(1, math.floor(#sorted * 0.3))])

    local count = #near
    local W, T = {}, {}
    for k, s in ipairs(near) do
        local du, dv = s.u - gu, s.v - gv
        local eu, ev = s.gu - gu, s.gv - gv
        W[k] = tricube(math.sqrt(eu * eu + ev * ev), radius)
        T[k] = { 1.0, du, dv, du * du, du * dv, dv * dv }
    end

    local coef
    local predicted = {}
    for k, s in ipairs(near) do predicted[k] = start[s] end

    for _ = 1, 4 do
        local m, rhs, n = {}, { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, 0
        for k = 1, 36 do m[k] = 0.0 end
        for k = 1, count do
            local w = W[k]
            local h = near[k].h
            if w > 0.0 and math.abs(h - predicted[k]) < limit then
                local t = T[k]
                for r = 1, 6 do
                    local wt = w * t[r]
                    rhs[r] = rhs[r] + wt * h
                    local base = (r - 1) * 6
                    for c = r, 6 do m[base + c] = m[base + c] + wt * t[c] end
                end
                n = n + 1
            end
        end
        if n < 12 then break end

        local a = {}
        for r = 1, 6 do
            a[r] = {}
            for c = 1, 6 do a[r][c] = r <= c and m[(r - 1) * 6 + c] or m[(c - 1) * 6 + r] end
        end
        local x = solve(a, rhs)
        if not x then break end
        coef = x

        for k = 1, count do
            local t = T[k]
            predicted[k] = x[1] + x[2] * t[2] + x[3] * t[3] + x[4] * t[4] + x[5] * t[5] + x[6] * t[6]
            res[k] = math.abs(near[k].h - predicted[k])
        end
        limit = math.max(0.0015, math.min(limit, 3.0 * median({ table.unpack(res) })))
    end
    return coef
end

-- For doors one smooth curve can't follow (the roll-over under the window, a body line).
-- pause, if given, is called now and then so the work doesn't freeze the screen.
function DoorMap.localSkin(map, skin, radius, pause)
    radius = radius or 0.08
    local step, grid = map.step, map.at
    local ni, nj = #grid, #grid[1]
    local every = math.max(2, math.floor(0.025 / step + 0.5))
    local reach = math.ceil(radius / step)
    local u0, v0 = grid[1][1].gu, grid[1][1].gv

    local function lattice(n)
        local list = {}
        for k = 1, n, every do list[#list + 1] = k end
        if list[#list] ~= n then list[#list + 1] = n end
        return list
    end
    local Li, Lj = lattice(ni), lattice(nj)

    local start = {}
    for _, s in ipairs(map.samples) do
        if s.h then start[s] = skin.height(s.u, s.v) end
    end

    local nodes = {}
    for a, i in ipairs(Li) do
        nodes[a] = {}
        for b, j in ipairs(Lj) do
            local gu, gv = grid[i][j].gu, grid[i][j].gv
            local near = {}
            for ii = math.max(1, i - reach), math.min(ni, i + reach) do
                local column = grid[ii]
                for jj = math.max(1, j - reach), math.min(nj, j + reach) do
                    local s = column[jj]
                    if s.h and (s.gu - gu) ^ 2 + (s.gv - gv) ^ 2 < radius * radius then near[#near + 1] = s end
                end
            end
            nodes[a][b] = { gu = gu, gv = gv, coef = fitAround(near, gu, gv, radius, start) }
        end
        if pause then pause() end
    end

    local function bracket(L, x)
        if x <= L[1] then return 1, 1, 0.0 end
        if x >= L[#L] then return #L, #L, 0.0 end
        local a = math.max(1, math.min(#L - 1, math.floor((x - 1) / every) + 1))
        while L[a + 1] < x do a = a + 1 end
        while L[a] > x do a = a - 1 end
        return a, a + 1, (x - L[a]) / (L[a + 1] - L[a])
    end

    local function height(u, v)
        local a0, a1, tu = bracket(Li, (u - u0) / step + 1)
        local b0, b1, tv = bracket(Lj, (v - v0) / step + 1)
        local sum, wsum = 0.0, 0.0
        for _, c in ipairs({ { a0, b0, (1 - tu) * (1 - tv) }, { a1, b0, tu * (1 - tv) }, { a0, b1, (1 - tu) * tv }, { a1, b1, tu * tv } }) do
            local node, w = nodes[c[1]][c[2]], c[3]
            if node.coef and w > 0.0 then
                local k, du, dv = node.coef, u - node.gu, v - node.gv
                sum = sum + w * (k[1] + k[2] * du + k[3] * dv + k[4] * du * du + k[5] * du * dv + k[6] * dv * dv)
                wsum = wsum + w
            end
        end
        if wsum < 1e-6 then return skin.height(u, v) end
        return sum / wsum
    end

    return { height = height }
end

-- s.feature = true, s.off: metres off the skin
function DoorMap.mark(map, skin, tolerance)
    tolerance = tolerance or FEATURE
    for _, s in ipairs(map.samples) do
        if s.h then
            s.off = s.h - skin.height(s.u, s.v)
            s.feature = s.blocked or math.abs(s.off) > tolerance
        else
            s.feature = true
        end
    end
end

-- Each group: { samples, u0, u1, v0, v1, out, deep }
function DoorMap.groups(map)
    local seen, groups = {}, {}
    for _, start in ipairs(map.samples) do
        if start.feature and not seen[start] then
            local g = { samples = {}, u0 = math.huge, u1 = -math.huge, v0 = math.huge, v1 = -math.huge, out = 0, deep = 0, holes = 0 }
            local stack = { start }
            seen[start] = true
            while #stack > 0 do
                local s = table.remove(stack)
                g.samples[#g.samples + 1] = s
                g.u0, g.u1 = math.min(g.u0, s.u), math.max(g.u1, s.u)
                g.v0, g.v1 = math.min(g.v0, s.v), math.max(g.v1, s.v)
                if not s.h then g.holes = g.holes + 1
                elseif s.off > 0 then g.out = g.out + 1
                else g.deep = g.deep + 1 end

                for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local column = map.at[s.i + d[1]]
                    local n = column and column[s.j + d[2]]
                    if n and n.feature and not seen[n] then
                        seen[n] = true
                        stack[#stack + 1] = n
                    end
                end
            end
            -- The thing's real edge can be anywhere up to the next sample, which missed it.
            local pad = map.step
            g.u0, g.u1, g.v0, g.v1 = g.u0 - pad, g.u1 + pad, g.v0 - pad, g.v1 + pad
            groups[#groups + 1] = g
        end
    end
    return groups
end

local function handleLike(g)
    local w, h = g.u1 - g.u0, g.v1 - g.v0
    if w < 0.05 or w > 0.36 or h < 0.012 or h > 0.11 or w < h * 1.4 then return false end
    return true
end

-- Read column by column so trim strips and body lines that join up with the handle don't count.
local function handleAtBone(map, anchor)
    local a, best
    for _, s in ipairs(map.samples) do
        local d = (s.gu - anchor.u) ^ 2 + (s.gv - anchor.v) ^ 2
        if not best or d < best then a, best = s, d end
    end
    if not a then return end

    -- Not glass or gaps, which run along the whole door above the handle.
    local function part(s) return s ~= nil and (s.blocked or (s.feature and s.off ~= nil and s.off > -0.025)) end

    local band = math.max(2, math.floor(0.05 / map.step + 0.5)) -- rows either side of the bone
    local count, all = {}, {}
    for i = 1, #map.at do
        local c = 0
        for j = a.j - band, a.j + band do
            if part(map.at[i][j]) then c = c + 1 end
        end
        count[i], all[i] = c, c
    end
    local base = median(all)
    local function stands(i) return count[i] ~= nil and count[i] > base end

    local i0 = nil
    for _, i in ipairs({ a.i, a.i - 1, a.i + 1 }) do
        if stands(i) then i0 = i break end
    end
    if not i0 then return end

    local i1 = i0
    while stands(i0 - 1) or stands(i0 - 2) do i0 = stands(i0 - 1) and i0 - 1 or i0 - 2 end
    while stands(i1 + 1) or stands(i1 + 2) do i1 = stands(i1 + 1) and i1 + 1 or i1 + 2 end
    if (i1 - i0 + 1) * map.step > 0.40 then return end -- runs the whole way: nothing stands out

    local function row(j)
        local c, n = 0, 0
        for i = i0, i1 do
            local s = map.at[i][j]
            if s then
                n = n + 1
                if part(s) then c = c + 1 end
            end
        end
        return n > 0 and c * 2 >= n
    end
    local j0, j1 = a.j, a.j
    while j0 - 1 >= a.j - band and row(j0 - 1) do j0 = j0 - 1 end
    while j1 + 1 <= a.j + band and row(j1 + 1) do j1 = j1 + 1 end

    local pad = map.step
    return {
        u0 = map.at[i0][a.j].gu - pad, u1 = map.at[i1][a.j].gu + pad,
        v0 = map.at[a.i][j0].gv - pad, v1 = map.at[a.i][j1].gv + pad,
        found = true,
    }
end

-- found is false if it was only guessed
---@return { u0: number, u1: number, v0: number, v1: number, found: boolean }?
function DoorMap.findHandle(map, anchor)
    if anchor then
        local box = handleAtBone(map, anchor)
        if box then return box end
    end

    local groups = DoorMap.groups(map)
    local best, bestScore

    for _, g in ipairs(groups) do
        local score
        if anchor then
            local du = math.max(g.u0 - anchor.u, 0, anchor.u - g.u1)
            local dv = math.max(g.v0 - anchor.v, 0, anchor.v - g.v1)
            local d = math.sqrt(du * du + dv * dv)
            if d < 0.04 and (g.u1 - g.u0) < 0.40 and (g.v1 - g.v0) < 0.14 then score = -d - #g.samples * 1e-4 end
        elseif handleLike(g) then
            local fill = #g.samples * map.step * map.step / ((g.u1 - g.u0) * (g.v1 - g.v0))
            score = fill - math.abs((g.u1 - g.u0) - 0.17) * 2.0
        end

        if score and (not bestScore or score > bestScore) then best, bestScore = g, score end
    end

    if best then return { u0 = best.u0, u1 = best.u1, v0 = best.v0, v1 = best.v1, found = true } end
    if anchor then
        -- Nothing stands out (a flush handle the probe missed): assume a typical one at the bone.
        return { u0 = anchor.u - 0.07, u1 = anchor.u + 0.07, v0 = anchor.v - 0.02, v1 = anchor.v + 0.02, found = false }
    end
end

-- Ahead of the handle first (the side the camera looks from), then behind it, then under it.
---@return { u: number, v: number, side: string }[]
function DoorMap.spots(handle, radius)
    local list = {}
    local vc, uc = (handle.v0 + handle.v1) * 0.5, (handle.u0 + handle.u1) * 0.5
    local function add(side, u, v, cost) list[#list + 1] = { u = u, v = v, side = side, cost = cost } end

    for gap = 0.004, handle.found == false and 0.16 or 0.08, 0.004 do
        for _, dv in ipairs({ 0.0, 0.006, -0.006, 0.012, -0.012, 0.024, -0.024 }) do
            local cost = gap + math.abs(dv) * 0.5
            add('front', handle.u1 + radius + gap, vc + dv, cost)
            add('rear', handle.u0 - radius - gap, vc + dv, cost + 0.05)
        end
        add('below', uc, handle.v0 - radius - gap, gap + 0.09)
    end

    table.sort(list, function(a, b) return a.cost < b.cost end)
    return list
end

local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

---@return { u: number, v: number, distance: number }[] candidates
---@return { u: number, v: number, distance: number, why: string }[] rejected
function DoorMap.lockCandidates(map, handle)
    -- Blocked: stood out further than the search went. A knob may well do that.
    local function raised(s) return s ~= nil and (s.blocked or (s.off ~= nil and s.off > 0.002)) end
    local seen, out, rejected = {}, {}, {}

    for _, start in ipairs(map.samples) do
        if raised(start) and not seen[start] then
            local blob, stack = {}, { start }
            seen[start] = true
            while #stack > 0 do
                local s = table.remove(stack)
                blob[#blob + 1] = s
                for _, d in ipairs(STEPS) do
                    local column = map.at[s.i + d[1]]
                    local n = column and column[s.j + d[2]]
                    if raised(n) and not seen[n] then
                        seen[n] = true
                        stack[#stack + 1] = n
                    end
                end
            end

            local i0, i1, j0, j1 = math.huge, -math.huge, math.huge, -math.huge
            local su, sv, sw = 0.0, 0.0, 0.0
            for _, s in ipairs(blob) do
                i0, i1, j0, j1 = math.min(i0, s.i), math.max(i1, s.i), math.min(j0, s.j), math.max(j1, s.j)
                local w = s.off or 0.03
                su, sv, sw = su + s.gu * w, sv + s.gv * w, sw + w
            end
            local around, busy = 0, 0
            for i = i0 - 1, i1 + 1 do
                for j = j0 - 1, j1 + 1 do
                    local s = map.at[i] and map.at[i][j]
                    local inBlob = i >= i0 and i <= i1 and j >= j0 and j <= j1 and raised(s)
                    if not inBlob then
                        around = around + 1
                        if not s or s.feature then busy = busy + 1 end
                    end
                end
            end
            local c = { u = su / sw, v = sv / sw }
            local du = math.max(handle.u0 - c.u, 0, c.u - handle.u1)
            local dv = math.max(handle.v0 - c.v, 0, c.v - handle.v1)
            c.distance = math.sqrt(du * du + dv * dv)

            if c.distance > 0.005 and c.distance < 0.25 then
                if (i1 - i0) * map.step > 0.06 or (j1 - j0) * map.step > 0.06 then
                    c.why = ('too big (%d x %d cm)'):format(math.floor((i1 - i0 + 1) * map.step * 100 + 0.5),
                        math.floor((j1 - j0 + 1) * map.step * 100 + 0.5))
                elseif busy > around * 0.25 then
                    c.why = 'too much else around it'
                end
                if c.why then
                    if #blob <= 40 then rejected[#rejected + 1] = c end
                else
                    out[#out + 1] = c
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out, rejected
end

---@return { u: number, v: number, radius: number, height: number }?
---@return string? why
function DoorMap.findKnob(fine, c, window)
    -- The paint around it, curved as it is (a plane would make any bulge look like a knob).
    local outer = {}
    for _, s in ipairs(fine.samples) do
        if s.h and (s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2 > (window * 0.8) ^ 2 then outer[#outer + 1] = s end
    end
    local coef = #outer >= 12 and leastSquares(outer, quadratic, function() return true end)
    if not coef then return nil, 'no paint around it' end

    local function above(s) return s and s.h and s.h - evaluate(coef, quadratic, s.u, s.v) or nil end
    local function raised(s) return s ~= nil and (s.blocked or (above(s) or 0) > 0.0015) end

    local start, best
    for _, s in ipairs(fine.samples) do
        local d = (s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2
        if raised(s) and (not best or d < best) then start, best = s, d end
    end
    if not start or best > (window * 0.5) ^ 2 then return nil, 'nothing stands out on a close look' end

    local blob, stack, seen = {}, { start }, { [start] = true }
    local last = #fine.at
    while #stack > 0 do
        local s = table.remove(stack)
        blob[#blob + 1] = s
        if s.i == 1 or s.j == 1 or s.i == last or s.j == #fine.at[1] then return nil, 'runs on too far to be a knob' end
        for _, d in ipairs(STEPS) do
            local n = fine.at[s.i + d[1]] and fine.at[s.i + d[1]][s.j + d[2]]
            if n and not seen[n] and raised(n) then
                seen[n] = true
                stack[#stack + 1] = n
            end
        end
    end

    local su, sv, sw, top = 0.0, 0.0, 0.0, 0.0
    local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
    for _, s in ipairs(blob) do
        local a = above(s) or 0.03
        su, sv, sw, top = su + s.gu * a, sv + s.gv * a, sw + a, math.max(top, a)
        u0, u1, v0, v1 = math.min(u0, s.gu), math.max(u1, s.gu), math.min(v0, s.gv), math.max(v1, s.gv)
    end
    local wide, tall = u1 - u0 + fine.step, v1 - v0 + fine.step
    if math.max(wide, tall) > 1.8 * math.min(wide, tall) then
        return nil, ('%d x %d mm: not round, so not a lock'):format(math.floor(wide * 1000 + 0.5), math.floor(tall * 1000 + 0.5))
    end
    local radius = math.sqrt(#blob * fine.step * fine.step / math.pi)
    if radius < 0.006 or radius > 0.032 then return nil, ('%d mm across, not the size of a lock'):format(math.floor(radius * 2000 + 0.5)) end
    if top < 0.003 then return nil, ('only %.1f mm proud: a bulge in the paint, not a lock'):format(top * 1000) end
    return { u = su / sw, v = sv / sw, radius = radius, height = top }
end

function DoorMap.pick(map, candidates, radius, rough, count)
    local ok = {}
    for _, c in ipairs(candidates) do
        local plane = DoorMap.fitPlane(DoorMap.near(map, c, radius + map.step * 0.5))
        if plane and plane.worst <= rough then
            c.rough = plane.worst
            c.rank = c.cost + plane.worst * 10.0 + (DoorMap.clear(map, c, radius) and 0.0 or 0.03)
            ok[#ok + 1] = c
        end
    end
    table.sort(ok, function(a, b) return a.rank < b.rank end)

    local out = {}
    for _, c in ipairs(ok) do
        local apart = true
        for _, o in ipairs(out) do
            if (o.u - c.u) ^ 2 + (o.v - c.v) ^ 2 < radius * radius then apart = false break end
        end
        if apart then
            out[#out + 1] = c
            if #out >= count then break end
        end
    end
    return out
end

function DoorMap.near(map, c, radius)
    local out = {}
    for _, s in ipairs(map.samples) do
        local du, dv = s.u - c.u, s.v - c.v
        if du * du + dv * dv <= radius * radius then out[#out + 1] = s end
    end
    return out
end

function DoorMap.clear(map, c, radius)
    local near = DoorMap.near(map, c, radius + map.step * 0.5)
    if #near == 0 then return false end
    for _, s in ipairs(near) do
        if s.feature then return false end
    end
    return true
end

-- Tilted to rest on the paint's high points like a real bezel. The ring's back is at h = a + b*(u - c.u) + c*(v - c.v).
---@return { a: number, b: number, c: number, gap: number, worst: number }?
function DoorMap.seat(samples, c, radius)
    local under = {}
    for _, s in ipairs(samples) do
        local du, dv = s.u - c.u, s.v - c.v
        if du * du + dv * dv <= radius * radius then
            if not s.h then return end
            under[#under + 1] = s
        end
    end
    local start = #under >= 6 and DoorMap.fitPlane(under)
    if not start then return end

    local function rest(b, cc)
        local a = -math.huge
        for _, s in ipairs(under) do a = math.max(a, s.h - b * (s.u - c.u) - cc * (s.v - c.v)) end
        local sum, worst = 0.0, 0.0
        for _, s in ipairs(under) do
            local g = a + b * (s.u - c.u) + cc * (s.v - c.v) - s.h
            sum, worst = sum + g, math.max(worst, g)
        end
        return { a = a, b = b, c = cc, gap = sum / #under, worst = worst }
    end

    local best = rest(start.b, start.c)
    for _, step in ipairs({ 0.04, 0.01, 0.0025, 0.0006 }) do
        local moved = true
        while moved do
            moved = false
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                local b, cc = best.b + d[1] * step, best.c + d[2] * step
                if math.abs(b) < 0.6 and math.abs(cc) < 0.6 then -- within about 30 degrees
                    local try = rest(b, cc)
                    if try.gap < best.gap - 1e-7 then best, moved = try, true end
                end
            end
        end
    end
    return best
end

-- h = a + b*u + c*v; worst: largest residual. nil if too few samples or any is missing.
function DoorMap.fitPlane(samples)
    for _, s in ipairs(samples) do if not s.h then return end end
    local coef = leastSquares(samples, linear, function() return true end)
    if not coef then return end

    local worst = 0.0
    for _, s in ipairs(samples) do
        worst = math.max(worst, math.abs(s.h - (coef[1] + coef[2] * s.u + coef[3] * s.v)))
    end
    return { a = coef[1], b = coef[2], c = coef[3], worst = worst }
end

-- Panel detector based on a recursive XY-cut over a downsampled grayscale grid.
--
-- Unlike a connected-components approach, it does not need panels to be
-- isolated blobs: panels that touch through borders, bleed into each other
-- or sit on yellowed/noisy paper are still split as long as a straight gutter
-- (a band that is "background" across the whole region) separates them.
-- Reading order falls out of the cut tree, so tall panels next to stacked
-- panels are ordered correctly.
--
-- Pure Lua, no KOReader dependencies, so it can be tested stand-alone.

local PanelDetector = {}

local DEFAULTS = {
    min_tolerance = 14,    -- lower/upper bounds for the adaptive color distance
    max_tolerance = 40,    -- from background that counts as content
    noise_levels = { 0.012, 0.04, 0.09, 0.16, 0.25 }, -- tolerated content per gutter line, tried in order
    loose_max_gap_frac = 0.04, -- looser levels only accept gutters thinner than this (page axis fraction)
    gap_frac = 0.003,      -- minimum thickness of a clean gutter (page axis fraction, at least 2 px)
    loose_gap_frac = 0.004, -- minimum thickness when some content crosses the gutter
    min_segment_frac = 0.04, -- bands thinner than this (page axis fraction) are dropped as noise
    min_panel_w = 0.05,    -- final panel filters (page fractions)
    min_panel_h = 0.04,
    min_panel_area = 0.012,
    border_frac = 0.02,    -- border band used to estimate the background level
    edge_margin_frac = 0.03, -- page-edge strip ignored when measuring gutters (printed frames, scan edges)
    max_skew_deg = 2.5,    -- scans are often slightly rotated; search +/- this many degrees
    skew_step_deg = 0.25,
    max_depth = 12,
}

local function opt(opts, key)
    if opts and opts[key] ~= nil then return opts[key] end
    return DEFAULTS[key]
end

-- planes: {r=, g=, b=} flat tables (r == g == b for grayscale input).
-- Background = most common luma level (16-level bins) in the outer border band.
-- Returns the mean background color and the typical noise around it.
local function estimateBackground(planes, gw, gh, border_frac)
    local r, g, b = planes.r, planes.g, planes.b
    local bx = math.max(1, math.floor(gw * border_frac))
    local by = math.max(1, math.floor(gh * border_frac))
    local hist = {}
    for i = 0, 15 do hist[i] = 0 end

    local function luma(i)
        return (r[i] * 3 + g[i] * 6 + b[i]) / 10
    end
    local function forBorder(fn)
        for y = 0, gh - 1 do
            if y < by or y >= gh - by then
                for x = 0, gw - 1 do fn(y * gw + x + 1) end
            else
                for x = 0, bx - 1 do fn(y * gw + x + 1) end
                for x = gw - bx, gw - 1 do fn(y * gw + x + 1) end
            end
        end
    end

    forBorder(function(i)
        local bin = math.floor(luma(i) / 16)
        if bin > 15 then bin = 15 end
        hist[bin] = hist[bin] + 1
    end)

    local best, best_count = 15, -1
    for i = 0, 15 do
        if hist[i] > best_count then best, best_count = i, hist[i] end
    end
    local lo, hi = best * 16 - 8, best * 16 + 24 -- the winning bin plus a margin

    local n, sr, sg, sb = 0, 0, 0, 0
    forBorder(function(i)
        local l = luma(i)
        if l >= lo and l < hi then
            n = n + 1
            sr, sg, sb = sr + r[i], sg + g[i], sb + b[i]
        end
    end)
    if n == 0 then return best * 16 + 8, best * 16 + 8, best * 16 + 8, 0, 0 end
    local border_total = 0
    for i = 0, 15 do border_total = border_total + hist[i] end
    local mr, mg, mb = sr / n, sg / n, sb / n

    local dev = 0
    forBorder(function(i)
        local l = luma(i)
        if l >= lo and l < hi then
            dev = dev + math.max(math.abs(r[i] - mr), math.abs(g[i] - mg), math.abs(b[i] - mb))
        end
    end)
    return mr, mg, mb, dev / n, n / math.max(1, border_total)
end

-- Gutter colors seen inside the page: rows/columns that are one flat color
-- across the whole page, in thin runs (gutters are thin; a flat sky band is not).
-- Needed when the paper tint differs from the scanner border (e.g. cream paper
-- with a white scan margin). Returns a list of {r,g,b}.
local function estimateGutterColors(planes, gw, gh, margin_x, margin_y, tol, max_run_frac)
    local r, g, b = planes.r, planes.g, planes.b
    local weights, colors = {}, {}

    local function median(hist, n)
        local half, acc = n / 2, 0
        for v = 0, 255 do
            acc = acc + hist[v]
            if acc >= half then return v end
        end
        return 255
    end

    -- axis scan: lines run along 'len' pixels; 'count' lines
    local function scan(count, len, idx, lo, hi, margin, max_run)
        local run_color, run_len = nil, 0
        local function flush()
            if run_color and run_len > 0 and run_len <= max_run then
                local key = math.floor(run_color[1] / 24) * 10000 + math.floor(run_color[2] / 24) * 100 + math.floor(run_color[3] / 24)
                weights[key] = (weights[key] or 0) + run_len
                colors[key] = colors[key] or run_color
            end
            run_color, run_len = nil, 0
        end
        for line = margin, count - 1 - margin do
            local hr, hg, hb = {}, {}, {}
            for v = 0, 255 do hr[v], hg[v], hb[v] = 0, 0, 0 end
            local n = 0
            for k = lo, hi do
                local i = idx(line, k)
                local vr, vg, vb = r[i], g[i], b[i]
                if vr > 255 then vr = 255 elseif vr < 0 then vr = 0 end
                if vg > 255 then vg = 255 elseif vg < 0 then vg = 0 end
                if vb > 255 then vb = 255 elseif vb < 0 then vb = 0 end
                hr[vr] = hr[vr] + 1; hg[vg] = hg[vg] + 1; hb[vb] = hb[vb] + 1
                n = n + 1
            end
            local mr, mg, mb = median(hr, n), median(hg, n), median(hb, n)
            local close = 0
            for k = lo, hi do
                local i = idx(line, k)
                if math.abs(r[i] - mr) <= tol and math.abs(g[i] - mg) <= tol and math.abs(b[i] - mb) <= tol then
                    close = close + 1
                end
            end
            if close >= 0.9 * n then
                if run_color and math.abs(run_color[1] - mr) <= tol and math.abs(run_color[2] - mg) <= tol and math.abs(run_color[3] - mb) <= tol then
                    run_len = run_len + 1
                else
                    flush()
                    run_color, run_len = { mr, mg, mb }, 1
                end
            else
                flush()
            end
        end
        flush()
    end

    local lo_x, hi_x = math.floor(gw * 0.04), math.floor(gw * 0.96)
    local lo_y, hi_y = math.floor(gh * 0.04), math.floor(gh * 0.96)
    scan(gh, gw, function(line, k) return line * gw + k + 1 end, lo_x, hi_x, margin_y, math.floor(max_run_frac * gh))
    scan(gw, gh, function(line, k) return k * gw + line + 1 end, lo_y, hi_y, margin_x, math.floor(max_run_frac * gw))

    local list = {}
    for key, wgt in pairs(weights) do list[#list + 1] = { color = colors[key], w = wgt } end
    table.sort(list, function(a, c) return a.w > c.w end)
    local out = {}
    for _, e in ipairs(list) do
        local far = true
        for _, o in ipairs(out) do
            if math.abs(o[1] - e.color[1]) <= tol and math.abs(o[2] - e.color[2]) <= tol and math.abs(o[3] - e.color[3]) <= tol then far = false end
        end
        if far and e.w >= 3 then out[#out + 1] = e.color end
        if #out >= 2 then break end
    end
    return out
end

-- counts[i] (i = 0..n-1) = content pixels on line i. Returns list of
-- {s=, e=} (e exclusive) content stretches separated by gutters >= min_gap.
-- Stretches shorter than min_len are discarded.
local function findSegments(counts, n, line_len, noise_frac, min_gap, min_len, max_gap)
    local thresh = math.floor(noise_frac * line_len)
    local runs = {} -- content runs
    local start = nil
    for i = 0, n - 1 do
        if counts[i] > thresh then
            if not start then start = i end
        elseif start then
            runs[#runs + 1] = { s = start, e = i }
            start = nil
        end
    end
    if start then runs[#runs + 1] = { s = start, e = n } end

    -- merge runs separated by gutters thinner than min_gap (or, at loose levels,
    -- thicker than max_gap: that is probably empty sky/background inside a panel)
    local merged = {}
    for _, r in ipairs(runs) do
        local last = merged[#merged]
        local gap = last and (r.s - last.e) or 0
        if last and (gap < min_gap or (max_gap and gap > max_gap)) then
            last.e = r.e
        else
            merged[#merged + 1] = { s = r.s, e = r.e }
        end
    end

    local out = {}
    for _, r in ipairs(merged) do
        if (r.e - r.s) >= min_len then out[#out + 1] = r end
    end
    return out
end

-- xa/xb: columns skipped on the left/right of the region (page-edge frames)
local function rowCounts(mask, gw, x0, y0, x1, y1, xa, xb)
    local counts = {}
    for y = y0, y1 - 1 do
        local c, base = 0, y * gw
        for x = x0 + xa, x1 - 1 - xb do c = c + mask[base + x + 1] end
        counts[y - y0] = c
    end
    return counts
end

local function colCounts(mask, gw, x0, y0, x1, y1, ya, yb)
    local counts = {}
    for x = x0, x1 - 1 do counts[x - x0] = 0 end
    for y = y0 + ya, y1 - 1 - yb do
        local base = y * gw
        for x = x0, x1 - 1 do
            counts[x - x0] = counts[x - x0] + mask[base + x + 1]
        end
    end
    return counts
end

-- Smallest box around everything that differs from the scan/border color.
-- Returns x0, y0, x1, y1 (x1/y1 exclusive) or nil when it cannot tell.
local function findPageBounds(planes, gw, gh, opts)
    local r, g, b = planes.r, planes.g, planes.b
    local bgr, bgg, bgb, noise = estimateBackground(planes, gw, gh, opt(opts, "border_frac"))
    local tol = math.min(opt(opts, "max_tolerance"), math.max(opt(opts, "min_tolerance"), noise * 3 + 6))
    local rows, cols = {}, {}
    for y = 0, gh - 1 do rows[y] = 0 end
    for x = 0, gw - 1 do cols[x] = 0 end
    for y = 0, gh - 1 do
        local base = y * gw
        for x = 0, gw - 1 do
            local i = base + x + 1
            if math.abs(r[i] - bgr) > tol or math.abs(g[i] - bgg) > tol or math.abs(b[i] - bgb) > tol then
                rows[y] = rows[y] + 1
                cols[x] = cols[x] + 1
            end
        end
    end
    local function first(counts, n, len)
        for i = 0, n - 1 do if counts[i] > 0.05 * len then return i end end
    end
    local function last(counts, n, len)
        for i = n - 1, 0, -1 do if counts[i] > 0.05 * len then return i + 1 end end
    end
    local y0, y1 = first(rows, gh, gw), last(rows, gh, gw)
    local x0, x1 = first(cols, gw, gh), last(cols, gw, gh)
    if not (x0 and x1 and y0 and y1) then return nil end
    if (x1 - x0) < 0.3 * gw or (y1 - y0) < 0.3 * gh then return nil end
    return x0, y0, x1, y1
end

-- Skew search: rotate the content points by candidate angles and keep the angle
-- whose row histogram is most peaked (straight gutters => sharp valleys).
local function estimateSkew(mask, gw, gh, max_deg, step_deg, opts_debug)
    local pxs, pys, n = {}, {}, 0
    for y = 0, gh - 1, 2 do
        local base = y * gw
        for x = math.floor(gw * 0.04), math.floor(gw * 0.96), 2 do
            if mask[base + x + 1] == 1 then
                n = n + 1
                pxs[n], pys[n] = x, y
            end
        end
    end
    if n < 200 then return 0 end

    local cx, cy = gw / 2, gh / 2
    local size = gh * 2 + 8
    local off = math.floor(gh / 2) + 1
    local okffi, ffi = pcall(require, "ffi")

    local function score(deg)
        local phi = deg * math.pi / 180
        local sn, cs = math.sin(phi), math.cos(phi)
        local hist = okffi and ffi.new("int32_t[?]", size) or {}
        if not okffi then for i = 0, size - 1 do hist[i] = 0 end end
        for i = 1, n do
            -- bins are 2 rows tall, matching the stride-2 point sampling (otherwise
            -- alternating empty rows at angle 0 inflate the sharpness score)
            local row = math.floor(((pxs[i] - cx) * sn + (pys[i] - cy) * cs + cy + 0.5 + off) / 2)
            if row >= 0 and row < size then hist[row] = hist[row] + 1 end
        end
        -- sharpness of the profile: sum of squared row-to-row changes (valleys of
        -- a straight gutter make steep steps; a slanted one smears them)
        local sum = 0
        -- Only the middle of the page counts: the page edge itself is a big step
        -- that any rotation would smear, drowning the gutters' signal.
        for i = math.floor((off + 0.08 * gh) / 2), math.floor((off + 0.92 * gh) / 2) do
            local d = hist[i] - hist[i + 1]
            sum = sum + d * d
        end
        return sum
    end

    local base_score = score(0)
    local best_deg, best_score = 0, base_score
    local deg = -max_deg
    while deg <= max_deg + 1e-9 do
        if math.abs(deg) > 1e-9 then
            local sc = score(deg)
            if sc > best_score then best_deg, best_score = deg, sc end
        end
        deg = deg + step_deg
    end
    -- refine around the coarse optimum
    local fine = step_deg / 4
    local center = best_deg
    for k = -3, 3 do
        local d = center + k * fine
        if k ~= 0 and math.abs(d) <= max_deg then
            local sc = score(d)
            if sc > best_score then best_deg, best_score = d, sc end
        end
    end
    if opts_debug then print(string.format("  skew search: base %.0f best %.0f at %.2f deg", base_score, best_score, best_deg)) end
    if best_score < base_score * 1.15 then return 0 end
    return best_deg
end

-- dst(x,y) = src(R^-1 (x,y)) about the grid center, nearest neighbor.
local function rotateMask(mask, gw, gh, deg)
    local phi = deg * math.pi / 180
    local sn, cs = math.sin(phi), math.cos(phi)
    local cx, cy = gw / 2, gh / 2
    local okffi, ffi = pcall(require, "ffi")
    local out = okffi and ffi.new("uint8_t[?]", gw * gh + 1) or {}
    for y = 0, gh - 1 do
        local dy = y - cy
        for x = 0, gw - 1 do
            local dx = x - cx
            local xs = math.floor(dx * cs + dy * sn + cx + 0.5)
            local ys = math.floor(-dx * sn + dy * cs + cy + 0.5)
            local v = 0
            if xs >= 0 and xs < gw and ys >= 0 and ys < gh then v = mask[ys * gw + xs + 1] end
            out[y * gw + x + 1] = v
        end
    end
    return out
end

-- pixels: either a flat gray table, or {r=, g=, b=} flat tables, indexed
-- [y * gw + x + 1] with values 0..255 (y, x zero-based).
-- reading_dir: "ltr" | "rtl". Returns panels {x,y,w,h} normalized to 0..1,
-- already in reading order.
local function detectCore(planes, gw, gh, reading_dir, opts)
    local min_gap_x = math.max(2, math.floor(opt(opts, "gap_frac") * gw + 0.5))
    local min_gap_y = math.max(2, math.floor(opt(opts, "gap_frac") * gh + 0.5))
    local loose_min_x = math.max(3, math.floor(opt(opts, "loose_gap_frac") * gw + 0.5))
    local loose_min_y = math.max(3, math.floor(opt(opts, "loose_gap_frac") * gh + 0.5))
    local min_len_x = math.max(2, math.floor(opt(opts, "min_segment_frac") * gw))
    local min_len_y = math.max(2, math.floor(opt(opts, "min_segment_frac") * gh))
    local max_depth = opt(opts, "max_depth")
    local margin_x = math.floor(opt(opts, "edge_margin_frac") * gw)
    local margin_y = math.floor(opt(opts, "edge_margin_frac") * gh)
    local rtl = (reading_dir == "rtl")

    local bgr, bgg, bgb, noise = estimateBackground(planes, gw, gh, opt(opts, "border_frac"))
    -- Flat gutters need a tight tolerance (so pale sky/skin tones inside a panel
    -- are not mistaken for gutter); noisy scans widen it automatically.
    local tol = math.min(opt(opts, "max_tolerance"), math.max(opt(opts, "min_tolerance"), noise * 3 + 6))

    -- Background palette: border color plus flat gutter colors found in the page.
    local palette = { { bgr, bgg, bgb } }
    local gc = estimateGutterColors(planes, gw, gh, margin_x, margin_y, math.max(10, tol * 0.6), opt(opts, "loose_max_gap_frac"))
    for _, c in ipairs(gc) do
        if math.max(math.abs(c[1] - bgr), math.abs(c[2] - bgg), math.abs(c[3] - bgb)) > tol * 0.6 then
            palette[#palette + 1] = c
        end
    end
    if opts and opts.debug then
        for i, c in ipairs(palette) do print(string.format("  palette %d: %d %d %d (tol %.0f)", i, c[1], c[2], c[3], tol)) end
    end

    local okffi, ffi = pcall(require, "ffi")
    local mask = okffi and ffi.new("uint8_t[?]", gw * gh + 1) or {}
    local pr, pg, pb = planes.r, planes.g, planes.b
    for i = 1, gw * gh do
        local best = 1000
        for _, c in ipairs(palette) do
            local d = math.max(math.abs(pr[i] - c[1]), math.abs(pg[i] - c[2]), math.abs(pb[i] - c[3]))
            if d < best then best = d end
        end
        mask[i] = best > tol and 1 or 0
    end

    local function cut(mask)
    local panels = {}

    local function addLeaf(x0, y0, x1, y1)
        local p = {
            x = x0 / gw, y = y0 / gh,
            w = (x1 - x0) / gw, h = (y1 - y0) / gh,
        }
        if p.w >= opt(opts, "min_panel_w") and p.h >= opt(opts, "min_panel_h")
            and p.w * p.h >= opt(opts, "min_panel_area") then
            panels[#panels + 1] = p
        end
    end

    local levels = opt(opts, "noise_levels")
    local loose_gap_x = math.floor(opt(opts, "loose_max_gap_frac") * gw)
    local loose_gap_y = math.floor(opt(opts, "loose_max_gap_frac") * gh)

    local split

    -- Bands/columns of one region at a given tolerance level.
    local function rowSegs(x0, y0, x1, y1, level)
        local xa = (x0 == 0) and margin_x or 0
        local xb = (x1 == gw) and margin_x or 0
        return findSegments(rowCounts(mask, gw, x0, y0, x1, y1, xa, xb), y1 - y0,
            x1 - x0 - xa - xb, levels[level], level > 1 and loose_min_y or min_gap_y, min_len_y,
            level > 1 and loose_gap_y or nil)
    end
    local function colSegs(x0, y0, x1, y1, level)
        local ya = (y0 == 0) and margin_y or 0
        local yb = (y1 == gh) and margin_y or 0
        return findSegments(colCounts(mask, gw, x0, y0, x1, y1, ya, yb), x1 - x0,
            y1 - y0 - ya - yb, levels[level], level > 1 and loose_min_x or min_gap_x, min_len_x,
            level > 1 and loose_gap_x or nil)
    end

    local function recurseY(x0, y0, x1, y1, segs, depth)
        for _, s in ipairs(segs) do split(x0, y0 + s.s, x1, y0 + s.e, depth + 1) end
    end
    local function recurseX(x0, y0, x1, y1, segs, depth)
        local first, last, step = 1, #segs, 1
        if rtl then first, last, step = #segs, 1, -1 end
        for i = first, last, step do
            split(x0 + segs[i].s, y0, x0 + segs[i].e, y1, depth + 1)
        end
    end

    split = function(x0, y0, x1, y1, depth)
        if x1 <= x0 or y1 <= y0 then return end
        if opts and opts.debug then
            print(string.format("  split depth %d region x[%d,%d) y[%d,%d)", depth, x0, x1, y0, y1))
        end
        if depth > max_depth then
            addLeaf(x0, y0, x1, y1)
            return
        end

        -- Strictest tolerance first: also trims empty margins off the region.
        local ys = rowSegs(x0, y0, x1, y1, 1)
        if #ys == 0 then return end
        if #ys > 1 then return recurseY(x0, y0, x1, y1, ys, depth) end
        local ny0, ny1 = y0 + ys[1].s, y0 + ys[1].e

        local xs = colSegs(x0, ny0, x1, ny1, 1)
        if #xs == 0 then return end
        if #xs > 1 then return recurseX(x0, ny0, x1, ny1, xs, depth) end
        local nx0, nx1 = x0 + xs[1].s, x0 + xs[1].e

        if nx0 ~= x0 or nx1 ~= x1 or ny0 ~= y0 or ny1 ~= y1 then
            return split(nx0, ny0, nx1, ny1, depth + 1) -- trimmed; re-check
        end

        -- No clean gutter: tolerate progressively more content crossing the gutter
        -- (speech bubbles, tails, lettering) before declaring this a single panel.
        for level = 2, #levels do
            local lys = rowSegs(x0, y0, x1, y1, level)
            if #lys > 1 then return recurseY(x0, y0, x1, y1, lys, depth) end
            local lxs = colSegs(x0, y0, x1, y1, level)
            if #lxs > 1 then return recurseX(x0, y0, x1, y1, lxs, depth) end
        end
        addLeaf(x0, y0, x1, y1)
    end

    split(0, 0, gw, gh, 0)
    return panels
    end

    local panels = cut(mask)

    -- Slightly rotated scans have slanted gutters; retry on a deskewed mask and
    -- keep it only if it finds more panels.
    local skew = estimateSkew(mask, gw, gh, opt(opts, "max_skew_deg"), opt(opts, "skew_step_deg"), opts and opts.debug)
    if skew ~= 0 then
        local rotated_panels = cut(rotateMask(mask, gw, gh, skew))
        if opts and opts.debug then
            print(string.format("  skew %.2f deg: %d panels (unrotated %d)", skew, #rotated_panels, #panels))
        end
        if #rotated_panels > #panels then
            local phi = skew * math.pi / 180
            local sn, cs = math.sin(phi), math.cos(phi)
            local cx, cy = gw / 2, gh / 2
            local mapped = {}
            for _, p in ipairs(rotated_panels) do
                local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
                for _, c in ipairs({ { p.x, p.y }, { p.x + p.w, p.y }, { p.x, p.y + p.h }, { p.x + p.w, p.y + p.h } }) do
                    local dx, dy = c[1] * gw - cx, c[2] * gh - cy
                    local xs = dx * cs + dy * sn + cx
                    local ys = -dx * sn + dy * cs + cy
                    if xs < minx then minx = xs end
                    if xs > maxx then maxx = xs end
                    if ys < miny then miny = ys end
                    if ys > maxy then maxy = ys end
                end
                minx, miny = math.max(0, minx), math.max(0, miny)
                maxx, maxy = math.min(gw, maxx), math.min(gh, maxy)
                mapped[#mapped + 1] = { x = minx / gw, y = miny / gh, w = (maxx - minx) / gw, h = (maxy - miny) / gh }
            end
            panels = mapped
        end
    end
    return panels
end

-- pixels: flat gray table, or {r=, g=, b=}. Crops printed/scan borders first.
function PanelDetector.detect(pixels, gw, gh, reading_dir, opts)
    local planes = pixels.r and pixels or { r = pixels, g = pixels, b = pixels }
    if not (opts and opts.no_crop) then
        local x0, y0, x1, y1 = findPageBounds(planes, gw, gh, opts)
        if x0 and (x0 > 0.015 * gw or y0 > 0.015 * gh or gw - x1 > 0.015 * gw or gh - y1 > 0.015 * gh) then
            local cw, ch = x1 - x0, y1 - y0
            local okffi, ffi = pcall(require, "ffi")
            local sub = {}
            for _, k in ipairs({ "r", "g", "b" }) do
                local dst = okffi and ffi.new("uint8_t[?]", cw * ch + 1) or {}
                local src = planes[k]
                for y = 0, ch - 1 do
                    local sb, db = (y + y0) * gw + x0, y * cw
                    for x = 0, cw - 1 do dst[db + x + 1] = src[sb + x + 1] end
                end
                sub[k] = dst
            end
            -- Only a real scan border is worth cropping. If its color also shows up
            -- inside the page (thin gutters, margins), it is the page's own paper
            -- and cropping would just eat into the art: keep the page whole.
            local bgr, bgg, bgb = estimateBackground(planes, gw, gh, opt(opts, "border_frac"))
            local same, total = 0, 0
            for i = 1, cw * ch, 3 do
                total = total + 1
                if math.abs(sub.r[i] - bgr) <= 14 and math.abs(sub.g[i] - bgg) <= 14 and math.abs(sub.b[i] - bgb) <= 14 then
                    same = same + 1
                end
            end
            if same / total > 0.04 then
                return detectCore(planes, gw, gh, reading_dir, opts)
            end
            local sub_opts = {}
            for k, v in pairs(opts or {}) do sub_opts[k] = v end
            sub_opts.no_crop = true
            local found = PanelDetector.detect(sub, cw, ch, reading_dir, sub_opts)
            for _, p in ipairs(found) do
                p.x, p.y = (x0 + p.x * cw) / gw, (y0 + p.y * ch) / gh
                p.w, p.h = p.w * cw / gw, p.h * ch / gh
            end
            return found
        end
    end
    return detectCore(planes, gw, gh, reading_dir, opts)
end

PanelDetector._estimateBackground = estimateBackground

return PanelDetector

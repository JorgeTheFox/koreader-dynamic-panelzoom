-- Parses pre-computed panel data (sidecar JSON) into normalized panels per page.
--
-- Accepted layouts (already decoded from JSON):
--   1. panelreader.koplugin / process_manga.py:
--        { reading_direction = "rtl", pages = { { page = 1, panels = { {x=,y=,w=,h=}, ... } }, ... } }
--      Coordinates normalized 0..1. A panel may also be an array {x, y, w, h}.
--   2. Kumiko's native output (kumiko -i <dir>):
--        [ { filename = "...", size = {W, H}, panels = { {x, y, w, h}, ... } }, ... ]
--      Pixel coordinates; page number is the position in the list (1-based).
--
-- Pure Lua so it can be tested without KOReader.

local PanelJson = {}

local function num(v)
    v = tonumber(v)
    if v and v == v and v ~= math.huge and v ~= -math.huge then return v end
end

local function readBox(p)
    if type(p) ~= "table" then return end
    local x, y, w, h
    if p.x ~= nil then
        x, y, w, h = num(p.x), num(p.y), num(p.w or p.width), num(p.h or p.height)
    else
        x, y, w, h = num(p[1]), num(p[2]), num(p[3]), num(p[4])
    end
    if x and y and w and h and w > 0 and h > 0 then return x, y, w, h end
end

-- Returns a clamped normalized panel or nil if it falls outside the page.
local function normalize(x, y, w, h, page_w, page_h)
    if page_w and page_h then
        x, y, w, h = x / page_w, y / page_h, w / page_w, h / page_h
    end
    local x1, y1 = math.min(1, x + w), math.min(1, y + h)
    x, y = math.max(0, x), math.max(0, y)
    w, h = x1 - x, y1 - y
    if w <= 0.01 or h <= 0.01 then return end
    return { x = x, y = y, w = w, h = h }
end

-- Returns { [page_number] = { panels... } }, direction ("ltr"/"rtl"/nil) or nil, err
function PanelJson.parse(data)
    if type(data) ~= "table" then return nil, "not a table" end

    local pages, direction = {}, nil
    local list

    if type(data.pages) == "table" then
        list = data.pages
        if data.reading_direction == "rtl" or data.reading_direction == "ltr" then
            direction = data.reading_direction
        end
    elseif data[1] ~= nil then
        list = data
    else
        return nil, "unrecognized layout"
    end

    for index, entry in ipairs(list) do
        if type(entry) == "table" and type(entry.panels) == "table" then
            local page_no = num(entry.page) or index
            local pw, ph
            if type(entry.size) == "table" then pw, ph = num(entry.size[1]), num(entry.size[2]) end

            local panels = {}
            for _, raw in ipairs(entry.panels) do
                local x, y, w, h = readBox(raw)
                if x then
                    -- Values above 1 are pixels (Kumiko); they need the page size.
                    local pixels = (x + w > 1.5 or y + h > 1.5)
                    if pixels and not (pw and ph and pw > 0 and ph > 0) then
                        x = nil
                    end
                    if x then
                        local p = normalize(x, y, w, h, pixels and pw or nil, pixels and ph or nil)
                        if p then panels[#panels + 1] = p end
                    end
                end
            end
            if #panels > 0 then pages[page_no] = panels end
        end
    end

    if next(pages) == nil then return nil, "no usable panels" end
    return pages, direction
end

return PanelJson

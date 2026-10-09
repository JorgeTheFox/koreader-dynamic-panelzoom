--[[
PanelViewer - A custom image viewer designed specifically for panel navigation

This viewer is built from scratch using KOReader's widget system and APIs,
inspired by modern image rendering patterns. It provides optimized panel
viewing with custom padding, gesture handling, and smooth transitions.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local PanelViewer = InputContainer:extend{
    -- Core properties
    name = "PanelViewer",
    
    -- Image source (BlitBuffer or file path)
    image = nil,
    file = nil,
    
    -- Display properties
    fullscreen = true,
    buttons_visible = false,
    
    -- Panel-specific properties
    reading_direction = "ltr",
    panel_aspect_ratio = nil,  -- Panel aspect ratio from main.lua
    
    -- Callbacks for navigation
    onNext = nil,
    onPrev = nil,
    onClose = nil,
    
    -- Internal state
    _image_bb = nil,
    _rendered_size = nil,
    _display_rect = nil,
    _scaled_image_bb = nil, -- Cached scaled image for display
    _is_dirty = false,

    -- When true, gestures settle with a flashing full refresh to clear e-ink
    -- ghosting; when false, use a lighter partial refresh (no flash, may ghost)
    full_refresh = true,

    -- Zoom / pan state
    max_zoom = 3.0,            -- upper bound for pinch zoom (memory-bounded)
    _zoom = 1.0,              -- 1.0 = fit (default paint path); > 1 = zoomed
    _center_x_ratio = 0.5,    -- image point shown at screen center (0..1)
    _center_y_ratio = 0.5,
    _zoomed_bb = nil,         -- cached upscaled buffer for current zoom level
    _zoomed_for = nil,        -- zoom value _zoomed_bb was built at
    _panning = false,
    _pan_start_cx = 0.5,
    _pan_start_cy = 0.5,
}

function PanelViewer:init()
    -- Initialize touch zones for navigation
    self:setupTouchZones()
    
    -- Load and process the image
    self:loadImage()
    
    -- Calculate display dimensions
    self:calculateDisplayRect()
    
    logger.info(string.format("PanelViewer: Initialized with image %dx%d", 
        self._rendered_size and self._rendered_size.w or 0,
        self._rendered_size and self._rendered_size.h or 0))
end

function PanelViewer:setupTouchZones()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    -- Define tap zones: Left 30% (prev), Right 30% (next), Center 40% (close)
    local full_range = Geom:new{
        x = 0, y = 0,
        w = screen_width,
        h = screen_height
    }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full_range } },
        -- Pinch/spread to zoom (fired once on finger lift)
        Spread = { GestureRange:new{ ges = "spread", range = full_range } },
        Pinch = { GestureRange:new{ ges = "pinch", range = full_range } },
        -- Drag/swipe to pan when zoomed in
        Pan = { GestureRange:new{ ges = "pan", range = full_range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = full_range } },
        Swipe = { GestureRange:new{ ges = "swipe", range = full_range } },
    }

    -- Physical button navigation (Kobo page-turn buttons, etc.)
    if Device:hasKeys() then
        self.key_events = {
            KeyNext = { { Device.input.group.PgFwd } },
            KeyPrev = { { Device.input.group.PgBack } },
            KeyClose = { { Device.input.group.Back } },
        }
    end
end

function PanelViewer:loadImage()
    if not self.image and not self.file then
        logger.warn("PanelViewer: No image or file provided")
        return false
    end
    
    local image_bb = nil
    
    -- Load from BlitBuffer
    if self.image then
        image_bb = self.image
        logger.info("PanelViewer: Using provided BlitBuffer")
    -- Load from file with screen-size decoding for sharp rendering
    elseif self.file then
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        logger.info(string.format("PanelViewer: Loading image file at screen size %dx%d with dithering: %s", screen_w, screen_h, self.file))
        -- Pass screen dimensions to MuPDF for high-quality scaling during decode
        image_bb = RenderImage:renderImageFile(self.file, false, screen_w, screen_h)
        if not image_bb then
            logger.error("PanelViewer: Failed to load image file")
            return false
        end
    end
    
    self._image_bb = image_bb
    self._rendered_size = {
        w = image_bb:getWidth(),
        h = image_bb:getHeight()
    }
    
    return true
end

function PanelViewer:calculateDisplayRect()
    if not self._image_bb then return end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local img_w = self._image_bb:getWidth()
    local img_h = self._image_bb:getHeight()

    local function round(x)
        return math.floor(x + 0.5)
    end

    -- 🔒 Center-lock mode (panel center matching)
    if self.custom_position then
        self._display_rect = {
            x = self.custom_position.x,
            y = self.custom_position.y,
            w = img_w,
            h = img_h
        }
        self._scaled_image_bb = self._image_bb
        return
    end

    -- Default: centered image
    local display_x = round((screen_w - img_w) / 2)
    local display_y = round((screen_h - img_h) / 2)

    self._display_rect = {
        x = display_x,
        y = display_y,
        w = img_w,
        h = img_h
    }

    

    logger.info(string.format(
        "PanelViewer: Display rect %dx%d at (%d,%d) (1:1 blit)",
        img_w, img_h, display_x, display_y
    ))
end

function PanelViewer:onTap(_, ges)
    if not ges or not ges.pos then return false end
    
    local screen_w = Screen:getWidth()
    local x_pct = ges.pos.x / screen_w
    
    -- Determine direction based on reading direction
    local is_rtl = self.reading_direction == "rtl"
    
    -- Zone Logic: In RTL, Left is "Forward". In LTR, Right is "Forward".
    local is_forward = (is_rtl and x_pct < 0.3) or (not is_rtl and x_pct > 0.7)
    local is_backward = (is_rtl and x_pct > 0.7) or (not is_rtl and x_pct < 0.3)
    
    if is_forward then
        logger.info("PanelViewer: Forward tap detected")
        if self.onNext then self.onNext() end
        return true
    elseif is_backward then
        logger.info("PanelViewer: Backward tap detected")
        if self.onPrev then self.onPrev() end
        return true
    end
    
    -- Center tap while zoomed: reset back to fit instead of closing
    if self._zoom > 1.0 then
        logger.info("PanelViewer: Center tap while zoomed, resetting to fit")
        self:zoomTo(1.0)
        return true
    end

    -- Center tap: Close the viewer
    logger.info("PanelViewer: Center tap detected, closing viewer")
    if self.onClose then self.onClose() end
    return true
end

function PanelViewer:onKeyNext()
    logger.info("PanelViewer: Forward key detected")
    if self.onNext then self.onNext() end
    return true
end

function PanelViewer:onKeyPrev()
    logger.info("PanelViewer: Backward key detected")
    if self.onPrev then self.onPrev() end
    return true
end

function PanelViewer:onKeyClose()
    logger.info("PanelViewer: Close key detected")
    if self.onClose then self.onClose() end
    return true
end

-- === Zoom / pan ===========================================================

-- Build (or reuse) the upscaled buffer for the current zoom level. Uses
-- MuPDF's C scaler via RenderImage for speed/quality; the source panel image
-- is never freed (free_orig_bb = false).
function PanelViewer:_ensureZoomedBuffer()
    if not self._image_bb or not self._rendered_size then return end
    if self._zoomed_bb and self._zoomed_for == self._zoom then return end
    if self._zoomed_bb and self._zoomed_bb ~= self._image_bb then
        self._zoomed_bb:free()
    end
    self._zoomed_bb = nil
    local zw = math.floor(self._rendered_size.w * self._zoom + 0.5)
    local zh = math.floor(self._rendered_size.h * self._zoom + 0.5)
    self._zoomed_bb = RenderImage:scaleBlitBuffer(self._image_bb, zw, zh, false)
    self._zoomed_for = self._zoom
end

-- Keep the viewport within the image bounds (or centered if smaller).
function PanelViewer:_clampCenterRatios()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local zw = self._rendered_size.w * self._zoom
    local zh = self._rendered_size.h * self._zoom
    if zw <= sw then
        self._center_x_ratio = 0.5
    else
        local margin = (sw / 2) / zw
        self._center_x_ratio = math.max(margin, math.min(1 - margin, self._center_x_ratio))
    end
    if zh <= sh then
        self._center_y_ratio = 0.5
    else
        local margin = (sh / 2) / zh
        self._center_y_ratio = math.max(margin, math.min(1 - margin, self._center_y_ratio))
    end
end

function PanelViewer:zoomTo(new_zoom)
    new_zoom = math.max(1.0, math.min(self.max_zoom, new_zoom))
    if new_zoom == self._zoom then return end

    if new_zoom <= 1.0 then
        -- Exit zoom mode: drop cache, recenter, repaint with default path
        self._zoom = 1.0
        self._center_x_ratio = 0.5
        self._center_y_ratio = 0.5
        if self._zoomed_bb and self._zoomed_bb ~= self._image_bb then
            self._zoomed_bb:free()
        end
        self._zoomed_bb = nil
        self._zoomed_for = nil
    else
        self._zoom = new_zoom
        self:_ensureZoomedBuffer()
        self:_clampCenterRatios()
    end
    logger.info(string.format("PanelViewer: Zoom set to %.2f", self._zoom))
    self:update(self:_settleRefresh())
end

-- Reference dimension for turning a pinch/spread travel into a zoom ratio,
-- mirroring ImageViewer: relative to the smaller of screen vs current image.
function PanelViewer:_zoomRefDim(direction)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local iw = self._rendered_size.w * self._zoom
    local ih = self._rendered_size.h * self._zoom
    if direction == "horizontal" then
        return math.min(sw, iw)
    elseif direction == "vertical" then
        return math.min(sh, ih)
    end
    return math.min(math.sqrt(sw * sw + sh * sh), math.sqrt(iw * iw + ih * ih))
end

function PanelViewer:onSpread(_, ges)
    if not ges or not ges.distance then return true end
    local inc = ges.distance / self:_zoomRefDim(ges.direction)
    self:zoomTo(self._zoom * (1 + inc))
    return true
end

function PanelViewer:onPinch(_, ges)
    if not ges or not ges.distance then return true end
    local dec = ges.distance / self:_zoomRefDim(ges.direction)
    if dec >= 0.75 then dec = 0.75 end  -- large reductions are jarring
    self:zoomTo(self._zoom * (1 - dec))
    return true
end

-- Shift the centered point by a finger movement (screen pixels). The content
-- follows the finger, so the centered image pixel moves opposite, scaled by
-- the current zoomed dimensions.
function PanelViewer:_panByPixels(fx, fy)
    local zw = self._rendered_size.w * self._zoom
    local zh = self._rendered_size.h * self._zoom
    self._center_x_ratio = self._center_x_ratio - (fx or 0) / zw
    self._center_y_ratio = self._center_y_ratio - (fy or 0) / zh
    self:_clampCenterRatios()
    -- Single discrete move (swipe): settle refresh to avoid leaving ghosts
    self:update(self:_settleRefresh())
end

-- Drag to pan. To avoid e-ink ghosting we don't repaint live: we only track
-- the new center during the drag and repaint once on release. ges.relative is
-- cumulative from the gesture start, so we re-anchor from the touch-down center.
function PanelViewer:onPan(_, ges)
    -- Only pan when zoomed in; otherwise let taps/navigation handle it
    if self._zoom <= 1.0 then return false end
    if not self._panning then
        self._panning = true
        self._pan_start_cx = self._center_x_ratio
        self._pan_start_cy = self._center_y_ratio
    end
    local rel = ges and ges.relative or { x = 0, y = 0 }
    local zw = self._rendered_size.w * self._zoom
    local zh = self._rendered_size.h * self._zoom
    self._center_x_ratio = self._pan_start_cx - (rel.x or 0) / zw
    self._center_y_ratio = self._pan_start_cy - (rel.y or 0) / zh
    self:_clampCenterRatios()
    return true
end

function PanelViewer:onPanRelease(_, ges)
    if not self._panning then return true end
    self._panning = false
    -- Repaint once, settle refresh to keep the panel ghost-free
    self:update(self:_settleRefresh())
    return true
end

-- Fast finger drags register as swipes rather than pans; treat them as panning
-- when zoomed so the user can reach the off-screen parts of a big panel.
function PanelViewer:onSwipe(_, ges)
    if self._zoom <= 1.0 then return false end
    local d = (ges and ges.distance) or 0
    local sq = math.sqrt(d * d / 2)
    local dir = ges and ges.direction
    if dir == "east" then
        self:_panByPixels(d, 0)
    elseif dir == "west" then
        self:_panByPixels(-d, 0)
    elseif dir == "north" then
        self:_panByPixels(0, -d)
    elseif dir == "south" then
        self:_panByPixels(0, d)
    elseif dir == "northeast" then
        self:_panByPixels(sq, -sq)
    elseif dir == "northwest" then
        self:_panByPixels(-sq, -sq)
    elseif dir == "southeast" then
        self:_panByPixels(sq, sq)
    elseif dir == "southwest" then
        self:_panByPixels(-sq, sq)
    else
        return false
    end
    return true
end

-- Paint the zoomed viewport: a screen-sized window into the upscaled buffer,
-- centered on (_center_x_ratio, _center_y_ratio), white where it falls short.
function PanelViewer:_paintZoomed(bb, x, y)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local zbb = self._zoomed_bb
    local zw = zbb:getWidth()
    local zh = zbb:getHeight()
    local white = Blitbuffer.Color8(255)

    bb:paintRect(x, y, sw, sh, white)

    local vx = math.floor(self._center_x_ratio * zw - sw / 2 + 0.5)
    local vy = math.floor(self._center_y_ratio * zh - sh / 2 + 0.5)
    if zw <= sw then
        vx = math.floor((zw - sw) / 2)
    else
        vx = math.max(0, math.min(zw - sw, vx))
    end
    if zh <= sh then
        vy = math.floor((zh - sh) / 2)
    else
        vy = math.max(0, math.min(zh - sh, vy))
    end

    local dst_x = vx < 0 and -vx or 0
    local dst_y = vy < 0 and -vy or 0
    local src_x = vx > 0 and vx or 0
    local src_y = vy > 0 and vy or 0
    local cw = math.min(sw - dst_x, zw - src_x)
    local ch = math.min(sh - dst_y, zh - src_y)

    if cw > 0 and ch > 0 then
        if Screen.sw_dithering then
            bb:ditherblitFrom(zbb, x + dst_x, y + dst_y, src_x, src_y, cw, ch)
        else
            bb:blitFrom(zbb, x + dst_x, y + dst_y, src_x, src_y, cw, ch)
        end
    end

    self._is_dirty = false
end

function PanelViewer:paintTo(bb, x, y)
    if not self._image_bb then return end

    -- Zoomed: render the pan viewport and skip the fit-view border drawing
    if self._zoom > 1.0 and self._zoomed_bb then
        self:_paintZoomed(bb, x, y)
        return
    end

    if not self._scaled_image_bb then return end
    
    -- Get screen-space rectangle (single source of truth)
    local screen_rect = self:getScreenRect()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local white_color = Blitbuffer.Color8(255)
    local black_color = Blitbuffer.Color8(0)
    
    -- Paint entire background white
   -- Top
bb:paintRect(0, 0, screen_w, screen_rect.y, white_color)
-- Bottom
bb:paintRect(0, screen_rect.y + screen_rect.h,
             screen_w, screen_h - (screen_rect.y + screen_rect.h), white_color)
-- Left
bb:paintRect(0, screen_rect.y,
             screen_rect.x, screen_rect.h, white_color)
-- Right
bb:paintRect(screen_rect.x + screen_rect.w, screen_rect.y,
             screen_w - (screen_rect.x + screen_rect.w), screen_rect.h, white_color)

    
    -- KOADER MUFPDF LOGIC: Enable dithering for E-ink displays to prevent artifacts
    -- KOReader uses dithering for 8bpp displays and grayscale content
    -- For manga panels on E-ink, we need dithering to avoid banding artifacts
    if Screen.sw_dithering then
        bb:ditherblitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
    else
        bb:blitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
    end
    
    -- Add white frame/border on top of the image
    -- This creates a white outline that covers the image edges
    local border_thickness = 50
    local side_thickness = 50  -- Reverted back to 30px outward
    local border_color = white_color  -- Changed to white
    
    -- Check if panel is square using screen rect aspect ratio
    -- The screen rect represents what's actually displayed, so that's what matters for border logic
    local screen_aspect_ratio = screen_rect.w / screen_rect.h
    local is_square = (screen_aspect_ratio >= 0.1 and screen_aspect_ratio <= 1.5)
    
    logger.info(string.format("PanelViewer: Screen rect aspect_ratio: %.3f, is_square: %s", 
                 screen_aspect_ratio, tostring(is_square)))
    
    -- Additional info about panel type
    if screen_aspect_ratio < 0.67 then
        logger.info("PanelViewer: This is a tall vertical panel (< 0.67)")
    elseif screen_aspect_ratio > 1.5 then
        logger.info("PanelViewer: This is a wide horizontal panel (> 1.5)")
    else
        logger.info("PanelViewer: This is a standard/square panel (0.67-1.5)")
    end
    
    -- Debug border coordinates
    logger.info(string.format("PanelViewer: Screen rect: x=%d, y=%d, w=%d, h=%d", 
                 screen_rect.x, screen_rect.y, screen_rect.w, screen_rect.h))
    
    -- Top border (hidden)
    -- bb:paintRect(screen_rect.x - border_thickness, screen_rect.y - border_thickness, 
    --              screen_rect.w + (border_thickness * 2), border_thickness, black_color)
    
    -- Bottom border (hidden)
    -- bb:paintRect(screen_rect.x - border_thickness, screen_rect.y + screen_rect.h, 
    --              screen_rect.w + (border_thickness * 2), border_thickness, black_color)
    
    -- Left border (30px thick, +15px inward for square panels) - drawn on top of image
    local left_thickness = side_thickness
    local left_inward_extension = 0
    
    if is_square then
        left_inward_extension = 4  -- Increased to 6px
        logger.info("PanelViewer: Square panel detected, adding 6px inward extension to left border")
    end
    
    local total_left_thickness = left_thickness + left_inward_extension
    logger.info(string.format("PanelViewer: Left border: thickness=%d + extension=%d = total=%d", 
                 left_thickness, left_inward_extension, total_left_thickness))
    logger.info(string.format("PanelViewer: Drawing left border at x=%d, y=%d, w=%d, h=%d", 
                 screen_rect.x - left_thickness, screen_rect.y - border_thickness, 
                 total_left_thickness, screen_rect.h + (border_thickness * 2)))
    
    bb:paintRect(screen_rect.x - left_thickness, screen_rect.y - border_thickness, 
                 total_left_thickness, screen_rect.h + (border_thickness * 2), border_color)
    
    -- Right border (30px thick, +15px inward for square panels) - drawn on top of image
    local right_thickness = side_thickness
    local right_inward_extension = 0
    
    if is_square then
        right_inward_extension = 0  -- Increased to 2px
        logger.info("PanelViewer: Square panel detected, adding 2px inward extension to right border")
    else
        logger.info("PanelViewer: Not a square panel, using standard right border")
    end
    
    local total_right_thickness = right_thickness + right_inward_extension
    logger.info(string.format("PanelViewer: Right border: thickness=%d + extension=%d = total=%d", 
                 right_thickness, right_inward_extension, total_right_thickness))
    logger.info(string.format("PanelViewer: Drawing right border at x=%d, y=%d, w=%d, h=%d", 
                 screen_rect.x + screen_rect.w - right_inward_extension, screen_rect.y - border_thickness, 
                 total_right_thickness, screen_rect.h + (border_thickness * 2)))
    
    bb:paintRect(screen_rect.x + screen_rect.w - right_inward_extension, screen_rect.y - border_thickness, 
                 total_right_thickness, screen_rect.h + (border_thickness * 2), border_color)
    
    self._is_dirty = false
end

function PanelViewer:getScreenRect()
    -- Single source of truth for screen-space coordinates
    -- Future-proof: supports animations, transforms, partial redraws
    if not self._display_rect then
        -- Fallback: full screen
        return {
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight()
        }
    end
    
    return {
        x = self._display_rect.x,
        y = self._display_rect.y,
        w = self._display_rect.w,
        h = self._display_rect.h
    }
end

function PanelViewer:getSize()
    return Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight()
    }
end

function PanelViewer:updateImage(new_image)
    -- Update the image source
    if self._image_bb and self._image_bb ~= self.image then
        self._image_bb:free()
    end
    
    -- Reset zoom/pan for the new panel
    if self._zoomed_bb and self._zoomed_bb ~= self._image_bb then
        self._zoomed_bb:free()
    end
    self._zoomed_bb = nil
    self._zoomed_for = nil
    self._zoom = 1.0
    self._center_x_ratio = 0.5
    self._center_y_ratio = 0.5
    self._panning = false

    self.image = new_image
    self._image_bb = new_image
    self:loadImage()
    self:calculateDisplayRect()
    self._is_dirty = true

    logger.info("PanelViewer: Image updated")
end

function PanelViewer:update(refresh_type)
    -- KOADER MUFPDF LOGIC: Use proper refresh types like ImageViewer.
    -- "ui" for smooth intermediate frames; "full" to clear e-ink ghosting
    -- once a gesture (pan/zoom) settles.
    refresh_type = refresh_type or "ui"
    self._is_dirty = true
    UIManager:setDirty(self, function()
        return refresh_type, self.dimen, Screen.sw_dithering  -- Enable dithering for E-ink
    end)
    logger.info("PanelViewer: Update called with refresh type " .. refresh_type)
end

-- Refresh type used when a gesture settles: flashing full refresh to clear
-- ghosting, unless the user opted out (then a lighter partial refresh).
function PanelViewer:_settleRefresh()
    return self.full_refresh and "full" or "ui"
end

function PanelViewer:updateReadingDirection(direction)
    self.reading_direction = direction or "ltr"
    logger.info(string.format("PanelViewer: Reading direction set to %s", self.reading_direction))
end

function PanelViewer:updateCustomPosition(custom_position)
    self.custom_position = custom_position
    -- Recalculate display rect with new position
    self:calculateDisplayRect()
    logger.info("PanelViewer: Custom position updated and display rect recalculated")
end

function PanelViewer:freeResources()
    -- BEST: No separate scaled image to free (1:1 blitting)
    -- Only free the original if it's not externally managed
    if self._zoomed_bb and self._zoomed_bb ~= self._image_bb then
        self._zoomed_bb:free()
    end
    self._zoomed_bb = nil
    self._zoomed_for = nil
    if self._image_bb and self._image_bb ~= self.image then
        self._image_bb:free()
        self._image_bb = nil
    end
    self._scaled_image_bb = nil  -- Just clear the reference
    logger.info("PanelViewer: Resources freed (1:1 blit mode)")
end

function PanelViewer:close()
    self:freeResources()
    UIManager:close(self)
end

return PanelViewer

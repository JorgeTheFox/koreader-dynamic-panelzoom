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
    covers_fullscreen = true,  -- Prevents UIManager from repainting widgets below us (avoids E-Ink flash on page change)
    buttons_visible = false,
    
    -- Panel-specific properties
    reading_direction = "ltr",
    panel_aspect_ratio = nil,  -- Panel aspect ratio from main.lua
    
    -- Callbacks for navigation
    onNext = nil,
    onPrev = nil,
    onClose = nil,
    onHold = nil,
    
    -- Internal state
    _image_bb = nil,
    _rendered_size = nil,
    _display_rect = nil,
    _scaled_image_bb = nil, -- Cached scaled image for display
    _is_dirty = false,
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
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = screen_width,
                    h = screen_height
                }
            }
        },
        Hold = {
            GestureRange:new{
                ges = "hold",
                range = Geom:new{
                    x = 0, y = 0,
                    w = screen_width,
                    h = screen_height
                }
            }
        }
    }

    -- Register hardware page-turn keys (Boox, Kindle, Kobo, etc.).
    -- Using input groups rather than raw key names keeps this device-agnostic
    -- and automatically honors the user's "Invert page-turn buttons" setting.
    if Device:hasKeys() then
        self.key_events = {
            Next = { { Device.input.group.PgFwd } },
            Prev = { { Device.input.group.PgBack } },
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

    -- ðŸ”’ Center-lock mode (panel center matching)
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
    
    if x_pct > 0.7 then
        logger.info("PanelViewer: Right tap detected")
        if self.onTapRight then self.onTapRight() end
        return true
    elseif x_pct < 0.3 then
        logger.info("PanelViewer: Left tap detected")
        if self.onTapLeft then self.onTapLeft() end
        return true
    end
    
    -- Center tap: Close the viewer
    logger.info("PanelViewer: Center tap detected, closing viewer")
    if self.onClose then self.onClose() end
    return true
end

function PanelViewer:onHold(_, ges)
    logger.info("PanelViewer: Hold gesture detected, triggering zoom mode")
    if self.onHold then self.onHold() end
    return true
end

function PanelViewer:onNext()
    logger.info("PanelViewer: PgFwd key received, forwarding to next panel")
    if self.reading_direction == "rtl" then
        if self.onTapLeft then self.onTapLeft() end
    else
        if self.onTapRight then self.onTapRight() end
    end
    return true
end

function PanelViewer:onPrev()
    logger.info("PanelViewer: PgBack key received, forwarding to previous panel")
    if self.reading_direction == "rtl" then
        if self.onTapRight then self.onTapRight() end
    else
        if self.onTapLeft then self.onTapLeft() end
    end
    return true
end

function PanelViewer:paintTo(bb, x, y)
    if not self._image_bb or not self._scaled_image_bb then return end
    
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
    
    self.image = new_image
    self._image_bb = new_image
    self:loadImage()
    self:calculateDisplayRect()
    self._is_dirty = true
    
    logger.info("PanelViewer: Image updated")
end

function PanelViewer:update()
    -- KOADER MUFPDF LOGIC: Use proper refresh types like ImageViewer
    -- For panel viewing, we want "ui" refresh for smooth transitions
    -- and "flashui" for initial display to ensure crisp rendering
    self._is_dirty = true
    UIManager:setDirty(self, function()
        return "ui", self.dimen, Screen.sw_dithering  -- Enable dithering for E-ink
    end)
    logger.info("PanelViewer: Update called with KOReader refresh logic")
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

function PanelViewer:updatePanelAspectRatio(ratio)
    self.panel_aspect_ratio = ratio
    self._is_dirty = true
    logger.info(string.format("PanelViewer: Panel aspect ratio updated to %.3f", ratio or 0))
end

function PanelViewer:freeResources()
    -- BEST: No separate scaled image to free (1:1 blitting)
    -- Only free the original if it's not externally managed
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

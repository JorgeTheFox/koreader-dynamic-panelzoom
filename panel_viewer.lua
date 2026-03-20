--[[
PanelViewer - Custom Image Viewer for Comic Panels

This widget is an image viewer built from scratch specifically for
comic panel navigation. It handles rendering the panel, managing
tap gestures, and ensuring a smooth experience on E-Ink devices.

Inspired by modern rendering APIs, it provides finer control over
positioning, scaling, and transitions compared to standard viewers.
]]

-- KOReader Dependencies
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

-- Utilities
local logger = require("logger")
local _ = require("gettext")

-- ===================================================================
-- CLASS: PanelViewer
-- An input container that displays an image fullscreen and
-- responds to tap gestures for navigation.
-- ===================================================================
local PanelViewer = InputContainer:extend{
    -- --- PROPERTIES ---
    name = "PanelViewer",
    image = nil,                 -- The panel image (a BlitBuffer) to display
    fullscreen = true,           -- Always force fullscreen display
    reading_direction = "ltr", -- Current reading direction (ltr/rtl)
    custom_position = nil,       -- Custom coordinates for smart centering

    -- --- CALLBACKS ---
    -- These are assigned by main.lua to connect the UI back to the core logic
    onNext = nil,
    onPrev = nil,
    onClose = nil,
    
    -- --- INTERNAL STATE ---
    _image_bb = nil,             -- Buffer of the original image
    _display_rect = nil,         -- The rectangle defining where the image is drawn on screen
}

--
-- FUNCTION: init()
-- Executed when a new PanelViewer instance is created.
--
function PanelViewer:init()
    -- 1. Configure the screen zones that will respond to tap gestures
    self:setupTouchZones()
    -- 2. Load and process the provided panel image
    self:loadImage()
    -- 3. Calculate the dimensions and position for drawing the image
    self:calculateDisplayRect()
end

--
-- FUNCTION: setupTouchZones()
-- Defines the screen areas for next, previous, and close actions.
--
function PanelViewer:setupTouchZones()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    
    -- We create a single "Tap" gesture handler that covers the entire screen.
    -- The logic to decide the action (next/prev/close) based on the tap coordinates
    -- is handled within the onTap() function.
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
            }
        }
    }
end

--
-- FUNCTION: loadImage()
-- Loads the image from the BlitBuffer provided by main.lua.
--
function PanelViewer:loadImage()
    if not self.image then
        logger.warn("PanelViewer: No image was provided.")
        return false
    end
    self._image_bb = self.image
    return true
end

--
-- FUNCTION: calculateDisplayRect()
-- Calculates the destination rectangle for the panel image on the screen.
-- Utilizes the `custom_position` if provided for smart "center-lock" positioning.
--
function PanelViewer:calculateDisplayRect()
    if not self._image_bb then return end

    -- If main.lua provided a custom position, use it.
    -- This is crucial for the "center-lock" feature, maintaining visual stability across panels.
    if self.custom_position then
        self._display_rect = {
            x = self.custom_position.x,
            y = self.custom_position.y,
            w = self._image_bb:getWidth(),
            h = self._image_bb:getHeight()
        }
    else
        -- Fallback: simply center the image dead-center on the screen.
        local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
        local img_w, img_h = self._image_bb:getWidth(), self._image_bb:getHeight()
        self._display_rect = {
            x = math.floor((screen_w - img_w) / 2 + 0.5),
            y = math.floor((screen_h - img_h) / 2 + 0.5),
            w = img_w,
            h = img_h
        }
    end
end

--
-- FUNCTION: onTap(_, ges)
-- Gesture handler for taps. Determines whether to navigate forward, backward, or close.
--
function PanelViewer:onTap(_, ges)
    if not ges or not ges.pos then return false end
    
    -- Calculate the horizontal percentage of the screen that was tapped (0.0 to 1.0)
    local x_pct = ges.pos.x / Screen:getWidth()
    
    -- Tap zone logic depends entirely on the reading direction
    local is_rtl = self.reading_direction == "rtl"
    local next_zone, prev_zone = 0.7, 0.3 -- Standard zones for LTR (Western comics)
    if is_rtl then
        next_zone, prev_zone = 0.3, 0.7 -- Inverted zones for RTL (Manga)
    end
    
    if x_pct > next_zone then
        if self.onNext then self.onNext() end
    elseif x_pct < prev_zone then
        if self.onPrev then self.onPrev() end
    else
        -- Tapping the center area (between the prev and next zones) closes the viewer
        if self.onClose then self.onClose() end
    end
    
    return true
end

--
-- FUNCTION: paintTo(bb, x, y)
-- The core drawing function. Called by KOReader's UI manager whenever
-- the screen needs to be refreshed.
--
function PanelViewer:paintTo(bb, x, y)
    if not self._image_bb or not self._display_rect then return end
    
    -- First, paint the entire background white to clear any artifacts from the previous screen
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    bb:paintRect(0, 0, screen_w, screen_h, Blitbuffer.Color8(255))

    -- Draw the panel image at the calculated coordinates.
    -- Using "ditherblitFrom" is highly recommended on E-Ink displays for grayscale
    -- content (like manga) to improve image quality and significantly reduce banding.
    if Screen.sw_dithering then
        bb:ditherblitFrom(self._image_bb, self._display_rect.x, self._display_rect.y, 0, 0, self._display_rect.w, self._display_rect.h)
    else
        bb:blitFrom(self._image_bb, self._display_rect.x, self._display_rect.y, 0, 0, self._display_rect.w, self._display_rect.h)
    end
end


-- ===================================================================
-- UPDATE FUNCTIONS
-- ===================================================================

--
-- FUNCTION: updateImage(new_image)
-- Allows main.lua to swap the displayed image (e.g., when transitioning to a preloaded panel)
-- without creating a new PanelViewer instance.
--
function PanelViewer:updateImage(new_image)
    self.image = new_image
    self:loadImage()
    self:calculateDisplayRect()
end

--
-- FUNCTION: updateCustomPosition(custom_position)
-- Allows main.lua to update the centering position for the current image.
--
function PanelViewer:updateCustomPosition(custom_position)
    self.custom_position = custom_position
    self:calculateDisplayRect()
end

--
-- FUNCTION: update()
-- Triggers a UI repaint for this widget.
--
function PanelViewer:update()
    UIManager:setDirty(self, "ui")
end

-- ===================================================================
-- WIDGET LIFECYCLE MANAGEMENT
-- ===================================================================

function PanelViewer:getScreenRect()
    return self._display_rect or Geom:new{ x=0, y=0, w=Screen:getWidth(), h=Screen:getHeight() }
end

function PanelViewer:getSize()
    return Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
end

function PanelViewer:close()
    UIManager:close(self)
end

return PanelViewer

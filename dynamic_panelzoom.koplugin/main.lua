local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PanelViewer = require("panel_viewer")
local _ = require("gettext")
local logger = require("logger")
local util = require("util")
local json = require("json")

local PanelZoomIntegration = WidgetContainer:extend{
    name = "dynamic_panelzoom",
    integration_mode = false,
    current_panels = {},
    current_panel_index = 1,
    last_page_seen = -1,
    tap_navigation_enabled = true,
    tap_zones = { left = 0.3, right = 0.7 },
    _panel_cache = {}, -- Cache JSON per document
    _preloaded_image = nil, -- Pre-rendered next panel
    _preloaded_panel_index = nil, -- Index of preloaded panel
    _is_switching = false, -- Debounce guard to prevent fast tap issues
    _is_changing_page = false, -- True while a page change is in progress
    _page_change_diff = nil, -- Direction of current page change (+1 or -1)
    _original_panel_zoom_handler = nil, -- Store original panel zoom handler
    _original_ocr_handler = nil, -- Store original OCR handler
    _original_ocr_menu_enabled = nil, -- Store original OCR menu state
    _original_genPanelZoomMenu = nil, -- Store original panel zoom menu function
    _json_available = false, -- Track if JSON is available for current document
    reading_direction_override = nil, -- User override for reading direction (rtl/ltr)
    zoom_margin_percent = 0.05, -- Default 5% extra margin for the free zoom mode
    standard_margin_percent = 0.0, -- Default 0% extra margin for standard panel-by-panel navigation
    show_adjacent_panels = true,   -- Show adjacent content (Smart Fill)
    zoom_initial_scale = 1.2, -- Default 1.2x initial software scale for the free zoom mode
}

function PanelZoomIntegration:init()
    -- Auto-detect JSON and integrate with Panel Zoom when document is opened
    self.onDocumentLoaded = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Page change handler: event-driven panel transitions
    -- KOReader dispatches PageUpdate as: handler(self, new_page_no, orig_mode)
    -- When _is_changing_page is true, the event was triggered by our changePage()
    -- call to onGotoViewRel(), so we handle the panel transition.
    -- Otherwise it's a normal page change (user swipe, menu, etc.)
    self.onPageUpdate = function(_, new_page_no)
        if self._is_changing_page then
            self:_onPageChangeComplete(new_page_no)
        else
            self:checkAndIntegratePanelZoom()
        end
    end
    
    -- Optional: Re-render current panel if document settings change
    self.onSettingsUpdate = function()
        if self._current_imgviewer and self.integration_mode then
            logger.info("PanelZoom: Settings changed, refreshing current panel")
            self:displayCurrentPanel()
        end
    end
    
    -- Integrate with existing panel zoom menu
    self:setupPanelZoomMenuIntegration()
end

-- Get effective reading direction (override takes precedence over JSON)
function PanelZoomIntegration:getEffectiveReadingDirection()
    -- No longer use a non-existent JSON property. Default is ltr unless overridden.
    if self.reading_direction_override then
        return self.reading_direction_override
    end
    return "ltr"
end

-- Check if document is compatible and integrate with Panel Zoom automatically
function PanelZoomIntegration:checkAndIntegratePanelZoom()
    if not self.ui.document then return end
    
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    -- Dynamic Panel Zoom is always available, we just integrate it
    self._json_available = true -- we fake it to keep the integration flag happy
    self:integrateWithPanelZoom()
    logger.info("DynamicPanelZoom: Auto-integration enabled")
end

-- Integrate with built-in Panel Zoom
function PanelZoomIntegration:integrateWithPanelZoom()
    if not self.ui.highlight then return end
    
    -- Store the original handler if not already stored
    if not self._original_panel_zoom_handler then
        self._original_panel_zoom_handler = self.ui.highlight.onPanelZoom
    end
    
    -- Store the original panel zoom enabled state
    if self._original_panel_zoom_enabled == nil then
        self._original_panel_zoom_enabled = self.ui.highlight.panel_zoom_enabled
    end
    
    -- Override Panel Zoom to use our JSON when available
    self.ui.highlight.onPanelZoom = function(inst, arg, ges)
        return self:onIntegratedPanelZoom(arg, ges)
    end
    
    self.integration_mode = true
    if self.ui.highlight then self.ui.highlight.panel_zoom_enabled = true end
    
    -- Block OCR when Panel Zoom integration is active
    self:blockOCR()
end

-- Restore original Panel Zoom behavior
function PanelZoomIntegration:restoreOriginalPanelZoom()
    if not self.ui.highlight then return end
    
    -- Restore the original handler
    if self._original_panel_zoom_handler then
        self.ui.highlight.onPanelZoom = self._original_panel_zoom_handler
    else
        self.ui.highlight.onPanelZoom = nil
    end
    
    -- Restore the original panel zoom enabled state
    if self._original_panel_zoom_enabled ~= nil then
        self.ui.highlight.panel_zoom_enabled = self._original_panel_zoom_enabled
    end
    
    self.integration_mode = false
    
    -- Restore OCR when Panel Zoom integration is disabled
    self:restoreOCR()
    
    -- Restore original panel zoom menu
    self:restorePanelZoomMenu()
end

-- Block OCR functionality when Panel Zoom is active
function PanelZoomIntegration:blockOCR()
    -- Store original OCR handler if not already stored
    if not self._original_ocr_handler and self.ui.ocr then
        self._original_ocr_handler = self.ui.ocr.onOCRText
    end
    
    -- Disable OCR by replacing the handler with a no-op function
    if self.ui.ocr then
        self.ui.ocr.onOCRText = function()
            logger.info("DynamicPanelZoom: OCR blocked - Panel Zoom integration is active")
            return false
        end
        logger.info("DynamicPanelZoom: OCR functionality blocked")
    end
    
    -- Also disable OCR menu items if available
    if self.ui.menu and self.ui.menu.ocr_menu then
        self._original_ocr_menu_enabled = self.ui.menu.ocr_menu.enabled
        self.ui.menu.ocr_menu.enabled = false
        logger.info("DynamicPanelZoom: OCR menu items disabled")
    end
end

-- Restore OCR functionality when Panel Zoom is disabled
function PanelZoomIntegration:restoreOCR()
    -- Guard against multiple restoration calls
    if not self._original_ocr_handler and (self._original_ocr_menu_enabled == nil) then
        return -- Already restored or never stored
    end
    
    -- Restore original OCR handler
    if self.ui.ocr and self._original_ocr_handler then
        self.ui.ocr.onOCRText = self._original_ocr_handler
        self._original_ocr_handler = nil
        logger.info("DynamicPanelZoom: OCR functionality restored")
    end
    
    -- Restore OCR menu items
    if self.ui.menu and self.ui.menu.ocr_menu and self._original_ocr_menu_enabled ~= nil then
        self.ui.menu.ocr_menu.enabled = self._original_ocr_menu_enabled
        self._original_ocr_menu_enabled = nil
        logger.info("DynamicPanelZoom: OCR menu items restored")
    end
end

-- Callback methods for PanelViewer
-- Spatial navigation methods for PanelViewer
function PanelZoomIntegration:handleTapRight()
    if self._is_switching or self._is_changing_page then return end
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    -- In absolute spatial terms:
    -- If LTR: Right tap means "go to next panel" (index + 1 in the correctly sorted array)
    -- If RTL: Right tap means "go to previous panel" (index - 1 in the correctly sorted array)
    if not is_rtl then
        -- LTR Flow
        -- Check preload first for LTR Next
        if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
            logger.info("PanelZoom: Using preloaded panel for instant switch (LTR Right)")
            self.current_panel_index = self.current_panel_index + 1
            self:displayPreloadedPanel()
            return
        end
        
        if self.current_panel_index < #self.current_panels then
            self.current_panel_index = self.current_panel_index + 1
            self:displayCurrentPanel()
        else
            -- LTR: End of page, right tap goes to next page
            logger.info("PanelZoom: Bottom-right reached (LTR), jumping to next page")
            self:changePage(1)
        end
    else
        -- RTL Flow: Right tap goes backwards in reading order (index - 1)
        if self.current_panel_index > 1 then
            self.current_panel_index = self.current_panel_index - 1
            self:displayCurrentPanel()
        else
            -- RTL: Top-right reached, right tap goes to previous page
            logger.info("PanelZoom: Top-right reached (RTL), jumping to previous page")
            self:changePage(-1)
        end
    end
end

function PanelZoomIntegration:handleTapLeft()
    if self._is_switching or self._is_changing_page then return end
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    -- In absolute spatial terms:
    -- If LTR: Left tap means "go to previous panel" (index - 1)
    -- If RTL: Left tap means "go to next panel" (index + 1)
    if not is_rtl then
        -- LTR Flow: Left tap goes backwards
        if self.current_panel_index > 1 then
            self.current_panel_index = self.current_panel_index - 1
            self:displayCurrentPanel()
        else
            -- LTR: Top-left reached, left tap goes to previous page
            logger.info("PanelZoom: Top-left reached (LTR), jumping to previous page")
            self:changePage(-1)
        end
    else
        -- RTL Flow: Left tap goes forwards (index + 1)
        -- Check preload first for RTL Next
        if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
            logger.info("PanelZoom: Using preloaded panel for instant switch (RTL Left)")
            self.current_panel_index = self.current_panel_index + 1
            self:displayPreloadedPanel()
            return
        end
        
        if self.current_panel_index < #self.current_panels then
            self.current_panel_index = self.current_panel_index + 1
            self:displayCurrentPanel()
        else
            -- RTL: Bottom-left reached, left tap goes to next page
            logger.info("PanelZoom: Bottom-left reached (RTL), jumping to next page")
            self:changePage(1)
        end
    end
end

function PanelZoomIntegration:closeViewer()
    if self._current_imgviewer then
        -- Ensure E-Ink refresh suppression is restored if we were mid-page-change
        if UIManager.currently_scrolling then
            UIManager.currently_scrolling = false
        end
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
        self:cleanupPreloadedImage()
        -- Restore OCR when panel viewer is closed
        self:restoreOCR()
    end
end

-- Preload the next panel in background
function PanelZoomIntegration:preloadNextPanel()
    -- Clean up any existing preloaded image
    self:cleanupPreloadedImage()
    
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    -- In absolute terms, "next" means index+1 (if LTR) or index-1 (if RTL)
    -- Actually, wait: the index IS correctly sorted in importToggleZoomPanels based on reading direction!
    -- Yes, the array is ALWAYS sorted so that index 1 is the START and index N is the END of the page.
    -- So "next panel in logical reading order" is always index + 1!
    local next_panel_index = self.current_panel_index + 1
    
    -- Check if there's a next panel to preload
    if next_panel_index <= #self.current_panels then
        local next_panel = self.current_panels[next_panel_index]
        
        if next_panel then
            logger.info(string.format("DynamicPanelZoom: Preloading panel %d in background", next_panel_index))
            
            local page = self:getSafePageNumber()
            local dim = self.ui.document:getNativePageDimensions(page)
            
            if dim then
                -- Calculate and log panel center coordinates for preloaded panel
                local center = self:calculatePanelCenter(next_panel, dim)
                
                -- Use helper function for center-preserving quantization
                local margin = self.standard_margin_percent or 0.0
                local rect = self:panelToRect(next_panel, dim, margin)
                
                -- Render the next panel with document settings (standard margins for preloading)
                local image, rotate, custom_position = self:drawPagePartWithSettings(page, rect, center, next_panel, dim)
                -- Store preloaded image with panel data for proper centering
                if image then
                    self._preloaded_image = image
                    self._preloaded_panel_index = next_panel_index
                    self._preloaded_panel = next_panel  -- Store panel data
                    self._preloaded_dim = dim          -- Store dimensions
                    self._preloaded_custom_position = custom_position  -- Store calculated position
                    logger.info("DynamicPanelZoom: Successfully preloaded next panel with document settings")
                else
                    logger.warn("DynamicPanelZoom: Failed to preload next panel")
                end
            end
        end
    end
end

-- Display preloaded panel instantly
function PanelZoomIntegration:displayPreloadedPanel()
    if not self._preloaded_image or not self._current_imgviewer then
        logger.warn("DynamicPanelZoom: No preloaded image or viewer available")
        return false
    end
    
    logger.info("DynamicPanelZoom: Displaying preloaded panel instantly")
    
    -- Update existing viewer with preloaded image using PanelViewer's method
    self._current_imgviewer:updateImage(self._preloaded_image)
    
    -- Get screen and image dimensions
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local image_w = self._preloaded_image:getWidth()
    local image_h = self._preloaded_image:getHeight()
    
    -- Use the pre-calculated center-locked position instead of simple centering
    local custom_position = self._preloaded_custom_position or {
        x = math.floor(((screen_w - image_w) / 2) + 0.5),
        y = math.floor(((screen_h - image_h) / 2) + 0.5),
    }
    
    logger.info(string.format("PanelZoom: Using preloaded center-locked position - x:%d, y:%d (image:%dx%d, screen:%dx%d)", 
        custom_position.x, custom_position.y, image_w, image_h, screen_w, screen_h))
    
    self._current_imgviewer:updateCustomPosition(custom_position)
    logger.info(string.format("PanelZoom: Updated custom position for preloaded panel - x:%d, y:%d (image:%dx%d, screen:%dx%d)", 
        custom_position.x, custom_position.y, image_w, image_h, screen_w, screen_h))
    
    self._current_imgviewer:update()
    
    -- Clear preloaded data after use
    self._preloaded_image = nil
    self._preloaded_panel_index = nil
    self._preloaded_panel = nil
    self._preloaded_dim = nil
    self._preloaded_custom_position = nil
    
    -- Start preloading the next panel
    UIManager:scheduleIn(0.1, function()
        self:preloadNextPanel()
    end)
    
    return true
end

-- Custom drawPagePart that applies document settings
function PanelZoomIntegration:drawPagePartWithSettings(pageno, rect, panel_center, panel, dim, scale_override)
    -- 1. Document & Screen Settings
    local doc_cfg = self.ui.document.info.config or {}
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    local contrast = doc_cfg.contrast or 1.0
    
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- 2. DEFINE ABSOLUTE LIMIT SAFE ZONE
    local padding = 5
    local safe_w = screen_w - (padding * 2)
    local safe_h = screen_h - (padding * 2)

    -- 3. CALCULATE SCALE (Must fit inside Safe Zone)
    local final_scale = 1.0
    if scale_override then
        final_scale = scale_override
        logger.info(string.format("DynamicPanelZoom: Using override scale %.4f", final_scale))
    else
        local scale_w = safe_w / rect.w
        local scale_h = safe_h / rect.h
        final_scale = math.min(scale_w, scale_h)
    end

    -- Calculate final display dimensions
    local display_w = math.floor(rect.w * final_scale + 0.5)
    local display_h = math.floor(rect.h * final_scale + 0.5)

    -- 4. ORIGINAL CENTERING LOGIC
    -- We calculate the top-left to perfectly center the box on screen
    local pos_x = (screen_w - display_w) / 2
    local pos_y = (screen_h - display_h) / 2

    -- 5. CLAMPING TO ABSOLUTE LIMITS
    -- Forces the panel to stay at least 5px from any edge
    local custom_position = {
        x = math.floor(math.max(padding, math.min(pos_x, screen_w - display_w - padding)) + 0.5),
        y = math.floor(math.max(padding, math.min(pos_y, screen_h - display_h - padding)) + 0.5)
    }

    -- 6. ASPECT RATIO NUDGES (Original offsets)
    if panel and dim then
        local panel_aspect_ratio = (panel.w * dim.w) / (panel.h * dim.h)
        if panel_aspect_ratio >= 0.67 then
            custom_position.x = custom_position.x - 1
        else
            custom_position.y = custom_position.y - 0
        end
    end

    -- 7. RENDER
    -- Create the geometry for MuPDF
    local geom_rect = Geom:new(rect)
    local scaled_rect = geom_rect:copy()
    scaled_rect:transformByScale(final_scale, final_scale)
    rect.scaled_rect = scaled_rect

    local tile = self.ui.document:renderPage(pageno, rect, final_scale, 0, gamma, true)
    local image = tile.bb

    -- 8. POST-PROCESSING
    if image then
        if contrast ~= 1.0 and image.contrast then
            image:contrast(contrast)
        end
        if doc_cfg.invert and image.invert then
            image:invert()
        end
        
        logger.info(string.format("DynamicPanelZoom: [Safe Zone %dpx] Rendered %dx%d at (%d,%d)", 
            padding, display_w, display_h, custom_position.x, custom_position.y))
    end

    return image, false, custom_position
end

-- Apply KOReader's contrast and gamma settings to image buffer
-- This can be used for preloaded images or manual refreshes
function PanelZoomIntegration:applyDocumentSettings(image)
    if not image then return false end
    
    local doc_cfg = self.ui.document.info.config or {}
    local contrast = doc_cfg.contrast or 1.0
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    
    -- Contrast
    if image.contrast and contrast ~= 1.0 then
        image:contrast(contrast)
        logger.info(string.format("DynamicPanelZoom: Applied contrast %.2f", contrast))
    end
    
    -- Gamma (if not handled during renderPage)
    if image.gamma and gamma ~= 1.0 then
        image:gamma(gamma)
        logger.info(string.format("DynamicPanelZoom: Applied gamma %.2f", gamma))
    end
    
    -- Invert
    if image.invert and doc_cfg.invert then
        image:invert()
        logger.info("DynamicPanelZoom: Applied image inversion")
    end
    
    return true
end

-- Clean up preloaded image to prevent memory leaks
function PanelZoomIntegration:cleanupPreloadedImage()
    if self._preloaded_image then
        logger.info("DynamicPanelZoom: Cleaning up preloaded image")
        self._preloaded_image = nil
        self._preloaded_panel_index = nil
        self._preloaded_custom_position = nil
    end
end

function PanelZoomIntegration:changePage(diff)
    -- DO NOT close the current panel viewer immediately. 
    -- Leaving it open keeps the screen covered with the last panel 
    -- while KOReader renders the new full page in the background, 
    -- preventing the "flash of full page" spoiler.

    -- Clear preloaded cache immediately to prevent ghost images
    self:cleanupPreloadedImage()

    -- Save current state for the event-driven flow
    self._is_changing_page = true
    self._page_change_diff = diff

    -- FLASH PREVENTION: Suppress E-Ink screen refreshes while KOReader
    -- renders the new page underneath our PanelViewer.
    -- `currently_scrolling = true` forces all refresh modes to "fast" (no flash).
    UIManager.currently_scrolling = true

    -- Safety net: ensure currently_scrolling is restored even if something
    -- goes wrong. This prevents permanently blocking all E-Ink refreshes.
    UIManager:scheduleIn(1.0, function()
        if UIManager.currently_scrolling then
            logger.warn("DynamicPanelZoom: Safety net restored currently_scrolling to false")
            UIManager.currently_scrolling = false
        end
    end)

    -- Trigger page navigation.
    -- onGotoViewRel is SYNCHRONOUS: it calls _gotoPage() which emits PageUpdate
    -- before returning. Our onPageUpdate handler will detect _is_changing_page
    -- and call _onPageChangeComplete() via nextTick.
    if self.ui.paging and self.ui.paging.onGotoViewRel then
        self.ui.paging:onGotoViewRel(diff)
        logger.info(string.format("DynamicPanelZoom: Used ui.paging.onGotoViewRel(%d)", diff))
    else
        -- Fallback to key event — this path does NOT guarantee a PageUpdate event,
        -- so we handle it directly with nextTick as a safety measure.
        local key = diff > 0 and "Right" or "Left"
        UIManager:sendEvent({ key = key, modifiers = {} })
        logger.info(string.format("DynamicPanelZoom: Used %s key event as fallback", key))
        -- Since key events may not trigger onPageUpdate synchronously,
        -- schedule the completion handler ourselves.
        self:_onPageChangeComplete(nil)
    end
end

-- Handle page change completion. Called by onPageUpdate (event-driven) or
-- directly from changePage() fallback path. Uses nextTick to ensure all
-- other PageUpdate handlers (ReaderView, ReaderZooming, etc.) have finished
-- processing before we load our panel.
function PanelZoomIntegration:_onPageChangeComplete(new_page_no)
    UIManager:nextTick(function()
        -- Restore normal refresh behavior now that we're ready to show our panel
        UIManager.currently_scrolling = false
        -- Prevent the partial->full flash promotion counter from triggering
        UIManager:avoidFlashOnNextRepaint()

        local new_page = new_page_no or self:getSafePageNumber()
        local diff = self._page_change_diff or 1
        logger.info(string.format("DynamicPanelZoom: Page change complete - page %d (diff: %d)", new_page, diff))
        self.last_page_seen = new_page

        self:importToggleZoomPanels()

        if #self.current_panels > 0 then
            -- Moving Forward (diff > 0): Start at first panel of new page.
            -- Moving Backward (diff < 0): Start at last panel of previous page.
            self.current_panel_index = (diff > 0) and 1 or #self.current_panels
            self:displayCurrentPanel()
        else
            UIManager:show(InfoMessage:new{ text = _("No panels on this page"), timeout = 1 })
            self:closeViewer()
        end

        self._is_changing_page = false
        self._page_change_diff = nil
    end)
end

function PanelZoomIntegration:getSafePageNumber()
    -- Try multiple methods to get the current page number
    local page = nil
    
    -- Method 1: Try ui.paging.getPage()
    if self.ui.paging and self.ui.paging.getPage then 
        page = self.ui.paging:getPage()
        logger.info(string.format("PanelZoom: Method 1 - ui.paging.getPage() -> %d", page))
    end
    
    -- Method 2: Try ui.paging.cur_page
    if not page and self.ui.paging and self.ui.paging.cur_page then 
        page = self.ui.paging.cur_page
        logger.info(string.format("PanelZoom: Method 2 - ui.paging.cur_page -> %d", page))
    end
    
    -- Method 3: Try ui.document.current_page
    if not page and self.ui.document and self.ui.document.current_page then 
        page = self.ui.document.current_page
        logger.info(string.format("PanelZoom: Method 3 - ui.document.current_page -> %d", page))
    end
    
    -- Method 4: Try ui.view.state.page
    if not page and self.ui.view and self.ui.view.state and self.ui.view.state.page then 
        page = self.ui.view.state.page
        logger.info(string.format("PanelZoom: Method 4 - ui.view.state.page -> %d", page))
    end
    
    -- Method 5: Try getting from the highlighting system
    if not page and self.ui.highlight and self.ui.highlight.page then 
        page = self.ui.highlight.page
        logger.info(string.format("PanelZoom: Method 5 - ui.highlight.page -> %d", page))
    end
    
    -- Fallback
    if not page then 
        page = 1
        logger.info("PanelZoom: Using fallback page number 1")
    end
    
    return page
end

function PanelZoomIntegration:onIntegratedPanelZoom(arg, ges)
    -- Ensure we have the gesture object
    local actual_ges = (type(arg) == "table" and arg.pos) and arg or ges
    
    -- If JSON is not available, fall back to built-in Panel Zoom
    if not self._json_available then
        logger.info("DynamicPanelZoom: JSON not available, using built-in Panel Zoom")
        if self._original_panel_zoom_handler then
            return self._original_panel_zoom_handler(self.ui.highlight, arg, ges)
        end
        return false
    end
    
    local current_page = self:getSafePageNumber()
    logger.info(string.format("DynamicPanelZoom: onIntegratedPanelZoom called - current_page: %d, last_page_seen: %d, panels_count: %d", 
        current_page, self.last_page_seen or -1, #self.current_panels))
    
    -- Force import if page changed or panels empty
    if current_page ~= self.last_page_seen or #self.current_panels == 0 then
        logger.info(string.format("DynamicPanelZoom: Page changed or no panels - importing for page %d", current_page))
        self.last_page_seen = current_page
        self:importToggleZoomPanels()
    else
        logger.info(string.format("DynamicPanelZoom: Using cached panels for page %d", current_page))
    end

    if #self.current_panels > 0 then
        -- Initial launch of Panel Viewer on a page
        -- In LTR, start at index 1 (top-left). In RTL, start at index 1 (top-right).
        self.current_panel_index = 1
        return self:displayCurrentPanel()
    end

    logger.warn("DynamicPanelZoom: No panels found for this page in JSON.")
    return false
end

function PanelZoomIntegration:importToggleZoomPanels()
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    local page_idx = self:getSafePageNumber()
    local reading_dir = self:getEffectiveReadingDirection()
    
    -- The cache key must now include reading_dir, otherwise flipping direction
    -- uses the old cached layout where panel 1 meant LTR/top-left instead of RTL/top-right.
    if not self._panel_cache[doc_path] then self._panel_cache[doc_path] = {} end
    if not self._panel_cache[doc_path][reading_dir] then self._panel_cache[doc_path][reading_dir] = {} end
    
    -- Check if we already have panels for this page cached in memory FOR THIS READING DIR
    if self._panel_cache[doc_path][reading_dir][page_idx] then
        logger.info(string.format("DynamicPanelZoom: Using cached %s panels for page %d", reading_dir, page_idx))
        self.current_panels = self._panel_cache[doc_path][reading_dir][page_idx]
        return
    end
    
    logger.info(string.format("DynamicPanelZoom: Analyzing page %d for %s panels dynamically", page_idx, reading_dir))
    self.current_panels = self:analyzePageForPanels(page_idx)
    
    -- Cache it for this document and page and direction
    self._panel_cache[doc_path][reading_dir][page_idx] = self.current_panels
    
    if #self.current_panels > 0 then
        logger.info(string.format("DynamicPanelZoom: SUCCESS! Detected %d panels for page %d (%s)", #self.current_panels, page_idx, reading_dir))
    else
        logger.warn(string.format("DynamicPanelZoom: No panels detected on page %d", page_idx))
    end
end

function PanelZoomIntegration:analyzePageForPanels(pageno)
    local ffi = require("ffi")
    local leptonica = ffi.loadlib("leptonica", "6")
    
    if not self.ui.document or not self.ui.document._document then return {} end
    
    -- Re-use or instantiate KOPTContext
    local KOPTContext = require("ffi/koptcontext")
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    
    if not page_size then return {} end
    
    -- Limit the dimensions to avoid OOM or slow processing
    local target_w = page_size.w
    local target_h = page_size.h
    
    local bbox = {
        x0 = 0, y0 = 0,
        x1 = target_w,
        y1 = target_h,
    }
    
    -- We can get the koptinterface from pdfdocument/cbzdocument if needed,
    -- or manually via KoptInterface:createContext
    local Document = require("document/document")
    local koptinterface
    if self.ui.document.koptinterface then
        koptinterface = self.ui.document.koptinterface
    end
    
    local kc
    if koptinterface and koptinterface.createContext then
        kc = koptinterface:createContext(self.ui.document, pageno, bbox)
    else
        -- Fallback: manual creation
        kc = KOPTContext.new()
        kc:setZoom(1.0)
        kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    end
    
    local page = self.ui.document._document:openPage(pageno)
    if not page then 
        if kc.free then kc:free() end
        return {} 
    end
    
    page:getPagePix(kc, self.ui.document.render_mode)
    
    local panels = {}
    
    if kc.src.data then
        local KOPTContextClass = require("ffi/koptcontext")
        local k2pdfopt = KOPTContextClass.k2pdfopt
        
        -- Helper destructors for FFI to avoid memory leaks
        local function _gc_ptr(p, destructor)
            return p and ffi.gc(p, destructor)
        end
        local function pixDestroy(pix)
            leptonica.pixDestroy(ffi.new('PIX *[1]', pix))
            ffi.gc(pix, nil)
        end
        local function boxDestroy(box)
            leptonica.boxDestroy(ffi.new('BOX *[1]', box))
            ffi.gc(box, nil)
        end
        local function boxaDestroy(boxa)
            leptonica.boxaDestroy(ffi.new('BOXA *[1]', boxa))
            ffi.gc(boxa, nil)
        end

        local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, kc.src.width, kc.src.height), pixDestroy)
        
        local pixg
        if leptonica.pixGetDepth(pixs) == 32 then
            pixg = leptonica.pixConvertRGBToGrayFast(pixs)
        else
            pixg = leptonica.pixClone(pixs)
        end
        pixg = _gc_ptr(pixg, pixDestroy)
        
        local pix_inverted = _gc_ptr(leptonica.pixInvert(nil, pixg), pixDestroy)
        local pix_thresholded = _gc_ptr(leptonica.pixThresholdToBinary(pix_inverted, 50), pixDestroy)
        leptonica.pixInvert(pix_thresholded, pix_thresholded)
        
        local bb = _gc_ptr(leptonica.pixConnCompBB(pix_thresholded, 8), boxaDestroy)
        
        local img_w = leptonica.pixGetWidth(pixs)
        local img_h = leptonica.pixGetHeight(pixs)
        
        local function boxGetGeometry(box)
            local geo = ffi.new('l_int32[4]')
            leptonica.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
            return tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])
        end

        local count = leptonica.boxaGetCount(bb)
        for index = 0, count - 1 do
            local box = _gc_ptr(leptonica.boxaGetBox(bb, index, leptonica.L_CLONE), boxDestroy)
            
            local pix_tmp = _gc_ptr(leptonica.pixClipRectangle(pixs, box, nil), pixDestroy)
            local w = leptonica.pixGetWidth(pix_tmp)
            local h = leptonica.pixGetHeight(pix_tmp)
            
            if w >= img_w / 8 and h >= img_h / 8 then
                local box_x, box_y, box_w, box_h = boxGetGeometry(box)
                
                table.insert(panels, {
                    x = box_x / target_w,
                    y = box_y / target_h,
                    w = box_w / target_w,
                    h = box_h / target_h,
                })
            end
            -- Note: Memory is handled automatically by _gc_ptr!
        end
    end
    
    page:close()
    if kc.free then kc:free() end
    
    -- Sort panels based on reading direction (Manga TR->BL)
    local effective_dir = self:getEffectiveReadingDirection()
    table.sort(panels, function(a, b)
        -- We want to sort primarily top-to-bottom, and secondarily according to direction
        -- If their y ranges overlap significantly, they are on the same "row"
        local a_center_y = a.y + (a.h / 2)
        local b_center_y = b.y + (b.h / 2)
        
        -- Rough same-row threshold ~10% of page height
        if math.abs(a_center_y - b_center_y) < 0.1 then
            if effective_dir == "rtl" then
                return a.x > b.x -- Right to Left
            else
                return a.x < b.x -- Left to Right
            end
        end
        
        return a_center_y < b_center_y -- Top to bottom
    end)
    
    return panels
end



function PanelZoomIntegration:calculatePanelCenter(panel, dim)
    -- Calculate absolute center coordinates from panel JSON data
    -- Center_x = x + w/2, Center_y = y + h/2
    local center_x = panel.x + (panel.w / 2)
    local center_y = panel.y + (panel.h / 2)
    
    -- Convert to absolute pixel coordinates
    local abs_center_x = math.floor(center_x * dim.w + 0.5)
    local abs_center_y = math.floor(center_y * dim.h + 0.5)
    
    logger.info(string.format("PanelZoom: Panel center - normalized:(%.3f, %.3f), absolute:(%d, %d)", 
        center_x, center_y, abs_center_x, abs_center_y))
    
    return {
        x = center_x,
        y = center_y,
        abs_x = abs_center_x,
        abs_y = abs_center_y
    }
end

function PanelZoomIntegration:panelToRect(panel, dim, apply_margin_percent)
    -- Step 1: Compute panel center (NO padding involved) - semantic center only
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h
    
    -- Step 2: Build a padded render rect (crop source)
    -- panel rect in page pixels
    local px = panel.x * dim.w
    local py = panel.y * dim.h
    local pw = panel.w * dim.w
    local ph = panel.h * dim.h
    
    local left_extension = 0
    local right_extension = 0
    local top_extension = 0
    local bottom_extension = 0

    if apply_margin_percent and apply_margin_percent > 0 then
        -- Zoom mode (or standard mode with custom margins): Apply constant absolute margin based on page size
        local base_dimension = math.max(dim.w, dim.h)
        local constant_margin = math.floor(base_dimension * apply_margin_percent + 0.5)
        
        left_extension = constant_margin
        right_extension = constant_margin
        top_extension = constant_margin
        bottom_extension = constant_margin
        logger.info(string.format("PanelZoom: Applying constant %.0fpx expanded margins", constant_margin))
    else
        -- Standard Panel Mode: Use default tight constraints
        local panel_aspect_ratio = pw / ph
        
        left_extension = 2   -- Less extension on left side
        right_extension = 2 -- 4px + 5px more extension on right
        top_extension = 0.5
        bottom_extension = 2.5
    end
    
    local render_rect = {
        x = px - left_extension,
        y = py - top_extension,
        w = pw + left_extension + right_extension,
        h = ph + top_extension + bottom_extension,
    }
    
    -- Clamp to page bounds
    render_rect.w = math.min(render_rect.w, dim.w)
    render_rect.h = math.min(render_rect.h, dim.h)
    render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
    render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))

    -- Step 3: Smart Fill (Aspect Ratio Expansion)
    if self.show_adjacent_panels then
        local screen_width = Screen:getWidth()
        local screen_height = Screen:getHeight()
        -- Handle landscape mode if orientation changed
        if self.view and self.view.mode == "landscape" then
            screen_width, screen_height = screen_height, screen_width
        end

        local screen_ratio = screen_width / screen_height
        local rect_ratio = render_rect.w / render_rect.h

        if rect_ratio > screen_ratio then
            -- Panel is wider than screen: Need to expand vertically (height)
            local target_new_h = render_rect.w / screen_ratio
            local total_expansion_needed = target_new_h - render_rect.h
            local expansion_per_side = total_expansion_needed / 2
            
            -- V4: Apply expansion symmetrically WITHOUT clamping to document bounds
            -- This allows render_rect.y to be negative and render_rect.h to exceed dim.h
            render_rect.y = render_rect.y - expansion_per_side
            render_rect.h = render_rect.h + (expansion_per_side * 2)
            
        elseif rect_ratio < screen_ratio then
            -- Panel is taller than screen: Need to expand horizontally (width)
            local target_new_w = render_rect.h * screen_ratio
            local total_expansion_needed = target_new_w - render_rect.w
            local expansion_per_side = total_expansion_needed / 2
            
            -- V4: Apply expansion symmetrically WITHOUT clamping to document bounds
            -- This allows render_rect.x to be negative and render_rect.w to exceed dim.w
            render_rect.x = render_rect.x - expansion_per_side
            render_rect.w = render_rect.w + (expansion_per_side * 2)
        end
    end
    
    logger.info(string.format("PanelZoom: Panel center:(%.1f,%.1f) render_rect:(%d,%d,%dx%d)", 
        panel_cx, panel_cy, render_rect.x, render_rect.y, render_rect.w, render_rect.h))
    
    -- Return render rect and panel center for later calculations
    return {
        x = render_rect.x,
        y = render_rect.y,
        w = render_rect.w,
        h = render_rect.h,
        panel_cx = panel_cx,  -- Semantic center (no padding)
        panel_cy = panel_cy   -- Semantic center (no padding)
    }
end


function PanelZoomIntegration:switchToZoomMode()
    logger.info("DynamicPanelZoom: Switching to Free Zoom Mode")
    
    local panel = self.current_panels[self.current_panel_index]
    if not panel then return false end

    local page = self:getSafePageNumber()
    local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
    if not dim then return false end

    -- 1. Get expanded rect (margin for reading text that spills out)
    local margin = self.zoom_margin_percent or 0.05
    local expanded_rect = self:panelToRect(panel, dim, margin)
    local center = self:calculatePanelCenter(panel, dim)
    
    -- 2. DYNAMIC SCALING (To prevent Segmentation Fault)
    -- We cannot render arbitrary large images on E-Ink memory limits.
    -- We calculate the scale so the image buffer NEVER exceeds screen size + a small buffer
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    
    -- Safe memory rendering constraints
    -- E-ink displays can usually handle a buffer 2.5x to 3x their resolution
    -- before hitting SegFaults, but 1.5x is too blurry for comics text.
    -- We raise this to 2.5x to get crisp text while staying safely below the crash threshold.
    local max_buffer_w = screen_w * 2.5
    local max_buffer_h = screen_h * 2.5
    
    -- Find a safe base scale for the MuPDF render phase
    local scale_w = max_buffer_w / expanded_rect.w
    local scale_h = max_buffer_h / expanded_rect.h
    local safe_scale = math.min(scale_w, scale_h, 3.5) -- Raised the hard render scale cap to 3.5x
    
    logger.info(string.format("DynamicPanelZoom: Using safe memory render scale %.4f", safe_scale))

    -- 3. Generate safe expanded image
    local expanded_image, _, _ = self:drawPagePartWithSettings(page, expanded_rect, center, panel, dim, safe_scale)
    if not expanded_image then return false end

    -- Create native ImageViewer using safe dynamic loading
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok or type(ImageViewer) ~= "table" then
        logger.warn("DynamicPanelZoom: Failed to load imageviewer widget")
        return false
    end
    
    -- 4. APPLY SOFTWARE ZOOM OVER THE SAFE RENDER
    -- To prevent any visual "jump" when switching to 1.0x, we need to match the exact visual scale 
    -- the user was just looking at in the PanelViewer.
    -- First, calculate what the scale was in the normal PanelViewer:
    local standard_margin = self.standard_margin_percent or 0.0
    local normal_rect = self:panelToRect(panel, dim, standard_margin) -- Rect with standard panel margins
    local padding = 5
    local safe_w = screen_w - (padding * 2)
    local safe_h = screen_h - (padding * 2)
    local normal_scale = math.min(safe_w / normal_rect.w, safe_h / normal_rect.h)
    
    -- The absolute scale we want to achieve on the physical screen (1 pixel image = 1 pixel screen at 1.0x)
    local target_absolute_scale = normal_scale / safe_scale
    
    -- IMPORTANT: ImageViewer doesn't treat scale_factor 1.0 as 1:1 pixels.
    -- It treats 1.0 as "Fit to screen" for the given image within its UI context.
    -- When buttons_visible = true, ImageViewer reserves space at the bottom (usually ~10-12% of screen height).
    local image_w = expanded_image:getWidth()
    local image_h = expanded_image:getHeight()
    
    -- Estimate ImageViewer's actual usable viewport (it reserves bottom space for buttons)
    local Size = require("ui/size")
    local button_bar_height = Size.bottom_menu_height or math.floor(screen_h * 0.1)
    local usable_h = screen_h - button_bar_height
    
    local fit_to_screen_scale = math.min(screen_w / image_w, usable_h / image_h)
    
    -- The software scale factor to pass to ImageViewer to achieve our target absolute scale
    -- Fix: ImageViewer uses explicit scale_factor as absolute scale on the image's native resolution, 
    -- not as a multiplier over fit_to_screen. Therefore, we pass target_absolute_scale directly.
    local base_visual_scale = target_absolute_scale
    
    -- Apply the user's zoom preference on top of that base scale
    local bump_factor = self.zoom_initial_scale or 1.2
    local initial_scale_factor = base_visual_scale * bump_factor
    
    logger.info(string.format("DynamicPanelZoom: ImageViewer usable height approx %d (screen %d)", usable_h, screen_h))
    logger.info(string.format("DynamicPanelZoom: ImageViewer Fit-to-screen scale is %.4f", fit_to_screen_scale))
    logger.info(string.format("DynamicPanelZoom: Required Absolute scale is %.4f", target_absolute_scale))
    logger.info(string.format("DynamicPanelZoom: Setting ImageViewer software scale factor to %.4f (bump: %.1fx)", initial_scale_factor, bump_factor))

    local image_viewer = ImageViewer:new{
        image = expanded_image,
        image_disposable = false, -- Disabled forced deletion to prevent garbage collection races/color noise
        fullscreen = true,
        with_title_bar = false,
        buttons_visible = true, -- Restored native UI buttons and minimap
        scale_factor = initial_scale_factor,
        
        -- Calculate the exact semantic center ratio of the panel inside our cropped expanded image
        -- This ensures the ImageViewer starts positioned right over the panel, compensating for asymmetrical margins near page edges.
        _center_x_ratio = (center.abs_x - expanded_rect.x) / expanded_rect.w,
        _center_y_ratio = (center.abs_y - expanded_rect.y) / expanded_rect.h,
    }

    -- We just push the image_viewer on top of the UI stack. 
    -- The PanelViewer stays underneath. When image_viewer is closed, PanelViewer is instantly revealed without flashing the background page.
    UIManager:show(image_viewer)
    return true
end

function PanelZoomIntegration:displayCurrentPanel()
    logger.info("DynamicPanelZoom: displayCurrentPanel called")
    local panel = self.current_panels[self.current_panel_index]
    if not panel then 
        logger.warn("DynamicPanelZoom: No panel data found for index " .. self.current_panel_index)
        return false 
    end

    local page = self:getSafePageNumber()
    
    -- Get dimensions from document for consistent coordinate space
    local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
    if not dim then 
        logger.warn("DynamicPanelZoom: Could not get page dimensions")
        return false 
    end
    logger.info(string.format("DynamicPanelZoom: Using document dimensions - w:%d, h:%d", dim.w, dim.h))

    -- Use helper function for center-preserving quantization with dynamic frame
    local margin = self.standard_margin_percent or 0.0
    local rect = self:panelToRect(panel, dim, margin)
    
    -- Calculate and log panel center coordinates
    local center = self:calculatePanelCenter(panel, dim)
    
    logger.info(string.format("DynamicPanelZoom: Panel rect - x:%d, y:%d, w:%d, h:%d", rect.x, rect.y, rect.w, rect.h))
    
    -- Create new image for the panel with document settings
    local image, rotate, custom_position = self:drawPagePartWithSettings(page, rect, center, panel, dim)
    if not image then 
        logger.warn("DynamicPanelZoom: Could not draw page part")
        return false 
    end
    
    logger.info("DynamicPanelZoom: Successfully created panel image with document settings")

    -- Calculate panel aspect ratio for border logic
    local panel_aspect_ratio = nil
    if panel and dim then
        local panel_w = panel.w * dim.w
        local panel_h = panel.h * dim.h
        panel_aspect_ratio = panel_w / panel_h
        logger.info(string.format("DynamicPanelZoom: Panel aspect ratio: %.3f", panel_aspect_ratio))
    end

    -- Reuse existing viewer if available instead of closing to prevent flash of full page
    if self._current_imgviewer then 
        logger.info("DynamicPanelZoom: Updating existing PanelViewer")
        self._current_imgviewer:updateReadingDirection(self:getEffectiveReadingDirection())
        self._current_imgviewer:updateCustomPosition(custom_position)
        self._current_imgviewer:updatePanelAspectRatio(panel_aspect_ratio)
        self._current_imgviewer:updateImage(image)
        self._current_imgviewer:update()
        
        -- Start preloading the next panel after a short delay
        UIManager:scheduleIn(0.2, function()
            self:preloadNextPanel()
        end)
        return true
    end
    
    -- Create new PanelViewer instance with our custom implementation
    logger.info("DynamicPanelZoom: Creating new PanelViewer instance")
    local panel_viewer = PanelViewer:new{
        image = image,
        fullscreen = true,
        buttons_visible = false,
        reading_direction = self:getEffectiveReadingDirection(),
        custom_position = custom_position,  -- Pass custom position for center matching
        panel_aspect_ratio = panel_aspect_ratio,  -- Pass panel aspect ratio for border logic
        onTapRight = function() self:handleTapRight() end,
        onTapLeft = function() self:handleTapLeft() end,
        onClose = function() 
            self:closeViewer()
            -- Restore OCR when panel viewer is closed
            self:restoreOCR()
        end,
        onHold = function()
            self:switchToZoomMode()
        end,
    }
    
    self._current_imgviewer = panel_viewer
    logger.info("DynamicPanelZoom: Showing new PanelViewer")
    UIManager:show(panel_viewer)
    
    -- Use "ui" refresh for initial panel display to avoid E-Ink flash.
    -- "flashui" would cause a visible full-screen flash on E-Ink devices.
    -- Dithering is still enabled for image quality on grayscale E-Ink displays.
    UIManager:setDirty(panel_viewer, function()
        return "ui", panel_viewer.dimen, Screen.sw_dithering  -- Enable dithering for E-ink
    end)
    
    logger.info("DynamicPanelZoom: New PanelViewer shown with flash-free refresh")
    
    -- Start preloading the next panel after a short delay
    UIManager:scheduleIn(0.2, function()
        self:preloadNextPanel()
    end)
    
    return true -- Success, new viewer created
end

-- Integrate reading direction options into existing panel zoom menu
function PanelZoomIntegration:setupPanelZoomMenuIntegration()
    -- Store original genPanelZoomMenu function
    if not self._original_genPanelZoomMenu and self.ui.highlight and self.ui.highlight.genPanelZoomMenu then
        self._original_genPanelZoomMenu = self.ui.highlight.genPanelZoomMenu
        
        -- Override genPanelZoomMenu to include our reading direction options
        self.ui.highlight.genPanelZoomMenu = function()
            local menu_items = self._original_genPanelZoomMenu(self.ui.highlight)
            
            -- Add reading direction submenu at the beginning
            table.insert(menu_items, 1, {
                text = _("Reading direction"),
                sub_item_table = {
                    {
                        text = _("Left-to-Right (LTR)"),
                        checked_func = function()
                            return self.reading_direction_override == "ltr" or self.reading_direction_override == nil
                        end,
                        callback = function()
                            self.reading_direction_override = "ltr"
                            logger.info("DynamicPanelZoom: Reading direction override set to LTR")
                            -- Clear all caches globally so next panel invocation re-sorts
                            self._panel_cache = {}
                            self.current_panels = {}
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                    {
                        text = _("Right-to-Left (RTL)"),
                        checked_func = function()
                            return self.reading_direction_override == "rtl"
                        end,
                        callback = function()
                            self.reading_direction_override = "rtl"
                            logger.info("DynamicPanelZoom: Reading direction override set to RTL")
                            -- Clear all caches globally so next panel invocation re-sorts
                            self._panel_cache = {}
                            self.current_panels = {}
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                },
                separator = true,
            })

            -- Add Standard Panel options
            table.insert(menu_items, 2, {
                text = _("Standard panel settings"),
                sub_item_table = {
                    {
                        text = _("Show adjacent page content"),
                        checked_func = function() return self.show_adjacent_panels end,
                        callback = function()
                            self.show_adjacent_panels = not self.show_adjacent_panels
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                    {
                        text = _("Padding around panel"),
                        sub_item_table = {
                            {
                                text = _("0% (None)"),
                                checked_func = function() return self.standard_margin_percent == 0.0 end,
                                callback = function() self.standard_margin_percent = 0.0 end,
                            },
                            {
                                text = _("2% (Tight)"),
                                checked_func = function() return self.standard_margin_percent == 0.02 end,
                                callback = function() self.standard_margin_percent = 0.02 end,
                            },
                            {
                                text = _("5% (Normal)"),
                                checked_func = function() return self.standard_margin_percent == 0.05 end,
                                callback = function() self.standard_margin_percent = 0.05 end,
                            },
                            {
                                text = _("10% (Wide)"),
                                checked_func = function() return self.standard_margin_percent == 0.10 end,
                                callback = function() self.standard_margin_percent = 0.10 end,
                            },
                        }
                    }
                },
                separator = true,
            })
            
            -- Add Free Zoom options
            table.insert(menu_items, 3, {
                text = _("Hold-to-Zoom settings"),
                sub_item_table = {
                    {
                        text = _("Hold-to-Zoom padding"),
                        sub_item_table = {
                            {
                                text = _("2% (Tight)"),
                                checked_func = function() return self.zoom_margin_percent == 0.02 end,
                                callback = function() self.zoom_margin_percent = 0.02 end,
                            },
                            {
                                text = _("5% (Normal)"),
                                checked_func = function() return self.zoom_margin_percent == 0.05 end,
                                callback = function() self.zoom_margin_percent = 0.05 end,
                            },
                            {
                                text = _("10% (Wide)"),
                                checked_func = function() return self.zoom_margin_percent == 0.10 end,
                                callback = function() self.zoom_margin_percent = 0.10 end,
                            },
                            {
                                text = _("20% (Context)"),
                                checked_func = function() return self.zoom_margin_percent == 0.20 end,
                                callback = function() self.zoom_margin_percent = 0.20 end,
                            },
                        }
                    },
                    {
                        text = _("Initial zoom level"),
                        sub_item_table = {
                            {
                                text = _("Fit to screen (1.0x)"),
                                checked_func = function() return self.zoom_initial_scale == 1.0 end,
                                callback = function() self.zoom_initial_scale = 1.0 end,
                            },
                            {
                                text = _("Slight Zoom (1.2x)"),
                                checked_func = function() return self.zoom_initial_scale == 1.2 end,
                                callback = function() self.zoom_initial_scale = 1.2 end,
                            },
                            {
                                text = _("Medium Zoom (1.5x)"),
                                checked_func = function() return self.zoom_initial_scale == 1.5 end,
                                callback = function() self.zoom_initial_scale = 1.5 end,
                            },
                            {
                                text = _("Heavy Zoom (2.0x)"),
                                checked_func = function() return self.zoom_initial_scale == 2.0 end,
                                callback = function() self.zoom_initial_scale = 2.0 end,
                            },
                        }
                    },
                },
                separator = true,
            })
            
            return menu_items
        end
        
        logger.info("DynamicPanelZoom: Integrated reading direction options into panel zoom menu")
    end
end

-- Restore original panel zoom menu when plugin is disabled
function PanelZoomIntegration:restorePanelZoomMenu()
    -- Guard against multiple restoration calls
    if not self._original_genPanelZoomMenu then
        return -- Already restored or never stored
    end
    
    if self._original_genPanelZoomMenu and self.ui.highlight then
        self.ui.highlight.genPanelZoomMenu = self._original_genPanelZoomMenu
        self._original_genPanelZoomMenu = nil
        logger.info("DynamicPanelZoom: Restored original panel zoom menu")
    end
end

-- Refresh current panel if viewer is active (for reading direction changes)
function PanelZoomIntegration:refreshCurrentPanelIfActive()
    if self._current_imgviewer and self.integration_mode and #self.current_panels > 0 then
        logger.info("DynamicPanelZoom: Refreshing panel viewer with new reading direction")
        
        -- To ensure correct spatial flow, we must re-sort the panels
        -- by the new reading direction and map the current panel to its new index
        local old_panel = self.current_panels[self.current_panel_index]
        
        -- Import will automatically use the NEW reading direction and 
        -- either generate a new layout or pull it from the direction-specific cache.
        self:importToggleZoomPanels()
        
        -- Find the old panel in the newly sorted array so we stay on the same physical panel
        if old_panel and #self.current_panels > 0 then
            for i, p in ipairs(self.current_panels) do
                -- Compare coordinates (allowing tiny float variations)
                if math.abs(p.x - old_panel.x) < 0.001 and math.abs(p.y - old_panel.y) < 0.001 then
                    self.current_panel_index = i
                    break
                end
            end
        end
        
        -- Propagate reading direction immediately
        if self._current_imgviewer.updateReadingDirection then
            self._current_imgviewer:updateReadingDirection(self:getEffectiveReadingDirection())
        end
        self:displayCurrentPanel()
    end
end

-- Helper function: Calculate position to move panel center exactly to screen center
function PanelZoomIntegration:panelCenterToScreenPosition(panel, rect, dim, zoom)
    if not panel or not rect or not dim or not zoom then
        logger.warn("DynamicPanelZoom: Invalid parameters in panelCenterToScreenPosition")
        -- Fallback to screen center
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        return {
            x = math.floor(screen_w / 2),
            y = math.floor(screen_h / 2),
        }
    end
    
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Absolute panel center (page space) from normalized JSON coordinates
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h

    -- Center inside rect (page space)
    local cx_in_rect = panel_cx - rect.x
    local cy_in_rect = panel_cy - rect.y

    -- Scaled center (screen space)
    local cx_screen = cx_in_rect * zoom
    local cy_screen = cy_in_rect * zoom

    -- Translation to move center to screen center
    return {
        x = math.floor(screen_w / 2 - cx_screen + 0.5),
        y = math.floor(screen_h / 2 - cy_screen + 0.5),
    }
end

return PanelZoomIntegration

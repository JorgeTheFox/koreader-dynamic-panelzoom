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
    name = "panelzoom_integration",
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
    _original_panel_zoom_handler = nil, -- Store original panel zoom handler
    _original_ocr_handler = nil, -- Store original OCR handler
    _original_ocr_menu_enabled = nil, -- Store original OCR menu state
    _original_genPanelZoomMenu = nil, -- Store original panel zoom menu function
    _json_available = false, -- Track if JSON is available for current document
    reading_direction_override = nil, -- User override for reading direction (rtl/ltr)
    horizontal_offset = 0,
    full_refresh = true, -- Flashing full refresh to avoid ghosting (user-toggleable)
    show_full_page_first = true, -- Show the whole page (step 0) before its panels
}

function PanelZoomIntegration:init()
    -- Load persisted refresh preference (default: enabled)
    if G_reader_settings then
        self.full_refresh = G_reader_settings:nilOrTrue("panelzoom_full_refresh")
        self.show_full_page_first = G_reader_settings:nilOrTrue("panelzoom_full_page_first")
    end

    -- Auto-detect JSON and integrate with Panel Zoom when document is opened
    self.onDocumentLoaded = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Auto-refresh JSON detection when page changes
    self.onPageUpdate = function()
        -- Always re-check JSON availability on page changes
        -- This ensures detection if JSON files are added/removed during reading
        self:checkAndIntegratePanelZoom()
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
    if self.reading_direction_override then
        return self.reading_direction_override
    end
    return self.reading_direction or "ltr"
end

-- Check if JSON is available and integrate with Panel Zoom automatically
function PanelZoomIntegration:checkAndIntegratePanelZoom()
    if not self.ui.document then return end
    
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    -- Extract directory and base name
    local dir, filename = util.splitFilePathName(doc_path)
    local base_name = filename:match("(.+)%..+$") or filename
    
    -- Check for JSON file in same directory as document
    local json_path = dir .. "/" .. base_name .. ".json"
    local json_found = util.pathExists(json_path)
    
    if json_found then
        logger.info("PanelZoom: Found JSON file at " .. json_path)
    end
    
    if json_found then
        self._json_available = true
        self:integrateWithPanelZoom()
        logger.info("PanelZoom: Auto-integration enabled - JSON available")
    else
        self._json_available = false
        self:restoreOriginalPanelZoom()
        logger.info("PanelZoom: Using built-in Panel Zoom - no JSON found")
    end
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
            logger.info("PanelZoom: OCR blocked - Panel Zoom integration is active")
            return false
        end
        logger.info("PanelZoom: OCR functionality blocked")
    end
    
    -- Also disable OCR menu items if available
    if self.ui.menu and self.ui.menu.ocr_menu then
        self._original_ocr_menu_enabled = self.ui.menu.ocr_menu.enabled
        self.ui.menu.ocr_menu.enabled = false
        logger.info("PanelZoom: OCR menu items disabled")
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
        logger.info("PanelZoom: OCR functionality restored")
    end
    
    -- Restore OCR menu items
    if self.ui.menu and self.ui.menu.ocr_menu and self._original_ocr_menu_enabled ~= nil then
        self.ui.menu.ocr_menu.enabled = self._original_ocr_menu_enabled
        self._original_ocr_menu_enabled = nil
        logger.info("PanelZoom: OCR menu items restored")
    end
end

-- Callback methods for PanelViewer
function PanelZoomIntegration:nextPanel()
    if self._is_switching then return end -- Block if already processing
    self._is_switching = true
    
    -- Reset the flag after the UI has had a chance to breathe
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    -- Check if we have preloaded the next panel
    if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
        -- Use preloaded image for instant switch
        logger.info("PanelZoom: Using preloaded panel for instant switch")
        self.current_panel_index = self.current_panel_index + 1
        self:displayPreloadedPanel()
        return
    end
    
    if self.current_panel_index < #self.current_panels then
        self.current_panel_index = self.current_panel_index + 1
        self:displayCurrentPanel()
    else
        -- Last panel reached, jump to next page
        logger.info("PanelZoom: Last panel reached, jumping to next page")
        self:changePage(1) 
    end
end

function PanelZoomIntegration:prevPanel()
    if self._is_switching then return end -- Block if already processing
    self._is_switching = true
    
    -- Reset the flag after the UI has had a chance to breathe
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    if self.current_panel_index > 1 then
        self.current_panel_index = self.current_panel_index - 1
        self:displayCurrentPanel()
    elseif self.current_panel_index == 1 and self.show_full_page_first then
        -- Step back to the whole-page view before leaving the page
        self.current_panel_index = 0
        self:displayCurrentPanel()
    else
        -- First panel reached, jump to previous page
        logger.info("PanelZoom: First panel reached, jumping to previous page")
        self:changePage(-1)
    end
end

function PanelZoomIntegration:closeViewer()
    if self._current_imgviewer then
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
    
    -- Check if there's a next panel to preload
    if self.current_panel_index < #self.current_panels then
        local next_panel_index = self.current_panel_index + 1
        local next_panel = self.current_panels[next_panel_index]
        
        if next_panel then
            logger.info(string.format("PanelZoom: Preloading panel %d in background", next_panel_index))
            
            local page = self:getSafePageNumber()
            local dim = self.ui.document:getNativePageDimensions(page)
            
            if dim then
                -- Calculate and log panel center coordinates for preloaded panel
                local center = self:calculatePanelCenter(next_panel, dim)
                
                -- Use helper function for center-preserving quantization
                local rect = self:panelToRect(next_panel, dim)
                
                -- Render the next panel with document settings
                local image, rotate, custom_position = self:drawPagePartWithSettings(page, rect, center, next_panel, dim)
                -- Store preloaded image with panel data for proper centering
                if image then
                    self._preloaded_image = image
                    self._preloaded_panel_index = next_panel_index
                    self._preloaded_panel = next_panel  -- Store panel data
                    self._preloaded_dim = dim          -- Store dimensions
                    self._preloaded_custom_position = custom_position  -- Store calculated position
                    logger.info("PanelZoom: Successfully preloaded next panel with document settings")
                else
                    logger.warn("PanelZoom: Failed to preload next panel")
                end
            end
        end
    end
end

-- Display preloaded panel instantly
function PanelZoomIntegration:displayPreloadedPanel()
    if not self._preloaded_image or not self._current_imgviewer then
        logger.warn("PanelZoom: No preloaded image or viewer available")
        return false
    end
    
    logger.info("PanelZoom: Displaying preloaded panel instantly")
    
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
    
    -- Full flashing refresh on panel switch: a partial "ui" refresh leaves the
    -- previous panel ghosted behind the new one on E-ink. User can disable it.
    self._current_imgviewer:update(self.full_refresh and "flashui" or "ui")

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
function PanelZoomIntegration:drawPagePartWithSettings(pageno, rect, panel_center, panel, dim)
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
    local scale_w = safe_w / rect.w
    local scale_h = safe_h / rect.h
    local final_scale = math.min(scale_w, scale_h)

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
    -- 5b. APPLY HORIZONTAL OFFSET
custom_position.x = custom_position.x + (self.horizontal_offset or -2)
-- Optional: clamp to screen bounds

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

    -- KOReader v2026.07 inserted a `saturation` arg before `hinting`:
    -- renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting).
    -- Pass 1.0 (neutral) for saturation, matching Document:drawPagePart.
    local tile = self.ui.document:renderPage(pageno, rect, final_scale, 0, gamma, 1.0, true)
    local image = tile.bb

    -- 8. POST-PROCESSING
    if image then
        if contrast ~= 1.0 and image.contrast then
            image:contrast(contrast)
        end
        if doc_cfg.invert and image.invert then
            image:invert()
        end
        
        logger.info(string.format("PanelZoom: [Safe Zone %dpx] Rendered %dx%d at (%d,%d)", 
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
        logger.info(string.format("PanelZoom: Applied contrast %.2f", contrast))
    end
    
    -- Gamma (if not handled during renderPage)
    if image.gamma and gamma ~= 1.0 then
        image:gamma(gamma)
        logger.info(string.format("PanelZoom: Applied gamma %.2f", gamma))
    end
    
    -- Invert
    if image.invert and doc_cfg.invert then
        image:invert()
        logger.info("PanelZoom: Applied image inversion")
    end
    
    return true
end

-- Clean up preloaded image to prevent memory leaks
function PanelZoomIntegration:cleanupPreloadedImage()
    if self._preloaded_image then
        logger.info("PanelZoom: Cleaning up preloaded image")
        self._preloaded_image = nil
        self._preloaded_panel_index = nil
        self._preloaded_custom_position = nil
    end
end

function PanelZoomIntegration:changePage(diff)
    -- 1. Use KOReader's built-in page navigation method
    if self.ui.paging and self.ui.paging.onGotoViewRel then
        self.ui.paging:onGotoViewRel(diff)
        logger.info(string.format("PanelZoom: Used ui.paging.onGotoViewRel(%d)", diff))
    else
        -- Fallback to key event
        local key = diff > 0 and "Right" or "Left"
        UIManager:sendEvent({ key = key, modifiers = {} })
        logger.info(string.format("PanelZoom: Used %s key event as fallback", key))
    end
        
    -- 2. Wait for the engine to render the new page, then update viewer content
    UIManager:scheduleIn(0.3, function()
        local new_page = self:getSafePageNumber()
        logger.info(string.format("PanelZoom: Changed to page %d (diff: %d)", new_page, diff))
        self.last_page_seen = new_page
        
        -- Clear preloaded cache after page is fully loaded to prevent conflicts
        self:cleanupPreloadedImage()
        
        self:importToggleZoomPanels()
        
        if #self.current_panels > 0 then
            -- If going forward, start at panel 1. If going backward, start at last panel.
            -- Going forward: whole page first (step 0) when enabled, otherwise panel 1.
            -- Going backward: start at the last panel.
            if diff > 0 then
                self.current_panel_index = self.show_full_page_first and 0 or 1
            else
                self.current_panel_index = #self.current_panels
            end
            -- Just update the current viewer instead of closing/reopening
            self:displayCurrentPanel()
        else
            -- No panels on this page, close viewer
            if self._current_imgviewer then
                UIManager:close(self._current_imgviewer)
                self._current_imgviewer = nil
            end
            UIManager:show(InfoMessage:new{ text = _("No panels on this page"), timeout = 1 })
        end
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
        logger.info("PanelZoom: JSON not available, using built-in Panel Zoom")
        if self._original_panel_zoom_handler then
            return self._original_panel_zoom_handler(self.ui.highlight, arg, ges)
        end
        return false
    end
    
    local current_page = self:getSafePageNumber()
    logger.info(string.format("PanelZoom: onIntegratedPanelZoom called - current_page: %d, last_page_seen: %d, panels_count: %d", 
        current_page, self.last_page_seen or -1, #self.current_panels))
    
    -- Force import if page changed or panels empty
    if current_page ~= self.last_page_seen or #self.current_panels == 0 then
        logger.info(string.format("PanelZoom: Page changed or no panels - importing for page %d", current_page))
        self.last_page_seen = current_page
        self:importToggleZoomPanels()
    else
        logger.info(string.format("PanelZoom: Using cached panels for page %d", current_page))
    end

    if #self.current_panels > 0 then
        self.current_panel_index = 1
        return self:displayCurrentPanel()
    end

    logger.warn("PanelZoom: No panels found for this page in JSON.")
    return false
end

function PanelZoomIntegration:importToggleZoomPanels()
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    -- Extract directory and base name early for use in cache check
    local dir, filename = util.splitFilePathName(doc_path)
    local base_name = filename:match("(.+)%..+$") or filename
    
    -- Check cache first
    if self._panel_cache[doc_path] then
        logger.info("PanelZoom: Using cached JSON for " .. doc_path)
        local cached_data = self._panel_cache[doc_path]
        self.reading_direction = cached_data.reading_direction or "ltr"
        
        -- Check if this is a chapter-based master index in cache
        if cached_data.chapters and type(cached_data.chapters) == "table" and #cached_data.chapters > 0 then
            logger.info("PanelZoom: Using cached chapter-based archive structure")
            return self:loadChapterBasedPanels(cached_data, dir, base_name)
        end
        
        local page_idx = self:getSafePageNumber()
        local panels = nil
        
        -- Find panels for current page from cached data
        if cached_data.pages and type(cached_data.pages) == "table" and #cached_data.pages > 0 then
            for _, page_data in ipairs(cached_data.pages) do
                if page_data.page == page_idx then
                    panels = page_data.panels
                    logger.info(string.format("PanelZoom: Found page %d in cached data", page_idx))
                    break
                end
            end
        end
        
        if panels and #panels > 0 then
            self.current_panels = panels
            logger.info(string.format("PanelZoom: SUCCESS! Loaded %d panels from cache for page %d", #panels, page_idx))
        else
            self.current_panels = {}
            logger.warn(string.format("PanelZoom: Cache found, but no panels match page %d", page_idx))
        end
        return
    end
    
    -- Not in cache, load from file
    local json_path = dir .. "/" .. base_name .. ".json"
    
    local f = io.open(json_path, "r")
    if not f then 
        logger.warn("PanelZoom: JSON not found at " .. json_path)
        return 
    end
    
    local content = f:read("*all")
    f:close()
    
    local ok, data = pcall(json.decode, content)
    if not ok or not data then return end

    -- Check if this is a chapter-based master index
    if data.chapters and type(data.chapters) == "table" and #data.chapters > 0 then
        logger.info("PanelZoom: Detected chapter-based archive structure")
        return self:loadChapterBasedPanels(data, dir, base_name)
    end

    -- Cache the parsed JSON
    self._panel_cache[doc_path] = data
    logger.info("PanelZoom: Cached JSON for " .. doc_path)

    -- Save the reading direction for the Tap handler
    self.reading_direction = data.reading_direction or "ltr"
    logger.info(string.format("PanelZoom: Reading direction set to %s", self.reading_direction))

    local page_idx = self:getSafePageNumber()
    local panels = nil

    -- Handle array-based JSON structure: pages is an array of objects
    if data.pages and type(data.pages) == "table" and #data.pages > 0 then
        -- Iterate through the pages array to find matching page number
        for _, page_data in ipairs(data.pages) do
            if page_data.page == page_idx then
                panels = page_data.panels
                logger.info(string.format("PanelZoom: Found page %d in array structure", page_idx))
                break
            end
        end
    end
    
    -- Fallback: Try dictionary-style access (for backward compatibility)
    if not panels and data.pages then
        -- 1. Try filename (e.g. "page001.jpg")
        -- 2. Try page index as string ("1")
        -- 3. Try page index as number (1)
        panels = data.pages[filename] or data.pages[tostring(page_idx)] or data.pages[page_idx]
    end
    
    -- Final fallback: if JSON has a top-level 'panels' array
    if not panels and data.panels then panels = data.panels end

    if panels and #panels > 0 then
        self.current_panels = panels
        logger.info(string.format("PanelZoom: SUCCESS! Loaded %d panels for page %d", #panels, page_idx))
    else
        self.current_panels = {}
        logger.warn(string.format("PanelZoom: JSON found, but no panels match page %d or filename %s", page_idx, filename))
    end
end

function PanelZoomIntegration:loadChapterBasedPanels(master_data, dir, base_name)
    logger.info("PanelZoom: Loading chapter-based panels")
    
    -- Cache the master data
    local doc_path = self.ui.document.file
    self._panel_cache[doc_path] = master_data
    
    -- Save the reading direction
    self.reading_direction = master_data.reading_direction or "ltr"
    logger.info(string.format("PanelZoom: Reading direction set to %s", self.reading_direction))
    
    local page_idx = self:getSafePageNumber()
    local current_page_in_chapter = page_idx
    local cumulative_pages = 0
    
    -- Find which chapter contains the current page
    local target_chapter = nil
    for _, chapter in ipairs(master_data.chapters) do
        if current_page_in_chapter <= chapter.total_pages then
            target_chapter = chapter
            break
        else
            current_page_in_chapter = current_page_in_chapter - chapter.total_pages
        end
    end
    
    if not target_chapter then
        logger.warn(string.format("PanelZoom: Could not find chapter for page %d", page_idx))
        self.current_panels = {}
        return
    end
    
    logger.info(string.format("PanelZoom: Found chapter %s for page %d (page %d in chapter)", 
        target_chapter.name, page_idx, current_page_in_chapter))
    
    -- Load the chapter JSON file
    local chapter_json_path = dir .. "/" .. target_chapter.json_file
    local chapter_file = io.open(chapter_json_path, "r")
    if not chapter_file then 
        logger.warn("PanelZoom: Chapter JSON not found at " .. chapter_json_path)
        self.current_panels = {}
        return 
    end
    
    local chapter_content = chapter_file:read("*all")
    chapter_file:close()
    
    local ok, chapter_data = pcall(json.decode, chapter_content)
    if not ok or not chapter_data then 
        logger.warn("PanelZoom: Failed to parse chapter JSON")
        self.current_panels = {}
        return 
    end
    
    -- Find panels for the current page within the chapter
    local panels = nil
    if chapter_data.pages and type(chapter_data.pages) == "table" and #chapter_data.pages > 0 then
        for _, page_data in ipairs(chapter_data.pages) do
            if page_data.page == current_page_in_chapter then
                panels = page_data.panels
                logger.info(string.format("PanelZoom: Found page %d in chapter %s", current_page_in_chapter, target_chapter.name))
                break
            end
        end
    end
    
    if panels and #panels > 0 then
        self.current_panels = panels
        logger.info(string.format("PanelZoom: SUCCESS! Loaded %d panels for page %d from chapter %s", 
            #panels, page_idx, target_chapter.name))
    else
        self.current_panels = {}
        logger.warn(string.format("PanelZoom: Chapter JSON found, but no panels match page %d in chapter %s", 
            current_page_in_chapter, target_chapter.name))
    end
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

function PanelZoomIntegration:panelToRect(panel, dim)
    -- Step 1: Compute panel center (NO padding involved) - semantic center only
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h
    
    -- Step 2: Build a padded render rect (crop source)
    -- panel rect in page pixels
    local px = panel.x * dim.w
    local py = panel.y * dim.h
    local pw = panel.w * dim.w
    local ph = panel.h * dim.h
    
    -- Calculate padding based on aspect ratio
    local padding_left = 0
    local padding_right = 0
    local padding_top = 0
    local padding_bottom = 0
    local padding_x = 0
    local padding_y = 0
    
    local panel_aspect_ratio = pw / ph
    
    if panel_aspect_ratio > 1.5 then
        -- Wide horizontal panels (action scenes, landscapes)
        padding_left = dim.w * 0.007
        padding_right = dim.w * 0.006
        padding_y = dim.h * 0.004
    elseif panel_aspect_ratio < 0.67 then
        -- Tall vertical panels (character focus, falling scenes)
        padding_x = dim.w * 0.004
        padding_top = dim.h * 0.001
        padding_bottom = dim.h * 0.002
    else
        -- Square/standard panels (dialogue, exposition)
        padding_x = dim.w * 0.005
        padding_top = dim.h * 0.0015
        padding_bottom = dim.h * 0.003
    end
    
    -- Build render rect with left extension (more area on left side, less on right)
    local left_extension = 2   -- Less extension on left side
    local right_extension = 2 -- 4px + 5px more extension on right
    local top_extension = 0.5
    local bottom_extension = 2.5
    
    local render_rect = {
        x = px - left_extension,      -- Less cropping on left
        y = py - top_extension,       -- Extend on top
        w = pw + left_extension + right_extension,
        h = ph + top_extension + bottom_extension,
    }
    
    -- Clamp to page bounds
    render_rect.w = math.min(render_rect.w, dim.w)
    render_rect.h = math.min(render_rect.h, dim.h)
    render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
    render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))
    
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


-- Index 0 is the whole page ("overview"); 1..n are the panels from the JSON.
function PanelZoomIntegration:getPanelAt(index)
    if index == 0 then
        return { x = 0, y = 0, w = 1, h = 1, _overview = true }
    end
    return self.current_panels[index]
end

function PanelZoomIntegration:displayCurrentPanel()
    logger.info("PanelZoom: displayCurrentPanel called")
    local panel = self:getPanelAt(self.current_panel_index)
    if not panel then 
        logger.warn("PanelZoom: No panel data found for index " .. self.current_panel_index)
        return false 
    end

    local page = self:getSafePageNumber()
    
    -- Get dimensions from document for consistent coordinate space
    local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
    if not dim then 
        logger.warn("PanelZoom: Could not get page dimensions")
        return false 
    end
    logger.info(string.format("PanelZoom: Using document dimensions - w:%d, h:%d", dim.w, dim.h))

    -- Use helper function for center-preserving quantization with dynamic frame
    local rect
    if panel._overview then
        -- Whole page, fitted to the screen with no panel padding tweaks
        rect = { x = 0, y = 0, w = dim.w, h = dim.h }
    else
        rect = self:panelToRect(panel, dim)
    end
    
    -- Calculate and log panel center coordinates
    local center = self:calculatePanelCenter(panel, dim)
    
    logger.info(string.format("PanelZoom: Panel rect - x:%d, y:%d, w:%d, h:%d", rect.x, rect.y, rect.w, rect.h))
    
    -- Create new image for the panel with document settings
    local image, rotate, custom_position = self:drawPagePartWithSettings(page, rect, center, panel, dim)
    if not image then 
        logger.warn("PanelZoom: Could not draw page part")
        return false 
    end
    
    logger.info("PanelZoom: Successfully created panel image with document settings")

    -- Calculate panel aspect ratio for border logic
    local panel_aspect_ratio = nil
    if panel and dim then
        local panel_w = panel.w * dim.w
        local panel_h = panel.h * dim.h
        panel_aspect_ratio = panel_w / panel_h
        logger.info(string.format("PanelZoom: Panel aspect ratio: %.3f", panel_aspect_ratio))
    end

    -- Close previous viewer BEFORE creating new image to avoid memory issues
    if self._current_imgviewer then 
        logger.info("PanelZoom: Closing previous PanelViewer")
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
    end
    
    -- Create new PanelViewer instance with our custom implementation
    logger.info("PanelZoom: Creating new PanelViewer instance")
    local panel_viewer = PanelViewer:new{
        image = image,
        fullscreen = true,
        buttons_visible = false,
        reading_direction = self:getEffectiveReadingDirection(),
        full_refresh = self.full_refresh,  -- Ghosting-avoidance refresh preference
        custom_position = custom_position,  -- Pass custom position for center matching
        panel_aspect_ratio = panel_aspect_ratio,  -- Pass panel aspect ratio for border logic
        onNext = function() self:nextPanel() end,
        onPrev = function() self:prevPanel() end,
        onClose = function() 
            self:closeViewer()
            -- Restore OCR when panel viewer is closed
            self:restoreOCR()
        end,
    }
    
    self._current_imgviewer = panel_viewer
    logger.info("PanelZoom: Showing new PanelViewer")
    UIManager:show(panel_viewer)
    
    -- KOADER MUFPDF LOGIC: Use flashui refresh for initial panel display
    -- This ensures crisp rendering like KOReader's ImageViewer
    -- Enable dithering for E-ink displays to prevent artifacts
    local initial_refresh = self.full_refresh and "flashui" or "ui"
    UIManager:setDirty(panel_viewer, function()
        return initial_refresh, panel_viewer.dimen, Screen.sw_dithering  -- Enable dithering for E-ink
    end)
    
    logger.info("PanelZoom: New PanelViewer shown with KOReader refresh logic")
    
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
            
            table.insert(menu_items, 2, {  -- insert after reading direction
    text = _("Horizontal Offset"),
    sub_item_table = {
        {
            text = _("Left 1 px"),
            callback = function()
                self.horizontal_offset = (self.horizontal_offset or 0) - 1
                logger.info("PanelZoom: Horizontal offset set to " .. self.horizontal_offset)
                self:refreshCurrentPanelIfActive()
            end
        },
        {
            text = _("Right 1 px"),
            callback = function()
                self.horizontal_offset = (self.horizontal_offset or 0) + 1
                logger.info("PanelZoom: Horizontal offset set to " .. self.horizontal_offset)
                self:refreshCurrentPanelIfActive()
            end
        },
        {
            text = _("Reset"),
            callback = function()
                self.horizontal_offset = 0
                logger.info("PanelZoom: Horizontal offset reset to 0")
                self:refreshCurrentPanelIfActive()
            end
        }
    },
    separator = true,
})

            -- Toggle: flashing full refresh to avoid E-ink ghosting (default on)
            table.insert(menu_items, 3, {
                text = _("Reduce ghosting (full refresh)"),
                checked_func = function()
                    return self.full_refresh
                end,
                callback = function()
                    self.full_refresh = not self.full_refresh
                    if G_reader_settings then
                        G_reader_settings:saveSetting("panelzoom_full_refresh", self.full_refresh)
                    end
                    if self._current_imgviewer then
                        self._current_imgviewer.full_refresh = self.full_refresh
                    end
                    logger.info("PanelZoom: Full refresh set to " .. tostring(self.full_refresh))
                end,
                separator = true,
            })

            -- Toggle: show the whole page before its panels (default on)
            table.insert(menu_items, 4, {
                text = _("Show full page before panels"),
                checked_func = function()
                    return self.show_full_page_first
                end,
                callback = function()
                    self.show_full_page_first = not self.show_full_page_first
                    if G_reader_settings then
                        G_reader_settings:saveSetting("panelzoom_full_page_first", self.show_full_page_first)
                    end
                    logger.info("PanelZoom: Show full page first set to " .. tostring(self.show_full_page_first))
                end,
                separator = true,
            })

            -- Add reading direction submenu at the beginning
            table.insert(menu_items, 1, {
                text = _("Reading Direction"),
                sub_item_table = {
                    {
                        text = _("Auto (from JSON)"),
                        checked_func = function()
                            return self.reading_direction_override == nil
                        end,
                        callback = function()
                            self.reading_direction_override = nil
                            logger.info("PanelZoom: Reading direction set to Auto (from JSON)")
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                    {
                        text = _("Left-to-Right (LTR)"),
                        checked_func = function()
                            return self.reading_direction_override == "ltr"
                        end,
                        callback = function()
                            self.reading_direction_override = "ltr"
                            logger.info("PanelZoom: Reading direction override set to LTR")
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
                            logger.info("PanelZoom: Reading direction override set to RTL")
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                },
                separator = true,
            })
            
            return menu_items
        end
        
        logger.info("PanelZoom: Integrated reading direction options into panel zoom menu")
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
        logger.info("PanelZoom: Restored original panel zoom menu")
    end
end

-- Refresh current panel if viewer is active (for reading direction changes)
function PanelZoomIntegration:refreshCurrentPanelIfActive()
    if self._current_imgviewer and self.integration_mode and #self.current_panels > 0 then
        logger.info("PanelZoom: Refreshing panel viewer with new reading direction")
        self:displayCurrentPanel()
    end
end

-- Helper function: Calculate position to move panel center exactly to screen center
function PanelZoomIntegration:panelCenterToScreenPosition(panel, rect, dim, zoom)
    if not panel or not rect or not dim or not zoom then
        logger.warn("PanelZoom: Invalid parameters in panelCenterToScreenPosition")
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

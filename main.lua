--[[
Dynamic Panel Zoom - Main Logic
Author: Community (Inspired by Kaito0's work)
Version: 1.0.0
--]]

-- KOReader Dependencies
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Plugin Components
local PanelViewer = require("panel_viewer") -- Custom panel viewer

-- Utilities
local _ = require("gettext")
local logger = require("logger")
local util = require("util")
local json = require("json")

-- ===================================================================
-- MAIN CLASS: PanelZoomIntegration
-- Manages KOReader integration, on-the-fly panel detection,
-- and the viewer's lifecycle.
-- ===================================================================
local PanelZoomIntegration = WidgetContainer:extend{
    name = "dynamic_panelzoom",
    
    -- --- PLUGIN STATE ---
    integration_mode = false,       -- Is the dynamic panel mode currently active?
    current_panels = {},            -- Table holding the bounding boxes of detected panels for the current page
    current_panel_index = 1,        -- Index of the currently displayed panel
    last_page_seen = -1,            -- Tracks the last processed page to avoid redundant analysis
    _panel_cache = {},              -- In-memory cache of detected panels per document/page

    -- --- NAVIGATION & PRELOADING ---
    tap_navigation_enabled = true,  -- Enable tap-to-navigate
    tap_zones = { left = 0.3, right = 0.7 }, -- Screen tap zones for previous/next
    _preloaded_image = nil,         -- Image buffer for the next panel (preloaded in background)
    _preloaded_panel_index = nil,   -- Index of the preloaded panel
    _is_switching = false,          -- Debounce flag to prevent issues with rapid tapping

    -- --- KOREADER INTEGRATION ---
    -- We store original KOReader handlers so we can restore them when the plugin is disabled/closed
    _original_panel_zoom_handler = nil,
    _original_ocr_handler = nil,
    _original_ocr_menu_enabled = nil,
    _original_genPanelZoomMenu = nil,
    
    -- --- USER SETTINGS ---
    reading_direction_override = nil, -- "ltr" (Left-to-Right) or "rtl" (Right-to-Left)
    horizontal_offset = 0,          -- Manual horizontal offset adjustment for panels
}

--
-- FUNCTION: init()
-- Called when the plugin is loaded. Sets up event handlers.
--
function PanelZoomIntegration:init()
    -- Attempt integration when a new document is opened
    self.onDocumentLoaded = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Check integration status on page turns
    self.onPageUpdate = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Re-render the current panel if the user changes global settings (like contrast)
    self.onSettingsUpdate = function()
        if self._current_imgviewer and self.integration_mode then
            logger.info("PanelZoom: Settings changed, refreshing current panel")
            self:displayCurrentPanel()
        end
    end
    
    -- Inject our custom options into KOReader's native "Panel Zoom" menu
    self:setupPanelZoomMenuIntegration()
end

--
-- FUNCTION: getEffectiveReadingDirection()
-- Returns the reading direction to use (user override takes precedence).
--
function PanelZoomIntegration:getEffectiveReadingDirection()
    if self.reading_direction_override then
        return self.reading_direction_override
    end
    return "ltr" -- Default to Left-to-Right
end

--
-- FUNCTION: checkAndIntegratePanelZoom()
-- Activates the integration with KOReader's native Panel Zoom system.
--
function PanelZoomIntegration:checkAndIntegratePanelZoom()
    if not self.ui.document then return end
    
    -- Unlike other plugins, ours is always "available" because it analyzes 
    -- the page on the fly and doesn't rely on external metadata files.
    self:integrateWithPanelZoom()
    logger.info("DynamicPanelZoom: Automatic integration enabled.")
end

--
-- FUNCTION: integrateWithPanelZoom()
-- Overrides KOReader's Panel Zoom and OCR handlers with our own logic.
--
function PanelZoomIntegration:integrateWithPanelZoom()
    if not self.ui.highlight then return end
    
    -- Store the original Panel Zoom handler if we haven't already
    if not self._original_panel_zoom_handler then
        self._original_panel_zoom_handler = self.ui.highlight.onPanelZoom
    end
    
    -- Override the handler to redirect to our dynamic analysis logic
    self.ui.highlight.onPanelZoom = function(inst, arg, ges)
        return self:onIntegratedPanelZoom(arg, ges)
    end
    
    self.integration_mode = true
    if self.ui.highlight then self.ui.highlight.panel_zoom_enabled = true end
    
    -- Block OCR functionality, as it conflicts with our custom panel viewer
    self:blockOCR()
end

--
-- FUNCTION: restoreOriginalPanelZoom()
-- Restores KOReader's original handlers, effectively disabling our plugin's interception.
--
function PanelZoomIntegration:restoreOriginalPanelZoom()
    if not self.ui.highlight then return end
    
    -- Restore the original Panel Zoom handler
    if self._original_panel_zoom_handler then
        self.ui.highlight.onPanelZoom = self._original_panel_zoom_handler
    end
    
    self.integration_mode = false
    
    -- Restore OCR and Menu functionality
    self:restoreOCR()
    self:restorePanelZoomMenu()
end

--
-- FUNCTION: blockOCR() / restoreOCR()
-- Helper functions to temporarily disable and then re-enable KOReader's OCR system.
--
function PanelZoomIntegration:blockOCR()
    if not self._original_ocr_handler and self.ui.ocr then
        self._original_ocr_handler = self.ui.ocr.onOCRText
    end
    
    if self.ui.ocr then
        self.ui.ocr.onOCRText = function()
            logger.info("DynamicPanelZoom: OCR blocked because panel viewer is active.")
            return false
        end
    end
end

function PanelZoomIntegration:restoreOCR()
    if self.ui.ocr and self._original_ocr_handler then
        self.ui.ocr.onOCRText = self._original_ocr_handler
        self._original_ocr_handler = nil
    end
end


-- ===================================================================
-- PANEL NAVIGATION
-- ===================================================================

--
-- FUNCTION: nextPanel() / prevPanel()
-- Executed when the user taps the designated zones on the screen.
--
function PanelZoomIntegration:nextPanel()
    if self._is_switching then return end -- Debounce to prevent multiple rapid triggers
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    -- If the next panel is already preloaded, display it instantly
    if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
        self.current_panel_index = self.current_panel_index + 1
        self:displayPreloadedPanel()
        return
    end
    
    -- Otherwise, proceed to the next panel or the next page
    if self.current_panel_index < #self.current_panels then
        self.current_panel_index = self.current_panel_index + 1
        self:displayCurrentPanel()
    else
        self:changePage(1) -- Last panel reached, turn to the next page
    end
end

function PanelZoomIntegration:prevPanel()
    if self._is_switching then return end -- Debounce
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    if self.current_panel_index > 1 then
        self.current_panel_index = self.current_panel_index - 1
        self:displayCurrentPanel()
    else
        self:changePage(-1) -- First panel reached, turn to the previous page
    end
end

--
-- FUNCTION: closeViewer()
-- Closes the custom panel viewer and frees up resources.
--
function PanelZoomIntegration:closeViewer()
    if self._current_imgviewer then
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
        self:cleanupPreloadedImage()
        self:restoreOCR() -- Re-enable OCR upon exiting
    end
end

-- ===================================================================
-- PANEL RENDERING & PRELOADING
-- ===================================================================

--
-- FUNCTION: preloadNextPanel()
-- Renders the next panel in the background to ensure smooth, instant transitions.
--
function PanelZoomIntegration:preloadNextPanel()
    self:cleanupPreloadedImage() -- Clear any previously preloaded data
    
    if self.current_panel_index < #self.current_panels then
        local next_panel_index = self.current_panel_index + 1
        local next_panel = self.current_panels[next_panel_index]
        
        if next_panel then
            local page = self:getSafePageNumber()
            local dim = self.ui.document:getNativePageDimensions(page)
            
            if dim then
                local rect = self:panelToRect(next_panel, dim)
                -- Render the specific portion of the page representing the panel
                local image, _, custom_position = self:drawPagePartWithSettings(page, rect, nil, next_panel, dim)
                
                if image then
                    self._preloaded_image = image
                    self._preloaded_panel_index = next_panel_index
                    self._preloaded_custom_position = custom_position
                end
            end
        end
    end
end

--
-- FUNCTION: displayPreloadedPanel()
-- Instantly displays the panel that was rendered in the background.
--
function PanelZoomIntegration:displayPreloadedPanel()
    if not self._preloaded_image or not self._current_imgviewer then return false end
    
    -- Update the existing viewer with the preloaded image and position
    self._current_imgviewer:updateImage(self._preloaded_image)
    self._current_imgviewer:updateCustomPosition(self._preloaded_custom_position)
    self._current_imgviewer:update()
    
    -- Clear preload data after use
    self._preloaded_image = nil
    self._preloaded_panel_index = nil
    self._preloaded_custom_position = nil
    
    -- Immediately schedule the preloading of the *next* panel
    UIManager:scheduleIn(0.1, function() self:preloadNextPanel() end)
    return true
end

--
-- FUNCTION: drawPagePartWithSettings()
-- Core rendering function. Extracts a section of the page (the panel) and applies
-- the user's current display settings (zoom, contrast, gamma, invert).
--
function PanelZoomIntegration:drawPagePartWithSettings(pageno, rect, panel_center, panel, dim)
    local doc_cfg = self.ui.document.info.config or {}
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    local contrast = doc_cfg.contrast or 1.0
    
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()

    -- Define a "safe zone" to ensure panels don't touch the absolute screen edge
    local padding = 5
    local safe_w, safe_h = screen_w - (padding * 2), screen_h - (padding * 2)

    -- Calculate the required scale to fit the panel inside the safe zone
    local final_scale = math.min(safe_w / rect.w, safe_h / rect.h)
    local display_w, display_h = math.floor(rect.w * final_scale + 0.5), math.floor(rect.h * final_scale + 0.5)

    -- Calculate coordinates to center the panel on the screen
    local pos_x, pos_y = (screen_w - display_w) / 2, (screen_h - display_h) / 2
    
    -- Calculate final position, clamping it to the safe zone boundaries
    local custom_position = {
        x = math.floor(math.max(padding, math.min(pos_x, screen_w - display_w - padding)) + 0.5),
        y = math.floor(math.max(padding, math.min(pos_y, screen_h - display_h - padding)) + 0.5)
    }
    
    -- Apply the manual horizontal offset (if any)
    custom_position.x = custom_position.x + self.horizontal_offset
    
    -- Request the specific page rectangle from KOReader's rendering engine (MuPDF)
    local geom_rect = Geom:new(rect)
    local tile = self.ui.document:renderPage(pageno, geom_rect, final_scale, 0, gamma, true)
    local image = tile.bb

    -- Apply image post-processing based on document settings
    if image then
        if contrast ~= 1.0 and image.contrast then image:contrast(contrast) end
        if doc_cfg.invert and image.invert then image:invert() end
    end

    return image, false, custom_position
end


-- ===================================================================
-- DYNAMIC PANEL DETECTION ENGINE
-- ===================================================================

--
-- FUNCTION: onIntegratedPanelZoom()
-- Main entry point triggered when the user activates "Panel Zoom" in KOReader.
--
function PanelZoomIntegration:onIntegratedPanelZoom(arg, ges)
    local current_page = self:getSafePageNumber()
    
    -- If we moved to a new page or have no panel data, analyze the page
    if current_page ~= self.last_page_seen or #self.current_panels == 0 then
        self.last_page_seen = current_page
        self:importAndAnalyzePanels()
    end

    -- If panels were found, start by displaying the first one
    if #self.current_panels > 0 then
        self.current_panel_index = 1
        return self:displayCurrentPanel()
    end

    logger.warn("DynamicPanelZoom: No panels detected on this page.")
    return false
end

--
-- FUNCTION: importAndAnalyzePanels()
-- Checks the in-memory cache first; if empty, triggers the Leptonica analysis.
--
function PanelZoomIntegration:importAndAnalyzePanels()
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    local page_idx = self:getSafePageNumber()
    
    -- Check cache first to save CPU cycles
    if self._panel_cache[doc_path] and self._panel_cache[doc_path][page_idx] then
        self.current_panels = self._panel_cache[doc_path][page_idx]
        return
    end
    
    -- Perform real-time image analysis to detect panels
    logger.info("DynamicPanelZoom: Dynamically analyzing page " .. page_idx .. " for panels.")
    self.current_panels = self:analyzePageForPanels(page_idx)
    
    -- Store results in cache for this session
    if not self._panel_cache[doc_path] then self._panel_cache[doc_path] = {} end
    self._panel_cache[doc_path][page_idx] = self.current_panels
end

--
-- FUNCTION: analyzePageForPanels()
-- The core engine. Uses the Leptonica C library via FFI to process the page
-- image, binarize it, and find the bounding boxes of distinct content (panels).
--
function PanelZoomIntegration:analyzePageForPanels(pageno)
    local ffi = require("ffi")
    local leptonica = ffi.loadlib("leptonica", "6") -- Load Leptonica library
    
    if not self.ui.document or not self.ui.document._document then return {} end
    
    local KOPTContext = require("ffi/koptcontext")
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    if not page_size then return {} end
    
    -- Retrieve a grayscale image of the entire page
    local bbox = { x0 = 0, y0 = 0, x1 = page_size.w, y1 = page_size.h }
    local kc = KOPTContext.new()
    kc:setZoom(1.0)
    kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    
    local page = self.ui.document._document:openPage(pageno)
    if not page then if kc.free then kc:free() end return {} end
    page:getPagePix(kc, self.ui.document.render_mode)
    
    local panels = {}
    
    if kc.src.data then
        -- --- LEPTONICA IMAGE PROCESSING PIPELINE ---
        -- 1. Convert KOReader bitmap to a Leptonica PIX object.
        -- 2. Ensure grayscale and binarize the image (black and white).
        -- 3. Find connected components (blobs of pixels) and their bounding boxes.
        -- 4. Filter out boxes that are too small to be actual panels.
        -- 5. Normalize the coordinates to a 0.0 - 1.0 scale.
        
        local KOPTContextClass = require("ffi/koptcontext")
        local k2pdfopt = KOPTContextClass.k2pdfopt

        -- FFI Memory management helpers (crucial to avoid leaks)
        local function _gc_ptr(p, destructor) return p and ffi.gc(p, destructor) end
        local function pixDestroy(pix) leptonica.pixDestroy(ffi.new('PIX *[1]', pix)); ffi.gc(pix, nil) end
        local function boxaDestroy(boxa) leptonica.boxaDestroy(ffi.new('BOXA *[1]', boxa)); ffi.gc(boxa, nil) end

        -- Execution steps
        local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, kc.src.width, kc.src.height), pixDestroy)
        local pixg = _gc_ptr(leptonica.pixGetDepth(pixs) == 32 and leptonica.pixConvertRGBToGrayFast(pixs) or leptonica.pixClone(pixs), pixDestroy)
        local pix_inverted = _gc_ptr(leptonica.pixInvert(nil, pixg), pixDestroy)
        local pix_thresholded = _gc_ptr(leptonica.pixThresholdToBinary(pix_inverted, 50), pixDestroy)
        leptonica.pixInvert(pix_thresholded, pix_thresholded)
        
        -- The Magic: Find bounding boxes of connected components
        local bb = _gc_ptr(leptonica.pixConnCompBB(pix_thresholded, 8), boxaDestroy)
        
        local img_w, img_h = leptonica.pixGetWidth(pixs), leptonica.pixGetHeight(pixs)
        
        local count = leptonica.boxaGetCount(bb)
        for index = 0, count - 1 do
            local box = leptonica.boxaGetBox(bb, index, leptonica.L_CLONE)
            
            local geo = ffi.new('l_int32[4]')
            leptonica.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
            local box_x, box_y, box_w, box_h = tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])

            -- Filter: Discard bounding boxes that cover less than 1/8th of the page width/height
            if box_w >= img_w / 8 and box_h >= img_h / 8 then
                table.insert(panels, {
                    x = box_x / page_size.w,
                    y = box_y / page_size.h,
                    w = box_w / page_size.w,
                    h = box_h / page_size.h,
                })
            end
            leptonica.boxDestroy(ffi.new('BOX *[1]', box))
        end
    end
    
    page:close()
    if kc.free then kc:free() end
    
    -- Sort the detected panels based on reading direction (crucial for Manga)
    local effective_dir = self:getEffectiveReadingDirection()
    table.sort(panels, function(a, b)
        -- Primary sort: Top to Bottom. Secondary sort: Left/Right based on reading direction.
        local a_center_y, b_center_y = a.y + (a.h / 2), b.y + (b.h / 2)
        
        -- If panels are roughly on the same horizontal row (within 10% tolerance)
        if math.abs(a_center_y - b_center_y) < 0.1 then 
            return (effective_dir == "rtl") and (a.x > b.x) or (a.x < b.x)
        end
        return a_center_y < b_center_y -- Otherwise, higher panel goes first
    end)
    
    return panels
end


-- ===================================================================
-- UTILITIES & CALCULATIONS
-- ===================================================================

--
-- FUNCTION: panelToRect()
-- Converts normalized panel coordinates (0.0-1.0) into absolute pixel coordinates,
-- adding a small padding to provide visual context around the panel.
--
function PanelZoomIntegration:panelToRect(panel, dim)
    local px, py = panel.x * dim.w, panel.y * dim.h
    local pw, ph = panel.w * dim.w, panel.h * dim.h
    
    -- Add a slight margin so the panel doesn't feel uncomfortably cropped
    local extension = 2
    local render_rect = {
        x = px - extension,
        y = py - extension,
        w = pw + (extension * 2),
        h = ph + (extension * 2),
    }
    
    -- Ensure the padded rectangle strictly remains within the page boundaries
    render_rect.w = math.min(render_rect.w, dim.w)
    render_rect.h = math.min(render_rect.h, dim.h)
    render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
    render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))
    
    return render_rect
end

--
-- FUNCTION: displayCurrentPanel()
-- Orchestrates the rendering and display of the currently targeted panel.
--
function PanelZoomIntegration:displayCurrentPanel()
    local panel = self.current_panels[self.current_panel_index]
    if not panel then return false end

    local page = self:getSafePageNumber()
    local dim = self.ui.document:getNativePageDimensions(page)
    if not dim then return false end

    -- Generate the cropped image for the panel
    local rect = self:panelToRect(panel, dim)
    local image, _, custom_position = self:drawPagePartWithSettings(page, rect, nil, panel, dim)
    if not image then return false end

    -- Destroy the previous viewer instance to avoid memory leaks
    if self._current_imgviewer then
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
    end
    
    -- Instantiate and display our custom PanelViewer
    local panel_viewer = PanelViewer:new{
        image = image,
        fullscreen = true,
        reading_direction = self:getEffectiveReadingDirection(),
        custom_position = custom_position,
        onNext = function() self:nextPanel() end,
        onPrev = function() self:prevPanel() end,
        onClose = function() self:closeViewer() end,
    }
    
    self._current_imgviewer = panel_viewer
    UIManager:show(panel_viewer)
    
    -- Force a full screen refresh (vital for E-Ink displays to clear ghosting)
    UIManager:setDirty(panel_viewer, "full")
    
    -- Initiate background preloading for the next panel
    UIManager:scheduleIn(0.2, function() self:preloadNextPanel() end)
    
    return true
end

--
-- FUNCTION: setupPanelZoomMenuIntegration()
-- Injects custom settings ("Reading Direction" and "Horizontal Offset") 
-- directly into KOReader's native Panel Zoom configuration menu.
--
function PanelZoomIntegration:setupPanelZoomMenuIntegration()
    if not self._original_genPanelZoomMenu and self.ui.highlight and self.ui.highlight.genPanelZoomMenu then
        self._original_genPanelZoomMenu = self.ui.highlight.genPanelZoomMenu
        
        self.ui.highlight.genPanelZoomMenu = function()
            local menu_items = self._original_genPanelZoomMenu(self.ui.highlight)
            
            -- Inject Horizontal Offset submenu
            table.insert(menu_items, 2, {
                text = _("Horizontal Offset"),
                sub_item_table = {
                    { text = _("Left 1 px"), callback = function() self.horizontal_offset = (self.horizontal_offset or 0) - 1; self:refreshCurrentPanelIfActive() end },
                    { text = _("Right 1 px"), callback = function() self.horizontal_offset = (self.horizontal_offset or 0) + 1; self:refreshCurrentPanelIfActive() end },
                    { text = _("Reset"), callback = function() self.horizontal_offset = 0; self:refreshCurrentPanelIfActive() end },
                },
                separator = true,
            })
            
            -- Inject Reading Direction submenu
            table.insert(menu_items, 1, {
                text = _("Reading Direction"),
                sub_item_table = {
                    { text = _("Left-to-Right (LTR)"), checked_func = function() return self:getEffectiveReadingDirection() == "ltr" end, callback = function() self.reading_direction_override = "ltr"; self:refreshCurrentPanelIfActive() end },
                    { text = _("Right-to-Left (RTL)"), checked_func = function() return self:getEffectiveReadingDirection() == "rtl" end, callback = function() self.reading_direction_override = "rtl"; self:refreshCurrentPanelIfActive() end },
                },
                separator = true,
            })
            
            return menu_items
        end
    end
end

--
-- FUNCTION: refreshCurrentPanelIfActive()
-- Forces a re-render of the active panel. Triggered when user changes a setting.
--
function PanelZoomIntegration:refreshCurrentPanelIfActive()
    if self._current_imgviewer and self.integration_mode and #self.current_panels > 0 then
        -- Re-analyze and re-sort panels based on the new reading direction
        self:importAndAnalyzePanels()
        -- Re-display (the current index might point to a different panel now due to sorting)
        self:displayCurrentPanel()
    end
end


-- ===================================================================
-- HELPERS & FALLBACKS
-- ===================================================================

function PanelZoomIntegration:cleanupPreloadedImage()
    if self._preloaded_image then self._preloaded_image = nil; self._preloaded_panel_index = nil; self._preloaded_custom_position = nil end
end

function PanelZoomIntegration:restorePanelZoomMenu()
    if self._original_genPanelZoomMenu and self.ui.highlight then self.ui.highlight.genPanelZoomMenu = self._original_genPanelZoomMenu; self._original_genPanelZoomMenu = nil end
end

function PanelZoomIntegration:changePage(diff)
    -- Attempt to use KOReader's native paging, fallback to sending keyboard events
    if self.ui.paging and self.ui.paging.onGotoViewRel then
        self.ui.paging:onGotoViewRel(diff)
    else
        UIManager:sendEvent({ key = diff > 0 and "Right" or "Left", modifiers = {} })
    end
        
    -- Wait briefly for the engine to render the new page before analyzing
    UIManager:scheduleIn(0.3, function()
        local new_page = self:getSafePageNumber()
        self.last_page_seen = new_page
        self:cleanupPreloadedImage()
        self:importAndAnalyzePanels()
        
        if #self.current_panels > 0 then
            self.current_panel_index = diff > 0 and 1 or #self.current_panels
            self:displayCurrentPanel()
        else
            -- If no panels found on the new page, close the viewer and notify the user
            if self._current_imgviewer then UIManager:close(self._current_imgviewer); self._current_imgviewer = nil end
            UIManager:show(InfoMessage:new{ text = _("No panels on this page"), timeout = 1 })
        end
    end)
end

-- Robust helper to retrieve the current page number across different KOReader versions/states
function PanelZoomIntegration:getSafePageNumber()
    if self.ui.paging and self.ui.paging.getPage then return self.ui.paging:getPage() end
    if self.ui.paging and self.ui.paging.cur_page then return self.ui.paging.cur_page end
    if self.ui.document and self.ui.document.current_page then return self.ui.document.current_page end
    if self.ui.view and self.ui.view.state and self.ui.view.state.page then return self.ui.view.state.page end
    return 1
end

return PanelZoomIntegration

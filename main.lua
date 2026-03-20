--[[
Dynamic Panel Zoom - Lógica Principal
Autor: Tu Nombre/Alias (Inspirado en el trabajo de Kaito0)
Versión: 1.0.0
--]]

-- Dependencias de KOReader
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Componentes del plugin
local PanelViewer = require("panel_viewer") -- Visor de paneles personalizado

-- Utilidades
local _ = require("gettext")
local logger = require("logger")
local util = require("util")
local json = require("json")

-- ===================================================================
-- CLASE PRINCIPAL: PanelZoomIntegration
-- Gestiona la integración con KOReader, la detección de paneles
-- y el ciclo de vida del visor.
-- ===================================================================
local PanelZoomIntegration = WidgetContainer:extend{
    name = "dynamic_panelzoom",
    
    -- --- ESTADO DEL PLUGIN ---
    integration_mode = false,       -- ¿Está el modo de panel dinámico activo?
    current_panels = {},            -- Tabla con las coordenadas de los paneles detectados para la página actual
    current_panel_index = 1,        -- Índice del panel que se está mostrando
    last_page_seen = -1,            -- Última página procesada para evitar re-análisis innecesarios
    _panel_cache = {},              -- Caché en memoria de los paneles detectados por documento/página

    -- --- NAVEGACIÓN Y PRECARGA ---
    tap_navigation_enabled = true,  -- Habilitar navegación por toques (taps)
    tap_zones = { left = 0.3, right = 0.7 }, -- Zonas de toque para siguiente/anterior
    _preloaded_image = nil,         -- Buffer de imagen para el siguiente panel (precargado)
    _preloaded_panel_index = nil,   -- Índice del panel precargado
    _is_switching = false,          -- Flag para evitar múltiples cambios de panel por toques rápidos (debounce)

    -- --- INTEGRACIÓN CON KOREADER ---
    -- Guardamos las funciones originales para poder restaurarlas al salir
    _original_panel_zoom_handler = nil,
    _original_ocr_handler = nil,
    _original_ocr_menu_enabled = nil,
    _original_genPanelZoomMenu = nil,
    
    -- --- CONFIGURACIÓN DE USUARIO ---
    reading_direction_override = nil, -- "ltr" (izquierda-a-derecha) o "rtl" (derecha-a-izquierda)
    horizontal_offset = 0,          -- Desplazamiento horizontal manual para los paneles
}

--
-- FUNCIÓN: init()
-- Se ejecuta al cargar el plugin. Configura los manejadores de eventos.
--
function PanelZoomIntegration:init()
    -- Cuando se carga un nuevo documento, intentamos activar la integración
    self.onDocumentLoaded = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Cuando se cambia de página, también lo comprobamos
    self.onPageUpdate = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Si el usuario cambia ajustes (como el contraste), refrescamos el panel actual
    self.onSettingsUpdate = function()
        if self._current_imgviewer and self.integration_mode then
            logger.info("PanelZoom: Ajustes cambiados, refrescando panel actual")
            self:displayCurrentPanel()
        end
    end
    
    -- Añadimos nuestras opciones al menú de "Panel Zoom" de KOReader
    self:setupPanelZoomMenuIntegration()
end

--
-- FUNCIÓN: getEffectiveReadingDirection()
-- Devuelve la dirección de lectura a usar (la del usuario tiene prioridad).
--
function PanelZoomIntegration:getEffectiveReadingDirection()
    if self.reading_direction_override then
        return self.reading_direction_override
    end
    return "ltr" -- Por defecto, izquierda a derecha
end

--
-- FUNCIÓN: checkAndIntegratePanelZoom()
-- Activa la integración con el sistema de "Panel Zoom" de KOReader.
--
function PanelZoomIntegration:checkAndIntegratePanelZoom()
    if not self.ui.document then return end
    
    -- A diferencia de otros plugins, el nuestro siempre está "disponible"
    -- porque no depende de archivos externos.
    self:integrateWithPanelZoom()
    logger.info("DynamicPanelZoom: Integración automática habilitada.")
end

--
-- FUNCIÓN: integrateWithPanelZoom()
-- Sobrescribe las funciones de Panel Zoom y OCR de KOReader con las nuestras.
--
function PanelZoomIntegration:integrateWithPanelZoom()
    if not self.ui.highlight then return end
    
    -- Guardamos el manejador original de "Panel Zoom" si no lo hemos hecho ya
    if not self._original_panel_zoom_handler then
        self._original_panel_zoom_handler = self.ui.highlight.onPanelZoom
    end
    
    -- Sobrescribimos el manejador para que llame a nuestra lógica
    self.ui.highlight.onPanelZoom = function(inst, arg, ges)
        return self:onIntegratedPanelZoom(arg, ges)
    end
    
    self.integration_mode = true
    if self.ui.highlight then self.ui.highlight.panel_zoom_enabled = true end
    
    -- Bloqueamos el OCR, ya que es incompatible con nuestro visor de paneles
    self:blockOCR()
end

--
-- FUNCIÓN: restoreOriginalPanelZoom()
-- Restaura los manejadores originales de KOReader, desactivando nuestro plugin.
--
function PanelZoomIntegration:restoreOriginalPanelZoom()
    if not self.ui.highlight then return end
    
    -- Restaura el manejador de "Panel Zoom"
    if self._original_panel_zoom_handler then
        self.ui.highlight.onPanelZoom = self._original_panel_zoom_handler
    end
    
    self.integration_mode = false
    
    -- Restaura el OCR y el menú
    self:restoreOCR()
    self:restorePanelZoomMenu()
end

--
-- FUNCIÓN: blockOCR() / restoreOCR()
-- Funciones para desactivar y reactivar el sistema de OCR de KOReader.
--
function PanelZoomIntegration:blockOCR()
    if not self._original_ocr_handler and self.ui.ocr then
        self._original_ocr_handler = self.ui.ocr.onOCRText
    end
    
    if self.ui.ocr then
        self.ui.ocr.onOCRText = function()
            logger.info("DynamicPanelZoom: OCR bloqueado porque el visor de paneles está activo.")
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
-- NAVEGACIÓN ENTRE PANELES
-- ===================================================================

--
-- FUNCIÓN: nextPanel() / prevPanel()
-- Se ejecutan al tocar la parte derecha o izquierda de la pantalla.
--
function PanelZoomIntegration:nextPanel()
    if self._is_switching then return end -- Evitar toques múltiples
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    -- Si tenemos el siguiente panel precargado, lo mostramos al instante
    if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
        self.current_panel_index = self.current_panel_index + 1
        self:displayPreloadedPanel()
        return
    end
    
    -- Si no, avanzamos al siguiente panel o a la siguiente página
    if self.current_panel_index < #self.current_panels then
        self.current_panel_index = self.current_panel_index + 1
        self:displayCurrentPanel()
    else
        self:changePage(1) -- Último panel, cambiamos de página
    end
end

function PanelZoomIntegration:prevPanel()
    if self._is_switching then return end -- Evitar toques múltiples
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    if self.current_panel_index > 1 then
        self.current_panel_index = self.current_panel_index - 1
        self:displayCurrentPanel()
    else
        self:changePage(-1) -- Primer panel, volvemos a la página anterior
    end
end

--
-- FUNCIÓN: closeViewer()
-- Cierra el visor de paneles y libera recursos.
--
function PanelZoomIntegration:closeViewer()
    if self._current_imgviewer then
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
        self:cleanupPreloadedImage()
        self:restoreOCR() -- Restauramos el OCR al salir
    end
end

-- ===================================================================
-- RENDERIZADO Y PRECARGA DE PANELES
-- ===================================================================

--
-- FUNCIÓN: preloadNextPanel()
-- Renderiza el siguiente panel en segundo plano para una transición fluida.
--
function PanelZoomIntegration:preloadNextPanel()
    self:cleanupPreloadedImage() -- Limpia la imagen precargada anterior
    
    if self.current_panel_index < #self.current_panels then
        local next_panel_index = self.current_panel_index + 1
        local next_panel = self.current_panels[next_panel_index]
        
        if next_panel then
            local page = self:getSafePageNumber()
            local dim = self.ui.document:getNativePageDimensions(page)
            
            if dim then
                local rect = self:panelToRect(next_panel, dim)
                -- Renderiza la porción de la página correspondiente al panel
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
-- FUNCIÓN: displayPreloadedPanel()
-- Muestra el panel que ya ha sido renderizado en segundo plano.
--
function PanelZoomIntegration:displayPreloadedPanel()
    if not self._preloaded_image or not self._current_imgviewer then return false end
    
    -- Actualiza la imagen y la posición en el visor actual
    self._current_imgviewer:updateImage(self._preloaded_image)
    self._current_imgviewer:updateCustomPosition(self._preloaded_custom_position)
    self._current_imgviewer:update()
    
    -- Limpiamos los datos de precarga una vez usados
    self._preloaded_image = nil
    self._preloaded_panel_index = nil
    self._preloaded_custom_position = nil
    
    -- Programamos la precarga del siguiente panel
    UIManager:scheduleIn(0.1, function() self:preloadNextPanel() end)
    return true
end

--
-- FUNCIÓN: drawPagePartWithSettings()
-- Función clave. Renderiza una sección de la página (un panel) aplicando
-- los ajustes de zoom, contraste, gamma, etc. del usuario.
--
function PanelZoomIntegration:drawPagePartWithSettings(pageno, rect, panel_center, panel, dim)
    local doc_cfg = self.ui.document.info.config or {}
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    local contrast = doc_cfg.contrast or 1.0
    
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()

    -- Calculamos un "área segura" con un pequeño margen
    local padding = 5
    local safe_w, safe_h = screen_w - (padding * 2), screen_h - (padding * 2)

    -- Calculamos la escala necesaria para que el panel quepa en el área segura
    local final_scale = math.min(safe_w / rect.w, safe_h / rect.h)
    local display_w, display_h = math.floor(rect.w * final_scale + 0.5), math.floor(rect.h * final_scale + 0.5)

    -- Centramos el panel en la pantalla
    local pos_x, pos_y = (screen_w - display_w) / 2, (screen_h - display_h) / 2
    
    -- Calculamos la posición final, asegurando que no se salga de los márgenes
    local custom_position = {
        x = math.floor(math.max(padding, math.min(pos_x, screen_w - display_w - padding)) + 0.5),
        y = math.floor(math.max(padding, math.min(pos_y, screen_h - display_h - padding)) + 0.5)
    }
    
    -- Aplicamos el desplazamiento horizontal manual
    custom_position.x = custom_position.x + self.horizontal_offset
    
    -- Renderizamos el fragmento de la página usando la API de KOReader
    local geom_rect = Geom:new(rect)
    local tile = self.ui.document:renderPage(pageno, geom_rect, final_scale, 0, gamma, true)
    local image = tile.bb

    -- Aplicamos post-procesado (contraste, inversión de color)
    if image then
        if contrast ~= 1.0 and image.contrast then image:contrast(contrast) end
        if doc_cfg.invert and image.invert then image:invert() end
    end

    return image, false, custom_position
end


-- ===================================================================
-- DETECCIÓN DINÁMICA DE PANELES
-- ===================================================================

--
-- FUNCIÓN: onIntegratedPanelZoom()
-- Punto de entrada principal cuando el usuario activa "Panel Zoom".
--
function PanelZoomIntegration:onIntegratedPanelZoom(arg, ges)
    local current_page = self:getSafePageNumber()
    
    -- Si hemos cambiado de página o no tenemos paneles, los analizamos
    if current_page ~= self.last_page_seen or #self.current_panels == 0 then
        self.last_page_seen = current_page
        self:importAndAnalyzePanels()
    end

    -- Si se encontraron paneles, mostramos el primero
    if #self.current_panels > 0 then
        self.current_panel_index = 1
        return self:displayCurrentPanel()
    end

    logger.warn("DynamicPanelZoom: No se encontraron paneles en esta página.")
    return false
end

--
-- FUNCIÓN: importAndAnalyzePanels()
-- Comprueba la caché y, si es necesario, llama a la función de análisis.
--
function PanelZoomIntegration:importAndAnalyzePanels()
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    local page_idx = self:getSafePageNumber()
    
    -- Comprobamos primero si ya tenemos los paneles para esta página en caché
    if self._panel_cache[doc_path] and self._panel_cache[doc_path][page_idx] then
        self.current_panels = self._panel_cache[doc_path][page_idx]
        return
    end
    
    -- Si no, analizamos la página para encontrar los paneles
    logger.info("DynamicPanelZoom: Analizando página " .. page_idx .. " para detectar paneles dinámicamente.")
    self.current_panels = self:analyzePageForPanels(page_idx)
    
    -- Guardamos los resultados en la caché
    if not self._panel_cache[doc_path] then self._panel_cache[doc_path] = {} end
    self._panel_cache[doc_path][page_idx] = self.current_panels
end

--
-- FUNCIÓN: analyzePageForPanels()
-- El corazón del plugin. Usa Leptonica a través de FFI para analizar la imagen
-- de la página y detectar los rectángulos que corresponden a los paneles.
--
function PanelZoomIntegration:analyzePageForPanels(pageno)
    local ffi = require("ffi")
    local leptonica = ffi.loadlib("leptonica", "6") -- Cargamos la librería Leptonica
    
    if not self.ui.document or not self.ui.document._document then return {} end
    
    local KOPTContext = require("ffi/koptcontext")
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    if not page_size then return {} end
    
    -- Obtenemos la imagen de la página completa en escala de grises
    local bbox = { x0 = 0, y0 = 0, x1 = page_size.w, y1 = page_size.h }
    local kc = KOPTContext.new()
    kc:setZoom(1.0)
    kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    
    local page = self.ui.document._document:openPage(pageno)
    if not page then if kc.free then kc:free() end return {} end
    page:getPagePix(kc, self.ui.document.render_mode)
    
    local panels = {}
    
    if kc.src.data then
        -- --- PROCESO DE ANÁLISIS DE IMAGEN CON LEPTONICA ---
        -- 1. Convertir el bitmap de KOReader a un objeto PIX de Leptonica.
        -- 2. Convertir a escala de grises y binarizar (blanco y negro).
        -- 3. Encontrar componentes conectados (manchas de píxeles) y sus "cajas" (bounding boxes).
        -- 4. Filtrar las cajas para quedarnos solo con las que son suficientemente grandes para ser paneles.
        -- 5. Convertir las coordenadas de las cajas a un formato relativo (de 0 a 1).
        
        local KOPTContextClass = require("ffi/koptcontext")
        local k2pdfopt = KOPTContextClass.k2pdfopt

        -- Funciones de ayuda para gestionar la memoria de FFI
        local function _gc_ptr(p, destructor) return p and ffi.gc(p, destructor) end
        local function pixDestroy(pix) leptonica.pixDestroy(ffi.new('PIX *[1]', pix)); ffi.gc(pix, nil) end
        local function boxaDestroy(boxa) leptonica.boxaDestroy(ffi.new('BOXA *[1]', boxa)); ffi.gc(boxa, nil) end

        -- Pasos del procesamiento
        local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, kc.src.width, kc.src.height), pixDestroy)
        local pixg = _gc_ptr(leptonica.pixGetDepth(pixs) == 32 and leptonica.pixConvertRGBToGrayFast(pixs) or leptonica.pixClone(pixs), pixDestroy)
        local pix_inverted = _gc_ptr(leptonica.pixInvert(nil, pixg), pixDestroy)
        local pix_thresholded = _gc_ptr(leptonica.pixThresholdToBinary(pix_inverted, 50), pixDestroy)
        leptonica.pixInvert(pix_thresholded, pix_thresholded)
        
        -- Aquí está la magia: encontrar los rectángulos de los componentes conectados
        local bb = _gc_ptr(leptonica.pixConnCompBB(pix_thresholded, 8), boxaDestroy)
        
        local img_w, img_h = leptonica.pixGetWidth(pixs), leptonica.pixGetHeight(pixs)
        
        local count = leptonica.boxaGetCount(bb)
        for index = 0, count - 1 do
            local box = leptonica.boxaGetBox(bb, index, leptonica.L_CLONE)
            
            local geo = ffi.new('l_int32[4]')
            leptonica.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
            local box_x, box_y, box_w, box_h = tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])

            -- Filtro: nos quedamos solo con los rectángulos que son suficientemente grandes
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
    
    -- Ordenamos los paneles según el sentido de lectura (importante para manga)
    local effective_dir = self:getEffectiveReadingDirection()
    table.sort(panels, function(a, b)
        -- Ordenamos de arriba a abajo, y luego por dirección (izquierda/derecha)
        local a_center_y, b_center_y = a.y + (a.h / 2), b.y + (b.h / 2)
        
        if math.abs(a_center_y - b_center_y) < 0.1 then -- Si están en la misma "fila"
            return (effective_dir == "rtl") and (a.x > b.x) or (a.x < b.x)
        end
        return a_center_y < b_center_y -- Si no, el de más arriba va primero
    end)
    
    return panels
end


-- ===================================================================
-- FUNCIONES DE UTILIDAD Y CÁLCULO
-- ===================================================================

--
-- FUNCIÓN: panelToRect()
-- Convierte las coordenadas relativas de un panel en un rectángulo de píxeles
-- absolutos, añadiendo un pequeño "relleno" para dar contexto visual.
--
function PanelZoomIntegration:panelToRect(panel, dim)
    local px, py = panel.x * dim.w, panel.y * dim.h
    local pw, ph = panel.w * dim.w, panel.h * dim.h
    
    -- Añadimos un pequeño margen alrededor del panel para que no se sienta tan "recortado"
    local extension = 2
    local render_rect = {
        x = px - extension,
        y = py - extension,
        w = pw + (extension * 2),
        h = ph + (extension * 2),
    }
    
    -- Nos aseguramos de que el rectángulo no se salga de los límites de la página
    render_rect.w = math.min(render_rect.w, dim.w)
    render_rect.h = math.min(render_rect.h, dim.h)
    render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
    render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))
    
    return render_rect
end

--
-- FUNCIÓN: displayCurrentPanel()
-- Orquesta el proceso de mostrar el panel actual en pantalla.
--
function PanelZoomIntegration:displayCurrentPanel()
    local panel = self.current_panels[self.current_panel_index]
    if not panel then return false end

    local page = self:getSafePageNumber()
    local dim = self.ui.document:getNativePageDimensions(page)
    if not dim then return false end

    -- Obtenemos el rectángulo del panel y lo renderizamos
    local rect = self:panelToRect(panel, dim)
    local image, _, custom_position = self:drawPagePartWithSettings(page, rect, nil, panel, dim)
    if not image then return false end

    -- Cerramos el visor anterior si existe
    if self._current_imgviewer then
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
    end
    
    -- Creamos y mostramos una nueva instancia de nuestro visor personalizado
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
    
    -- Forzamos un refresco de pantalla completo para E-Ink
    UIManager:setDirty(panel_viewer, "full")
    
    -- Precargamos el siguiente panel
    UIManager:scheduleIn(0.2, function() self:preloadNextPanel() end)
    
    return true
end

--
-- FUNCIÓN: setupPanelZoomMenuIntegration()
-- Añade las opciones de "Dirección de Lectura" y "Desplazamiento Horizontal"
-- al menú de configuración del zoom de paneles de KOReader.
--
function PanelZoomIntegration:setupPanelZoomMenuIntegration()
    if not self._original_genPanelZoomMenu and self.ui.highlight and self.ui.highlight.genPanelZoomMenu then
        self._original_genPanelZoomMenu = self.ui.highlight.genPanelZoomMenu
        
        self.ui.highlight.genPanelZoomMenu = function()
            local menu_items = self._original_genPanelZoomMenu(self.ui.highlight)
            
            -- Submenú para el desplazamiento horizontal
            table.insert(menu_items, 2, {
                text = _("Horizontal Offset"),
                sub_item_table = {
                    { text = _("Left 1 px"), callback = function() self.horizontal_offset = (self.horizontal_offset or 0) - 1; self:refreshCurrentPanelIfActive() end },
                    { text = _("Right 1 px"), callback = function() self.horizontal_offset = (self.horizontal_offset or 0) + 1; self:refreshCurrentPanelIfActive() end },
                    { text = _("Reset"), callback = function() self.horizontal_offset = 0; self:refreshCurrentPanelIfActive() end },
                },
                separator = true,
            })
            
            -- Submenú para la dirección de lectura
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
-- FUNCIÓN: refreshCurrentPanelIfActive()
-- Refresca la vista del panel actual si está activa. Útil cuando se cambia una opción.
--
function PanelZoomIntegration:refreshCurrentPanelIfActive()
    if self._current_imgviewer and self.integration_mode and #self.current_panels > 0 then
        -- Re-analiza y re-ordena los paneles con la nueva dirección
        self:importAndAnalyzePanels()
        -- Muestra el panel actual, que podría ser diferente si el orden cambió
        self:displayCurrentPanel()
    end
end


-- ===================================================================
-- HELPERS Y OTRAS FUNCIONES
-- ===================================================================

function PanelZoomIntegration:cleanupPreloadedImage()
    if self._preloaded_image then self._preloaded_image = nil; self._preloaded_panel_index = nil; self._preloaded_custom_position = nil end
end

function PanelZoomIntegration:restorePanelZoomMenu()
    if self._original_genPanelZoomMenu and self.ui.highlight then self.ui.highlight.genPanelZoomMenu = self._original_genPanelZoomMenu; self._original_genPanelZoomMenu = nil end
end

function PanelZoomIntegration:changePage(diff)
    if self.ui.paging and self.ui.paging.onGotoViewRel then
        self.ui.paging:onGotoViewRel(diff)
    else
        UIManager:sendEvent({ key = diff > 0 and "Right" or "Left", modifiers = {} })
    end
        
    UIManager:scheduleIn(0.3, function()
        local new_page = self:getSafePageNumber()
        self.last_page_seen = new_page
        self:cleanupPreloadedImage()
        self:importAndAnalyzePanels()
        
        if #self.current_panels > 0 then
            self.current_panel_index = diff > 0 and 1 or #self.current_panels
            self:displayCurrentPanel()
        else
            if self._current_imgviewer then UIManager:close(self._current_imgviewer); self._current_imgviewer = nil end
            UIManager:show(InfoMessage:new{ text = _("No panels on this page"), timeout = 1 })
        end
    end)
end

-- Función robusta para obtener el número de página actual
function PanelZoomIntegration:getSafePageNumber()
    if self.ui.paging and self.ui.paging.getPage then return self.ui.paging:getPage() end
    if self.ui.paging and self.ui.paging.cur_page then return self.ui.paging.cur_page end
    if self.ui.document and self.ui.document.current_page then return self.ui.document.current_page end
    if self.ui.view and self.ui.view.state and self.ui.view.state.page then return self.ui.view.state.page end
    return 1
end

return PanelZoomIntegration

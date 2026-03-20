--[[
PanelViewer - Visor de Imagen Personalizado para Paneles

Este widget es un visor de imágenes construido desde cero para la navegación
específica por paneles de cómic. Se encarga de renderizar el panel,
manejar los gestos de toque (tap) y asegurar que la experiencia sea fluida
en dispositivos de tinta electrónica (E-Ink).

Inspirado por las APIs de renderizado modernas, proporciona un control
más fino sobre el posicionamiento, el escalado y las transiciones.
]]

-- Dependencias de KOReader
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

-- Utilidades
local logger = require("logger")
local _ = require("gettext")

-- ===================================================================
-- CLASE: PanelViewer
-- Un contenedor de entrada que muestra una imagen a pantalla completa
-- y responde a los toques para la navegación.
-- ===================================================================
local PanelViewer = InputContainer:extend{
    -- --- PROPIEDADES ---
    name = "PanelViewer",
    image = nil,                 -- La imagen del panel (un BlitBuffer) a mostrar
    fullscreen = true,           -- Siempre se muestra a pantalla completa
    reading_direction = "ltr", -- Sentido de lectura actual
    custom_position = nil,       -- Posición personalizada para el centrado inteligente

    -- --- CALLBACKS (Funciones de llamada) ---
    -- Estas funciones son asignadas desde main.lua para conectar la UI con la lógica
    onNext = nil,
    onPrev = nil,
    onClose = nil,
    
    -- --- ESTADO INTERNO ---
    _image_bb = nil,             -- Buffer de la imagen original
    _display_rect = nil,         -- Rectángulo donde se dibujará la imagen en pantalla
}

--
-- FUNCIÓN: init()
-- Se ejecuta al crear una nueva instancia de PanelViewer.
--
function PanelViewer:init()
    -- 1. Configura las zonas de la pantalla que responderán a los toques
    self:setupTouchZones()
    -- 2. Carga y procesa la imagen del panel
    self:loadImage()
    -- 3. Calcula dónde y de qué tamaño se va a dibujar la imagen
    self:calculateDisplayRect()
end

--
-- FUNCIÓN: setupTouchZones()
-- Define las áreas en la pantalla para avanzar, retroceder o cerrar.
--
function PanelViewer:setupTouchZones()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    
    -- Creamos un único gestor de eventos para "Tap" que cubre toda la pantalla.
    -- La lógica para decidir qué hacer (avanzar/retroceder/cerrar) se encuentra en onTap().
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
-- FUNCIÓN: loadImage()
-- Carga la imagen desde el BlitBuffer proporcionado por main.lua.
--
function PanelViewer:loadImage()
    if not self.image then
        logger.warn("PanelViewer: No se ha proporcionado una imagen.")
        return false
    end
    self._image_bb = self.image
    return true
end

--
-- FUNCIÓN: calculateDisplayRect()
-- Calcula el rectángulo de destino para la imagen del panel en la pantalla.
-- Utiliza la `custom_position` para el centrado inteligente.
--
function PanelViewer:calculateDisplayRect()
    if not self._image_bb then return end

    -- Si main.lua nos ha pasado una posición personalizada, la usamos.
    -- Esto es clave para el "center-lock", que mantiene la estabilidad visual.
    if self.custom_position then
        self._display_rect = {
            x = self.custom_position.x,
            y = self.custom_position.y,
            w = self._image_bb:getWidth(),
            h = self._image_bb:getHeight()
        }
    else
        -- Si no, simplemente centramos la imagen en la pantalla (fallback).
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
-- FUNCIÓN: onTap(_, ges)
-- Manejador de eventos de toque. Decide si avanzar, retroceder o cerrar.
--
function PanelViewer:onTap(_, ges)
    if not ges or not ges.pos then return false end
    
    -- Calculamos en qué porcentaje de la pantalla (horizontalmente) se ha tocado.
    local x_pct = ges.pos.x / Screen:getWidth()
    
    -- La lógica de las zonas de toque depende del sentido de lectura.
    local is_rtl = self.reading_direction == "rtl"
    local next_zone, prev_zone = 0.7, 0.3 -- Zonas para LTR (cómics occidentales)
    if is_rtl then
        next_zone, prev_zone = 0.3, 0.7 -- Zonas invertidas para RTL (manga)
    end
    
    if x_pct > next_zone then
        if self.onNext then self.onNext() end
    elseif x_pct < prev_zone then
        if self.onPrev then self.onPrev() end
    else
        -- Si se toca en el centro, se cierra el visor.
        if self.onClose then self.onClose() end
    end
    
    return true
end

--
-- FUNCIÓN: paintTo(bb, x, y)
-- La función de dibujado principal del widget. Se llama cada vez que KOReader
-- necesita refrescar la pantalla.
--
function PanelViewer:paintTo(bb, x, y)
    if not self._image_bb or not self._display_rect then return end
    
    -- Primero, pintamos todo el fondo de blanco para limpiar la pantalla anterior.
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    bb:paintRect(0, 0, screen_w, screen_h, Blitbuffer.Color8(255))

    -- Dibujamos la imagen del panel en la posición calculada.
    -- Es importante usar "ditherblitFrom" en pantallas E-Ink para mejorar la
    -- calidad de la imagen y reducir el "banding".
    if Screen.sw_dithering then
        bb:ditherblitFrom(self._image_bb, self._display_rect.x, self._display_rect.y, 0, 0, self._display_rect.w, self._display_rect.h)
    else
        bb:blitFrom(self._image_bb, self._display_rect.x, self._display_rect.y, 0, 0, self._display_rect.w, self._display_rect.h)
    end
end


-- ===================================================================
-- FUNCIONES DE ACTUALIZACIÓN
-- ===================================================================

--
-- FUNCIÓN: updateImage(new_image)
-- Permite a main.lua cambiar la imagen del panel (por ejemplo, al mostrar un panel precargado).
--
function PanelViewer:updateImage(new_image)
    self.image = new_image
    self:loadImage()
    self:calculateDisplayRect()
end

--
-- FUNCIÓN: updateCustomPosition(custom_position)
-- Permite a main.lua actualizar la posición de centrado.
--
function PanelViewer:updateCustomPosition(custom_position)
    self.custom_position = custom_position
    self:calculateDisplayRect()
end

--
-- FUNCIÓN: update()
-- Provoca un repintado de la pantalla.
--
function PanelViewer:update()
    UIManager:setDirty(self, "ui")
end

-- ===================================================================
-- FUNCIONES DE GESTIÓN DEL WIDGET
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

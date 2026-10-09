# KOReader Dynamic Panel Zoom

A KOReader plugin that automatically detects and displays comic and manga panels one by one for a seamless reading experience on E-Ink devices. 

No pre-processing, external scripts, or JSON files required—it analyzes the page on the fly.

<p align="center">
  <img src="https://github.com/user-attachments/assets/839285a6-00c0-4308-82cb-ba637a2e0284" width="300" alt="Demo GIF showing Dynamic Panel Zoom in action" style="border: 5px solid #ccc; border-radius: 4px;">
</p>

## Features
- **🤖 Real-time Detection:** Analyzes pages instantly using gutter-based (XY-cut) detection, with a connected-components fallback. Handles touching panels, tinted/noisy paper and dark gutters, and orders panels correctly for tall-next-to-stacked layouts.
- **📖 Focused View:** Centers each panel and masks adjacent content to reduce distractions.
- **⚡ Smart Pre-loading:** Renders the next panel in the background for zero-lag transitions.
- **🔄 Reading Direction:** Supports Left-to-Right (Western) and Right-to-Left (Manga).
- **🔍 Hold-to-Zoom Mode:** Long-press on any panel to instantly enter a free-zoom state with smart text padding to read cut-off speech bubbles or admire wide landscape art.

## Installation
1. Download the latest `dynamic_panelzoom.koplugin.zip` from [Releases](https://github.com/JorgeTheFox/koreader-dynamic-panelzoom/releases).
2. Unzip and copy the `dynamic_panelzoom.koplugin` folder to your KOReader's `plugins/` directory.
3. Restart KOReader.

## Usage
1. Open a comic (`.cbz`, `.pdf`, etc.) in "full page mode": fit = full and view mode = page (see the gif above).
2. Go to the top menu, tap on the document tab and check **Allow panel zoom**.
3. Select **Reading direction**:
   - **Left-to-Right (LTR)** for Western comics
   - **Right-to-Left (RTL)** for Manga/Eastern comics
4. **Standard panel settings** (Optional):
   - **Show adjacent page content:** Toggle whether parts of the page outside the current panel are masked or visible.
   - **Padding around panel:** Adds a margin (`0%` to `10%`) around the detected panel for the standard panel view.
5. **Hold-to-Zoom settings** (Optional):
   - **Hold-to-Zoom padding:** Adds a safe margin (`2%` to `20%`) around the detected panel to capture overlapping speech bubbles when long-pressing.
   - **Initial zoom level:** Choose how the zoom mode starts (`1.0x Fit` to `2.0x Heavy Zoom`).
6. **Navigation:**
   - Long-press on a panel to enable panel view.
   - Tap the **edges** of the screen to move between panels or pages.
   - **Hold (Long-press)** anywhere while viewing a panel to trigger the **Free Zoom Mode**.
   - Tap the **center** to exit panel view.

## Pre-computed panels (optional)
If the automatic detection is not good enough for a comic, you can give the plugin the panels yourself. Put a JSON file with the **same name as the comic** next to it (`my_comic.cbz` -> `my_comic.json`). Pages found in the file take priority over detection; pages missing from it still use detection. Toggle in the panel zoom menu: *Experimental features -> Use panel JSON file when available*.

Two formats are accepted:
- **[panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin) / `process_manga.py`** (normalized 0..1 coordinates):
  ```json
  {"reading_direction": "rtl", "pages": [{"page": 1, "panels": [{"x": 0.1, "y": 0.05, "w": 0.8, "h": 0.4}]}]}
  ```
- **[Kumiko](https://github.com/njean42/kumiko) native output** (pixels; the page number is the position in the list).

Panels are shown in the order they appear in the file.

### Visual editor
[tools/panel_editor.html](tools/panel_editor.html) creates and corrects these JSON files without any command line. Open it in a browser (double click; it runs fully offline, nothing is uploaded and no install is needed; keep `panel_detector.js` next to it).
1. Open the `.cbz` (or a set of images / a folder) and click **Detectar todas**: panels are pre-detected with the same algorithm the plugin uses.
2. Fix what is wrong: drag a panel to move it, drag the handles to resize, drag on empty space to draw a new one, `Delete` removes the selected one. Reading order is the number on each panel (*Antes/Depois*, *Ordem automática* or *Definir ordem* and click the panels one by one). `Ctrl+Z` undoes.
3. **Exportar JSON** and copy `<comic name>.json` next to the comic on your device. Progress is saved in the browser, and *Importar JSON* reloads an existing file (this plugin's format or Kumiko's) for further editing.

`tools/panel_detector.js` is a JavaScript port of `panel_detector.lua`; keep both in sync when changing the detection.

## Known Issues
- **Full page mode Only:** If you use the plugin without full page view, you may see some repeated panels.

- *Tested primarily on Linux (Native/AppImage) and Kindle Colorsoft (2025).*

## Credits & License
Inspired by Kaito0's [panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin), but built from scratch to use on-the-fly detection via Leptonica instead of pre-generated JSON files.

Licensed under the MIT License.

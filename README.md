# KOReader Dynamic Panel Zoom

A KOReader plugin that automatically detects and displays comic and manga panels one by one for a seamless reading experience on E-Ink devices. 

No pre-processing, external scripts, or JSON files required—it analyzes the page on the fly.



## Features
- **🤖 Real-time Detection:** Analyzes pages instantly using KOReader's native engine.
- **📖 Focused View:** Centers each panel and masks adjacent content to reduce distractions.
- **⚡ Smart Pre-loading:** Renders the next panel in the background for zero-lag transitions.
- **🔄 Reading Direction:** Supports Left-to-Right (Western) and Right-to-Left (Manga).

## Installation
1. Download the latest `dynamic_panelzoom.koplugin.zip` from [Releases](https://github.com/JorgeTheFox/koreader-dynamic-panelzoom/releases).
2. Unzip and copy the `dynamic_panelzoom.koplugin` folder to your KOReader's `plugins/` directory.
3. Restart KOReader.

## Usage
1. Open a comic (`.cbz`, `.pdf`, etc.) in **full-screen mode** (fit = full and view mode = page).
2. Check **Allow panel zoom**
3. Select **Reading direction**:
   - **Left-to-Right (LTR)** for Western comics
   - **Right-to-Left (RTL)** for Manga/Eastern comics
4. **Navigation:**
   - Long press to enable panel view
   - Tap the **edges** of the screen to move between panels or pages
   - Tap the **center** to exit

## Known Issues
- **Fullscreen Only:** KOReader UI bars must be hidden when activating Panel Zoom, or coordinate detection may fail.

- *Tested primarily on Linux (Native/AppImage) and Kindle Colorsoft (2025).*

## Credits & License
Inspired by Kaito0's [panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin), but built from scratch to use on-the-fly detection via Leptonica instead of pre-generated JSON files.

Licensed under the MIT License.
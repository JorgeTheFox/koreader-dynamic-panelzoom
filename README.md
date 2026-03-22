# KOReader Dynamic Panel Zoom

A KOReader plugin that automatically detects and displays comic and manga panels one by one for a seamless reading experience on E-Ink devices. 

No pre-processing, external scripts, or JSON files required—it analyzes the page on the fly.

## Features
- **🤖 Real-time Detection:** Analyzes pages instantly using KOReader's native engine.
- **📖 Focused View:** Centers each panel and masks adjacent content to reduce distractions.
- **⚡ Smart Pre-loading:** Renders the next panel in the background for zero-lag transitions.
- **🔄 Reading Direction:** Supports Left-to-Right (Western) and Right-to-Left (Manga).
- **🔍 Hold-to-Zoom Mode:** Long-press on any panel to instantly enter a free-zoom state with smart text padding to read cut-off speech bubbles or admire wide landscape art.

<p align="center">
  <img src="https://github.com/user-attachments/assets/839285a6-00c0-4308-82cb-ba637a2e0284" width="400" alt="Demo GIF showing Dynamic Panel Zoom in action" style="border: 2px solid #ccc; border-radius: 4px;">
</p>

## Installation
1. Download the latest `dynamic_panelzoom.koplugin.zip` from [Releases](https://github.com/JorgeTheFox/koreader-dynamic-panelzoom/releases).
2. Unzip and copy the `dynamic_panelzoom.koplugin` folder to your KOReader's `plugins/` directory.
3. Restart KOReader.

## Usage
1. Open a comic (`.cbz`, `.pdf`, etc.) in **full-screen mode** (fit = full and view mode = page).
2. Go to the bottom menu, tap on the **Highlight** tab (pen icon) and check **Allow panel zoom**.
3. Select **Reading direction**:
   - **Left-to-Right (LTR)** for Western comics
   - **Right-to-Left (RTL)** for Manga/Eastern comics
4. **Hold-to-Zoom settings** (Optional):
   - **Padding around panel:** Adds a safe margin (`2%` to `20%`) around the detected panel to capture overlapping speech bubbles.
   - **Initial zoom level:** Choose how the zoom mode starts (`1.0x Fit` to `2.0x Heavy Zoom`).
5. **Navigation:**
   - Double tap or long-press on a panel to enable panel view.
   - Tap the **edges** of the screen to move between panels or pages.
   - **Hold (Long-press)** anywhere while viewing a panel to trigger the **Free Zoom Mode**.
   - Tap the **center** to exit panel view.

## Known Issues
- **Fullscreen Only:** KOReader UI bars must be hidden when activating Panel Zoom, or coordinate detection may fail.

- *Tested primarily on Linux (Native/AppImage) and Kindle Colorsoft (2025).*

## Credits & License
Inspired by Kaito0's [panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin), but built from scratch to use on-the-fly detection via Leptonica instead of pre-generated JSON files.

Licensed under the MIT License.
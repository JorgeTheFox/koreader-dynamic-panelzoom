# KOReader Dynamic Panel Zoom

**A KOReader plugin for an enhanced comic and manga reading experience with automatic, on-the-fly panel detection.**

This plugin intelligently analyzes the current page of a CBZ, PDF, or other comic book format in [KOReader](https://github.com/koreader/koreader) and detects the individual panels. It then displays them one-by-one in a clean, focused viewer, allowing for a smooth, guided reading experience without needing any pre-generated JSON or metadata files.

It's designed to "just work" and is especially useful for reading digital comics on E-Ink devices, where traditional pinch-and-zoom can be slow and cumbersome.

![Dynamic Panel Zoom in Action (Conceptual)](https://raw.githubusercontent.com/koreader/koreader/master/data/splash/splash-koreader.png)
*(Image: KOReader Logo - a placeholder to be replaced with a real screenshot/GIF)*

## Features

-   **Automatic Panel Detection:** No need for external scripts or files. The plugin analyzes the page you're on in real-time.
-   **Focused Panel View:** Each panel is cropped and centered on the screen, removing distractions.
-   **Smooth Navigation:** Tap the left/right side of the screen to move between panels or jump to the next/previous page.
-   **Reading Direction Control:** Easily switch between Left-to-Right (LTR) for western comics and Right-to-Left (RTL) for manga.
-   **Smart Pre-loading:** The next panel is rendered in the background for near-instant transitions.
-   **Center-Lock Viewing:** The viewer intelligently positions each panel to keep the focal point stable, reducing eye strain.
-   **Adjustable Offsets:** Fine-tune the horizontal position of panels to your liking.
-   **Full Integration:** Adds its options directly into KOReader's existing "Panel zoom" menu for a seamless experience.

## Requirements

-   **KOReader** (Latest stable release recommended)
-   **PanelViewer:** This plugin utilizes the `PanelViewer` widget structure, which is included within this repository but relies on KOReader's core UI components.

*Disclaimer: This plugin has currently only been tested on the Linux version of KOReader (AppImage/Native) and on the Kindle Colorsoft (2025). Performance and compatibility on other platforms (Android, Kobo, PocketBook, etc.) are not guaranteed.*

## Installation

1.  [Download the latest release](https://github.com/JorgeTheFox/koreader-dynamic-panelzoom/releases) (the `dynamic_panelzoom.koplugin.zip` file).
2.  Unzip the file. You should now have a folder named `dynamic_panelzoom.koplugin`.
3.  Copy this `dynamic_panelzoom.koplugin` folder into your KOReader's `plugins` directory. The path is typically `koreader/plugins/`.
4.  Restart KOReader. The plugin will be loaded automatically.

## How to Use

1.  Open any comic book (e.g., a `.cbz` file) in KOReader.
2.  Long-press on the screen to bring up the main menu.
3.  Tap the "Panel zoom" icon in the bottom menu. This will trigger the dynamic panel detection.
4.  The first detected panel will be displayed.
    -   Tap the **right side** of the screen to move to the next panel (for LTR comics).
    -   Tap the **left side** of the screen to move to the previous panel.
    -   **Tap the center of the screen to exit the panel viewer and return to the normal page view.**
5.  At the end of a page, it will automatically turn to the next page and continue in panel view.

### Changing Reading Direction

If you are reading manga, you will want to set the reading order to Right-to-Left (RTL).

1.  Long-press on the screen to open the menu.
2.  Go to the "Panel zoom" menu (usually under the gear icon or layout settings).
3.  Select **Reading Direction** > **Right-to-Left (RTL)**.

The tap zones will automatically adjust. In RTL mode, the left side of the screen advances to the next panel.

## Known Issues & Limitations

-   **Fullscreen Requirement:** The plugin currently only works correctly if you are viewing the comic in full-screen mode (without UI bars showing). If KOReader's UI menus or status bars are visible when activating Panel Zoom, the coordinate calculations may fail or behave erratically.

-   **E-ink Flickering on Preload Transition:** When advancing through preloaded panels, there may be unnecessary UI flickering due to sequential update calls instead of batched redrawing (see [#2](https://github.com/JorgeTheFox/koreader-dynamic-panelzoom/issues/2)).

## Technical Approach & Acknowledgements

This plugin was inspired by the idea behind [panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin) by Kaito0. However, the technical approach is completely different.

-   **Kaito0's plugin** relies on external preprocessing (likely machine learning-based) to generate a JSON file with panel coordinates for every single comic. This can be very accurate for complex layouts, but requires significant setup and external processing power.
-   **Dynamic Panel Zoom** is fully self-contained. It leverages the built-in image processing capabilities of KOReader (specifically the Leptonica library, similarly to how KOReader's native "Panel zoom" feature detects bounding boxes). This means no external JSON files, no preprocessing on a PC, and zero setup for the user. While it might occasionally struggle with extremely chaotic layouts, it offers a much more convenient, "plug-and-play" experience for the vast majority of comics and manga.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

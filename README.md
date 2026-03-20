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

## Installation

1.  [Download the latest release](https://github.com/jefe/koreader-dynamic-panelzoom/releases) (the `dynamic_panelzoom.koplugin.zip` file).
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
    -   Tap the **center** of the screen to exit the panel viewer.
5.  At the end of a page, it will automatically turn to the next page and continue in panel view.

### Changing Reading Direction

If you are reading manga, you will want to set the reading order to Right-to-Left (RTL).

1.  Long-press on the screen to open the menu.
2.  Go to the "Panel zoom" menu (usually under the gear icon or layout settings).
3.  Select **Reading Direction** > **Right-to-Left (RTL)**.

The tap zones will automatically adjust. In RTL mode, the left side of the screen advances to the next panel.

## Acknowledgements

This plugin was heavily inspired by and based on the initial work of [Kaito0](https://github.com/Kaito0) and their [panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin). This version refactors the core logic into a self-contained, real-time analysis engine that does not require external JSON files.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

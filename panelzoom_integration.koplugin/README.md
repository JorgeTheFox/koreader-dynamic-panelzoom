# PanelReader for KOReader

KOReader-native Guided View, adapted for:

* Open formats

* E-ink 

* Performance

## Available detection algorithms:

* Kumiko - opencv, cpu - fast, simple layouts
* YOLO - min 1050 ti 4gb - CUDA*
* MAGI - min 1050 ti 4gb - CUDA* 

NVIDIA Driver: Version 530+ (for CUDA 12 support).
CUDA Toolkit: 11.8 for older cards like the 1050 Ti

## Required KOReader Settings

To ensure the plugin works correctly, apply the following settings:

* **Zoom:** Fit full page
* **Page Crop:** none

## Installation

### 1. Plugin Setup

* Download the plugin and place the panelzoom_integration.koplugin into the KOReader `plugins/` directory.

### 2. Linux Setup (Kumiko Helper)

To process manga files on Linux, install the necessary dependencies and the Kumiko (fork):

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install python3 python3-pip python3-opencv git

# Arch Linux
sudo pacman -S python python-pip python-opencv git

# Clone and Setup
git clone https://github.com/guilherme5ss/quadrinhos.git
cd quadrinhos
chmod +x kumiko

```

### 3. Windows Setup (Kumiko Helper)

1. **Install Python:** Download the latest version from [python.org](https://www.python.org/). Ensure **Add Python to PATH** is checked during installation.
2. **Install Git:** Download and install from [git-scm.com](https://git-scm.com/).
3. **Install Dependencies:** Open Command Prompt or PowerShell and run:
```bash
pip install opencv-python Pillow requests

```


4. **Clone Repository:**
```bash
git clone https://github.com/guilherme5ss/quadrinhos.git
cd quadrinhos

```



---

## Processing Manga

The plugin requires a JSON file containing panel coordinates. The `process_manga.py` script uses **Kumiko** for detection and **Pillow** for coordinate normalization.

**Execution:**

```bash
# Windows
python process_manga.py "C:\path\to\manga.cbz" 

# Linux
python process_manga.py /path/to/manga.cbz

```

**Workflow:**

1. Extracts the archive (CBZ/CBR).
2. Uses Kumiko to detect panel boundaries in pixels.
3. Uses Pillow to get page dimensions and normalize coordinates to a 0.0–1.0 scale.
4. Generates a matching `.json` file in panel_result folder

---

## Navigation and Controls

1. **Enable Integration:** `Tools → MoreTools → Panel Zoom Integration`.
2. **Enter Panel Mode:** Long-press anywhere on the page.
3. **Navigate:** Use the following tap zones:

| Zone | Action | LTR (Western) | RTL (Manga) |
| --- | --- | --- | --- |
| **Left 30%** | Backward | Previous Panel | Next Panel |
| **Right 30%** | Forward | Next Panel | Previous Panel |
| **Center 40%** | **Exit** | Close Viewer | Close Viewer |

Reaching the last panel of a page and tapping forward will automatically transition to the first panel of the next page.

---

## JSON Data Structure

The JSON file must be named identically to the manga file (e.g., `manga.cbz` and `manga.json`).

```json
{
  "reading_direction": "rtl",
  "total_pages": 2,
  "pages": [
    {
      "page": 1,
      "panels": [
        {"x": 0.084, "y": 0.0, "w": 0.857, "h": 0.322},
        {"x": 0.299, "y": 0.3, "w": 0.280, "h": 0.322}
      ]
    }
  ]
}

```

* **Coordinates:** `x, y, w, h` are normalized values (0.0 to 1.0) relative to the page size.

---

## Troubleshooting

* **ImportError (PIL/Pillow):** Ensure you ran `pip install Pillow`.
* **No Panels Found:** Ensure the JSON file is in the same directory as the manga and the filenames match exactly.
* **Import Errors (cv2):** Re-run the dependency installation commands for `opencv-python`.

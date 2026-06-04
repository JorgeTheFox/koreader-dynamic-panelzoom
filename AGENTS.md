# OpenCode Agent Instructions

This repository contains a KOReader plugin written in Lua.

## Architecture & Code Boundaries
- **Plugin Source**: All plugin code lives in `dynamic_panelzoom.koplugin/`.
- **Entrypoints**: `main.lua` is the KOReader integration layer; `panel_viewer.lua` handles the panel UI/rendering logic.
- **Dependency context**: The code runs inside the KOReader environment and uses its internal Lua UI modules (`ui/widget/...`, `device`, etc.) and Leptonica for on-the-fly panel detection.
- **Directory strictness**: Do not change the internal structure of `dynamic_panelzoom.koplugin/`. End users drop this exact directory into their KOReader `plugins/` folder, and the automated release workflow (`.github/workflows/release.yml`) packages it verbatim.

## Testing & Verification
All testing happens via a localized KOReader AppImage environment. 

### Prerequisites for testing
1. The KOReader AppImage must be extracted to `local_resources/koreader-test-env/squashfs-root/`. (Command: `./koreader.AppImage --appimage-extract` inside the env folder).
2. At least one `.cbz`, `.cbr`, or `.pdf` must exist in `local_resources/comics/`.
3. Automated tests require `xvfb`, `xdotool`, and `scrot`.

### Manual Testing
- Run `./local_resources/run_test.sh`
- This script automatically copies the current plugin code into the `squashfs-root` environment and launches KOReader with a random comic from `local_resources/comics/`. 

### Automated Functional Tests
The test orchestrator (`./local_resources/tests/run_tests.sh`) can be parameterized via arguments and environment variables:
- **Run specific suites**: Pass names as arguments (e.g., `./local_resources/tests/run_tests.sh detection navigation`). Available suites: `smoke`, `detection`, `navigation`, `settings`.
- **Run a single test**: Use `REQUESTED_TEST` (e.g., `REQUESTED_TEST="T04" ./local_resources/tests/run_tests.sh detection`).
- **Visual Debugging**: Tests run headless via Xvfb by default (`HEADLESS=1`). Set `HEADLESS=0` to run visibly on the real screen, which is highly recommended for diagnosing failures. Example: `HEADLESS=0 REQUESTED_TEST="T04" TAP_DELAY=3.0 ./local_resources/tests/run_tests.sh detection`
- **Adjusting Timing/Timeouts**: Modify delays and timeouts if the environment is slow or to stress-test the UI:
  - **Delays**: `TAP_DELAY` (default 1.0/2.0), `BOUNDARY_TAP_DELAY`, `DEBOUNCE_TAP_DELAY`, `POST_ACTION_DELAY`.
  - **Timeouts**: `WAIT_INIT_TIMEOUT` (default 25s), `WAIT_TAP_TIMEOUT`, `WAIT_PAGE_CHANGE_TIMEOUT`, `WAIT_PANEL_ANALYSIS_TIMEOUT`.
  - **Limits**: `MAX_BOUNDARY_TAPS`, `MAX_BOUNDARY_TAPS_DETECTION`.
  - **Example (slow VM)**: `WAIT_INIT_TIMEOUT=60 WAIT_PAGE_CHANGE_TIMEOUT=30 ./local_resources/tests/run_tests.sh`
- **Artifacts**: Test results, KOReader logs, and scrot screenshots are output to `local_resources/tests/results/latest/`. Always check these logs if a test fails.

## Open Source Workflow & Standards
To maintain consistency with standard Open Source practices, all automated actions and agent behaviors must adhere to the following rules:

### 1. Branching Strategy
- **Do not commit directly to `master`** unless explicitly requested.
- Create descriptive branches based on the task:
  - **Features**: `feature/<short-description>` or `feature/issue-<number>-<short-desc>` (e.g., `feature/e-ink-optimization`).
  - **Fixes**: `fix/<short-description>` or `bugfix/<short-description>`.
  - **Chores/Docs**: `chore/<short-description>` or `docs/<short-description>`.

### 2. Commit Conventions
- Use **Conventional Commits** strictly in lowercase for the type.
- Format: `<type>(<optional-scope>): <description in lowercase>`
- Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
- Examples: 
  - `feat(panelzoom): improve E-Ink refresh`
  - `fix: prevent panel 0 flickering on page change`
- If a commit resolves an issue, include a blank line and `Resolves #<number>` in the commit body.

### 3. Pull Requests (PRs)
- PR titles **must** follow the Conventional Commits format. The automated release workflow (`release.yml`) uses `generate_release_notes: true`, which relies on PR titles to generate the public changelog.
- PR descriptions should link to related issues (e.g., `Closes #X` or `Resolves #X`).

### 4. Versioning & Releases
- The project uses **Semantic Versioning** (SemVer: `MAJOR.MINOR.PATCH`).
- Automated releases are triggered via `.github/workflows/release.yml` when a tag starting with `v` is pushed.
- When instructed to bump a version and release:
  1. First, verify the latest version by checking the remote Git tags. Determine the next version number based on the type of changes (feat -> MINOR, fix -> PATCH).
  2. Update the version string in the code (e.g., `_meta.lua` or similar) to the new version.
  3. Create a commit formatted as `chore: bump version to X.Y.Z`.
  4. Create an annotated Git tag: `git tag -a vX.Y.Z -m "Release vX.Y.Z"`.
  5. Push the branch (if applicable, via a PR) and the tag to trigger the GitHub Action.

### 5. Code Comment Style
- **Language**: Strictly English.
- **Focus**: Document the *why* (context, decisions, KOReader API workarounds) rather than the *what*.
- **Structure**: Use `--` for inline/logical groupings, and `--[[ ... ]]` for module headers or large function documentation.
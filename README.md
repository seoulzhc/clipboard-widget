# Clipboard Widget · 剪贴板助手

[![Latest release](https://img.shields.io/github/v/release/seoulzhc/clipboard-widget?sort=semver&display_name=tag)](https://github.com/seoulzhc/clipboard-widget/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**[⬇ Download the latest release](https://github.com/seoulzhc/clipboard-widget/releases/latest)**

A tiny, dependency-free clipboard history panel for Windows. It sits on your desktop as a borderless always-on-top card, records the text you copy, and lets you star the snippets you use most.

![Clipboard Widget](docs/panel.png)

## Features

- **Automatic history** — watches the clipboard and keeps the latest 60 copied texts.
- **Two columns** — *History* on the left, *Favorites* on the right.
- **Star to favorite** — click ☆ on a row and it appears in Favorites; click ★ to remove it.
- **Delete entries** — click ✕ on a row to remove it from the list.
- **Click to copy, double-click to edit** — or use the ✎ button on a row. `Ctrl+Enter` saves, `Esc` cancels.
- **Resize from any corner** — drag a corner to scale the whole card (0.6×–1.6×). Size and position are remembered.
- **Pin / move** — 📌 toggles always-on-top; drag the title bar to move the card.
- **Minimize to the system tray** — the `−` button hides the card and puts an icon in the notification area; click the icon to bring the card back.
- **Local only** — data is a plain JSON file under `%APPDATA%\ClipboardWidget`. No network calls, no telemetry.

## Screenshots

| Panel | System tray |
| --- | --- |
| ![Panel](docs/panel.png) | ![Tray](docs/tray.png) |

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (bundled with Windows)
- No admin rights, no installer, no external modules

## Install

1. Download this repository (Code → Download ZIP) and extract it anywhere, e.g. `C:\Tools\ClipboardWidget`.
2. Double-click **install.cmd** (or run `install.ps1` from PowerShell). It creates a desktop shortcut and a startup shortcut, then starts the widget.
3. To skip the autostart shortcut: `powershell -ExecutionPolicy Bypass -File install.ps1 -NoStartup`

Run once without installing:

```powershell
powershell -Sta -NoProfile -ExecutionPolicy Bypass -File .\clipboard-widget.ps1
```

## Usage

| Action | How |
| --- | --- |
| Copy an item again | Single click |
| Edit an item | Double-click the row, or click ✎ |
| Favorite / unfavorite | ☆ / ★ on the row |
| Delete an entry | ✕ on the row |
| Resize | Drag any of the four corners |
| Move | Drag the title bar |
| Always on top | 📌 |
| Minimize to tray | `−` |
| Restore from tray | Left-click or double-click the tray icon |
| Quit | ✕, or tray menu → Exit |

## Data & privacy

- History and favorites are stored in `%APPDATA%\ClipboardWidget\data.json` as plain text (max 60 history entries, 200 favorites).
- Only text is read from the clipboard; images and files are ignored.
- Nothing is uploaded anywhere. If you copy passwords, remove those entries or clear the file.

## Uninstall

- Run **uninstall.cmd** — removes the shortcuts and `%APPDATA%\ClipboardWidget`.
- Or delete the folder and the two shortcuts manually.

## Notes and limitations

- On Windows 11 the tray icon may first appear in the overflow menu (`^`). Drag it onto the taskbar once to pin it.
- Editing changes the stored entry only; it does not touch the current clipboard.
- The card is always-on-top by default; use 📌 to let it stay behind other windows.
- Text only — no image or file history.

## License

MIT — see [LICENSE](LICENSE).

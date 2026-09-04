# Helium Workspace Archive

Capture every open Helium tab across Windows virtual desktops and browse the resulting screenshots in a local, browser-like viewer.

The generated viewer reproduces the desktop, window, and tab hierarchy. It supports virtual desktop switching, window selection, browser-style tabs, global search, Task View, zoom, fullscreen, and keyboard navigation.

## Requirements

- Windows 10 or Windows 11
- Helium browser
- Windows PowerShell 5.1
- The PowerShell `VirtualDesktop` module
- GNU Make, if using the Makefile commands
- Tab Freezer installed in Helium if captured windows should be frozen afterward

Install the required PowerShell module for the current user:

```powershell
Install-Module VirtualDesktop -Scope CurrentUser
```

## Run Everything

Open a terminal in this directory and run:

```powershell
make all
```

This runs the capture and then generates `index.html` from `tabs.md`.

Open the finished viewer:

```powershell
make open
```

`index.html` can also be opened directly. It does not require a local web server.

## Make Targets

| Command | Purpose |
| --- | --- |
| `make all` | Capture every Helium tab and generate the viewer |
| `make capture` | Run the capture only |
| `make capture HWND=67934` | Capture only one Helium window for testing |
| `make index` | Rebuild `index.html` from the existing `tabs.md` |
| `make open` | Generate and open the viewer |
| `make check` | Check required scripts and the `VirtualDesktop` module |
| `make help` | List available targets |

## Run Without Make

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\capture.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-index.ps1
Start-Process .\index.html
```

To generate a viewer from another Markdown file:

```powershell
.\build-index.ps1 -InputPath .\tabs.md -OutputPath .\index.html
```

## Generated Files

- `tabs.md`: readable hierarchy of desktops, windows, and tabs
- `tabs.csv`: detailed capture metadata
- `screenshots/`: one JPEG for every captured tab
- `index.html`: generated interactive viewer with embedded metadata

`index.template.html` is the viewer template. `build-index.ps1` parses the Markdown and embeds its data into a copy of that template.

## Capture Behavior

During capture, `capture.ps1`:

1. Finds Helium windows on every virtual desktop.
2. Switches desktops and brings each window to the foreground.
3. Selects every tab and records its title and URL.
4. Pauses playing Helium media through the Windows media session API.
5. Saves a screenshot for each tab.
6. Restores the selected tab and clicks the Tab Freezer extension.
7. Attempts to restore the original desktop and foreground window.

Avoid using the mouse or keyboard until capture finishes. The process can take a while for large sessions.

## Privacy

The archive contains tab titles, URLs, and full screenshots. Review it before sharing or publishing. Everything remains local unless you move or upload the generated files.

## Keyboard Shortcuts

- `Ctrl+K`: search all captured tabs
- `Alt+Left`: previous tab
- `Alt+Right`: next tab
- `Ctrl+Tab`: next tab
- `Ctrl+Shift+Tab`: previous tab
- `Escape`: close search or the mobile window drawer

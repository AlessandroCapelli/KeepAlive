# KeepAlive

A small Windows utility to keep the PC awake, monitor Wi-Fi, or append
`424242...` to a TXT file in the background, one character per second.

## Getting started

Requires **Windows** and **PowerShell 5.1 or later**. No installation needed.

1. Double-click **KeepAlive.cmd**.
2. Choose a mode from the menu.
3. Press **Q** or **Esc** to stop.

## Controls

| Action                        | Control                         |
| ----------------------------- | ------------------------------- |
| Stop a session                | **Q** or **Esc** in the console |
| Stop TXT mode from any window | **Ctrl+Alt+Q**                  |
| Set session duration          | **Settings** (`0` = unlimited)  |
| Restore optimized settings    | Menu option **4**               |

Protected changes require administrator access. Optimization saves the original
Windows settings so they can be restored.

## Local files

| File                   | Purpose                           |
| ---------------------- | --------------------------------- |
| `keepalive.state.json` | Configuration and settings backup |
| `keepalive.txt`        | Generated TXT output              |

Both files are ignored by Git.

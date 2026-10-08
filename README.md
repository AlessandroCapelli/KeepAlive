# KeepAlive

Windows utility to keep the PC awake, monitor Wi-Fi, and generate background
mouse activity. No installation needed.

## Getting started

Requires **Windows** and **PowerShell 5.1 or later**.

1. Double-click **KeepAlive.cmd**.
2. Enter a menu option below.

## Menu

| Option                      | What it does                                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1 — Keep-alive**          | Keeps Windows awake, monitors Wi-Fi, and attempts reconnection when needed.                                                                       |
| **2 — Settings**            | Sets the Wi-Fi profile, check intervals, display behavior, and session duration.                                                                  |
| **3 — Optimize**            | Where supported, disables Wi-Fi power saving and sleep on lid close; sets Wi-Fi as metered to reduce background traffic. Saves original settings. |
| **4 — Restore**             | Restores the Windows settings saved by option 3.                                                                                                  |
| **5 — Diagnostics**         | Shows network and power settings, gateway latency, and Internet reachability.                                                                     |
| **6 — Administrator**       | Restarts KeepAlive with administrator privileges.                                                                                                 |
| **7 — Background activity** | Writes `424242...` to a TXT file once per second and moves the mouse slightly forward/back every 30 seconds while idle.                           |
| **0 — Exit**                | Closes KeepAlive; offers to restore saved settings if present.                                                                                    |

## Settings (option 2)

| Option                        | Values                                             | Default         |
| ----------------------------- | -------------------------------------------------- | --------------- |
| **1 — Wi-Fi profile**         | Automatic or a saved profile                       | Current network |
| **2 — Gateway ping interval** | 5–300 seconds                                      | 20 seconds      |
| **3 — Internet check**        | 0–120 minutes; `0` disables it                     | Disabled        |
| **4 — Keep display on**       | Yes / No, for mode 1                               | No              |
| **5 — Session duration**      | 0–72 hours; `0` means unlimited, for modes 1 and 7 | Unlimited       |
| **0 — Back**                  | Returns to the main menu                           | —               |

Settings are saved automatically.

## Background activity (option 7)

You can minimize the console; no editor window opens. Mouse movement starts
after 30 seconds and waits for at least 30 seconds without keyboard or mouse
input. It pauses while mouse buttons or Shift, Ctrl, Alt, or Windows keys are held.

No keystrokes, clicks, scrolling, or focus changes are generated. Text goes
directly to `keepalive.txt`, even if another window opens or takes focus.
Movement can affect hover behavior or shift the cursor slightly at screen edges.

## Controls

| Action                        | Control                         |
| ----------------------------- | ------------------------------- |
| Stop a session                | **Q** or **Esc** in the console |
| Stop TXT mode from any window | **Ctrl+Alt+Q**                  |
| Set session duration          | **Settings** (`0` = unlimited)  |
| Restore optimized settings    | Menu option **4**               |

Protected changes require administrator access (option **6**).

## Local files

| File                   | Purpose                           |
| ---------------------- | --------------------------------- |
| `keepalive.state.json` | Configuration and settings backup |
| `keepalive.txt`        | Generated TXT output              |

Both files are ignored by Git.

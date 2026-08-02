# LGforMac

A native **SwiftUI/AppKit** macOS app to control the **brightness (OLED Light)** of
LG webOS TVs used as monitors — C2, C3, G-series and friends — over your LAN.
The macOS version of [LGforWin](https://github.com/itsAllexB/LGforWin).

OLED TVs have no DDC/CI hardware brightness, so macOS brightness controls do nothing
for them. The only real "brightness" is the TV's **OLED Light (backlight)** picture
setting. LGforMac drives that setting over the network — from a window, the **menu
bar**, or global hotkeys.

## Features

Full feature parity with LGforWin v2.1, plus a menu bar home:

- **Menu bar app** — a slider and power button for every TV, one click away. Closing
  the window keeps LGforMac running in the menu bar.
- **Find TVs automatically** — one click scans the LAN over SSDP and lists every webOS
  TV. Adding by IP still works.
- **Pair once** — accept the on-screen prompt one time; the stored client-key
  reconnects silently forever after. Secure `wss://:3001` with automatic fallback to
  `ws://:3000`.
- Per-TV **OLED Light slider (0–100)** that pushes changes live (debounced).
- **Global hotkeys** (default ⌃⌥ + ↑/↓, customizable) that adjust the TV on the screen
  your **cursor** is on — pair each TV to the display it drives. 1–25 points per press.
- **On-screen display** — two styles: a native **macOS pop-up** that drops in below the
  menu bar exactly like the system volume/brightness HUD — rendered in real **Liquid
  Glass** (`NSGlassEffectView`) on macOS 26+, frosted material on older systems — or the
  classic **Windows-style pill** with six anchor positions. Both honor the screen mode,
  duration and optional TV name settings.
- **Schedules** — up to 10 daily brightness rules, with catch-up after Mac sleep, on
  startup, and for TVs that were off when a rule fired (applied the moment they're back).
- **Power automation** — turn the TVs on/off with the Mac: at app start, on wake, on
  sleep, on shutdown/log-out, and following the display-sleep timer (blank the panel
  for instant resume, or power off fully). Waking uses Wake-on-LAN.
- **Launch at login** (normal window / minimized / menu bar only).
- **Import / export** all settings as one JSON file — **LGforWin backups import
  directly**, pairing keys included.
- Light / dark / system theme; remembers TVs, their last brightness, window size.

## Requirements

- macOS 14 (Sonoma) or newer.
- The TV and Mac on the same network, with the TV's network/mobile control enabled
  (LG Connect Apps — on by default on recent models).
- For the turn-on rules: **Quick Start+** enabled on the TV (General → Devices →
  External Devices, wording varies) so it answers Wake-on-LAN.

> **Local network permission**: macOS asks once whether LGforMac may access the local
> network — approve it, or every connection fails with an "internet appears offline"
> error (`NSURLErrorDomain -1009`). On recent macOS (26+) the prompt sometimes never
> appears and the app is silently blocked without even being listed under System
> Settings → Privacy & Security → Local Network; LGforMac works around this by
> triggering the permission registration itself (Bonjour/Network.framework probes) when
> it detects the block, and shows a banner with a shortcut to the settings pane.
> Rebuilding changes an ad-hoc-signed app's identity, so a rebuild may re-ask; the
> build script prefers a stable "LGforMac Local Signing" certificate when one exists in
> the keychain to keep the grant across rebuilds.

## Building

```bash
./build.sh                # release build → dist/LGforMac.app
./build.sh debug          # debug build
./build.sh release --run  # build and launch
```

Needs Xcode (or the Command Line Tools with the macOS SDK). The script builds with
SwiftPM, assembles `dist/LGforMac.app`, and ad-hoc signs it.

## Diagnostics CLI

The binary doubles as a protocol test tool:

```bash
.build/release/LGforMac --scan                  # SSDP-discover TVs
.build/release/LGforMac --probe <ip>            # connect, pair, report state
.build/release/LGforMac --set <ip> <0-100>      # set OLED Light
.build/release/LGforMac --raw <ip> <ssap-uri>   # raw SSAP request (paired hosts)
.build/release/LGforMac --osd-preview           # ask the running app to show the OSD
```

A small log is kept at `~/Library/Application Support/LGforMac/log.txt`, next to
`devices.json` and `settings.json`.

## How it works (protocol)

webOS speaks **SSAP over a WebSocket** at `wss://<tv-ip>:3001` (older firmware:
`ws://:3000`):

1. **Pair** — a registration handshake; the TV shows an accept prompt and returns a
   `client-key`, which is persisted and reused.
2. **Set brightness** — the privileged
   `luna://com.webos.settingsservice/setSystemSettings` call (picture → `backlight`),
   routed through the notification-alert API (`createAlert`/`closeAlert`) — the proven
   trick (bscpylgtv, ColorControl) that works on stock, unrooted TVs.
3. **Read current** — `ssap://settings/getSystemSettings` to initialise the slider.
4. **Power** — `ssap://system/turnOff`, `…tvpower/power/turnOffScreen` /
   `turnOnScreen` to blank/restore just the panel, and `…tvpower/power/getPowerState`
   as both status and a 30 s liveness probe (a TV that loses power doesn't close the
   socket).
5. **Wake** — Wake-on-LAN magic packets to the MAC addresses the TV reports over
   `ssap://com.webos.service.connectionmanager/getinfo` (both Wi-Fi and wired, learned
   while connected; ARP is the fallback).

## Project layout

| Path | Purpose |
|------|---------|
| `Sources/LGforMac/Services/WebOSClient.swift` | Low-level SSAP WebSocket: connect, pair, request/response, luna-via-alert |
| `Sources/LGforMac/Services/TvController.swift` | Per-TV lifecycle, auto-reconnect, heartbeat, power, debounced backlight |
| `Sources/LGforMac/Services/SsdpDiscovery.swift` | LAN scan for webOS TVs (SSDP M-SEARCH + UPnP description) |
| `Sources/LGforMac/Services/WakeOnLan.swift` | Magic-packet wake + ARP fallback MAC lookup |
| `Sources/LGforMac/Services/PowerEventService.swift` | macOS sleep / wake / display-sleep / power-off notifications |
| `Sources/LGforMac/Services/HotkeyService.swift` | Global hotkeys via Carbon `RegisterEventHotKey` |
| `Sources/LGforMac/Services/ScreenService.swift` | Display enumeration with stable UUIDs for TV↔screen pairing |
| `Sources/LGforMac/App/` | App state (`AppState`, `TvState`), app/window lifecycle, CLI mode |
| `Sources/LGforMac/UI/` | Main window pages, menu bar popover, OSD overlay panel |

## License

Licensed under the [GNU General Public License v3.0](LICENSE) © Alex Bolocan.

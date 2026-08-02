# LGforMac — TODO

Open items after the initial port (feature parity with LGforWin v2.1 is otherwise in place
and verified against a real C3).

## On-screen display — make the macOS style truly native

The current macOS-style OSD is a real `NSGlassEffectView` capsule below the menu bar
(name row, dotted track, sun icons, full-capsule corners), but it still doesn't pass for
the system volume/brightness pop-up. Known gaps and leads:

- [ ] **Tone/contrast**: the system HUD reads as a darker, luminance-adaptive glass with a
      **white** fill in both appearances; ours follows the app appearance (`.primary`
      content on plain `.regular` glass), so it renders light-on-light on bright wallpapers.
      Leads: BetterDisplay ships "adaptive vs system appearance" glass styles for exactly
      this reason (their adaptive style is size-limited to ~63 px height — suggests a
      constrained system variant). Investigate `NSGlassEffectView` tinting, forced dark
      appearance on the panel, or private glass variants.
- [ ] **Entrance/exit animation**: system HUD's spring/timing differs from our linear
      slide+fade; capture it (screen recording, frame-by-frame) and match.
- [ ] **Exact metrics**: measure the real HUD (width, insets, font, track thickness, dot
      spacing, icon sizes, shadow) from screenshots at 2x and match precisely.
- [ ] **Slider knob**: check whether the system HUD shows a knob/thumb at the fill edge.
- [ ] Consider whether the private `OSDManager`/`OSDUIHelper` path does anything useful on
      macOS 26/27 (in a normal app context it summons the Control Center HUD per
      MonitorControl, but the value bar reportedly doesn't track — retest from the app,
      not a sandboxed CLI, where the XPC lookup was denied).

## Not yet verified on real hardware (implemented, untested)

- [ ] **Wake-on-LAN** end-to-end (needs the TV off; magic packets + retry loop are ported).
- [ ] **Power automation** live: off-on-sleep, off-on-shutdown, display-sleep follow
      (screen off / full off), wake-on-display-wake.
- [ ] **Launch at login** (+ the `--autostart` launch-behavior distinction via the bundled
      launch agent).
- [ ] **Schedules** firing at the minute + sleep-gap catch-up.
- [ ] **Drag-to-reorder** TV cards (SwiftUI `onMove` on macOS).
- [ ] **Import a real LGforWin backup** exported from the Windows app.

## Roadmap carried over from LGforWin's Todo.md (unshipped there too)

- [ ] **Extra picture sliders** — contrast / black level / energy-saving (OLED brightness
      limiter); same luna-call mechanism as backlight.
- [ ] **Sunrise–sunset auto-dim** — schedule brightness to the sun instead of fixed times.
- [ ] **Per-TV schedule targeting** — schedules currently apply to *all* TVs.
- [ ] Per-TV power rules (power automation applies to all TVs, like schedules).
- [ ] Surface TV power state in the menu bar icon/tooltip, not just the TV card.
- [ ] "Identify screens" helper to make TV↔display pairing foolproof.
- [ ] Optional per-TV dedicated hotkey combos (in addition to cursor targeting).

## Distribution & polish

- [ ] **App icon** — replace the generated sun tile with a real designed icon.
- [ ] **Code signing / notarization** — a real Developer ID would also end the
      local-network permission churn that ad-hoc signing causes (see README).
- [ ] Auto-update (Sparkle) and a release pipeline (zip + GitHub releases like LGforWin).
- [ ] README screenshots of the Mac app (Home, menu bar, OSD, pages).

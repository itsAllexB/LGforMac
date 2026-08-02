import AppKit
import SwiftUI
import Observation

/// A small borderless, always-on-top OSD (like the system volume/brightness HUD) that
/// briefly shows the brightness when it's changed via global hotkeys — a frosted pill
/// that slides + fades in, anchored to a configurable corner of a configurable screen.
@MainActor
final class OsdController {
    // Metrics (points). "Win" is the LGforWin-style pill; "mac" mirrors the macOS 26
    // volume/brightness pop-up (wide Liquid Glass capsule below the menu bar,
    // top-trailing) — measured against the system HUD.
    private static let winWidth: CGFloat = 230
    private static let winHeight: CGFloat = 52          // icon + bar + value
    private static let winHeightWithName: CGFloat = 72  // + TV name line
    private static let macWidth: CGFloat = 290
    private static let macHeight: CGFloat = 46          // slider row only
    private static let macHeightWithName: CGFloat = 70  // + device-name row
    private static let macTopMargin: CGFloat = 11       // gap below the menu bar
    private static let msgWidth: CGFloat = 320          // the "no TV on this screen" prompt has text
    private static let msgHeight: CGFloat = 64
    private static let edgeMargin: CGFloat = 16
    private static let bottomMargin: CGFloat = 8
    private static let slide: CGFloat = 20
    private static let fadeIn: TimeInterval = 0.25
    private static let fadeOut: TimeInterval = 0.19

    private var panel: NSPanel?
    private var hosting: NSHostingView<OsdView>?
    private var glassView: NSView? // NSGlassEffectView on macOS 26+
    private let model = OsdModel()
    private var hideTimer: Timer?

    private var finalOrigin = NSPoint.zero
    private var anchoredTop = false
    private var visible = false
    private var hiding = false

    /// Shows (or refreshes) the brightness OSD per the settings.
    /// When the mode is "the adjusted TV's screen" and that screen isn't paired/connected,
    /// nothing is shown — unless `allowFallback` (Preview / schedules) falls back to primary.
    func showBrightness(tvName: String?, value: Int, osd: OsdSettings, screenId: String?,
                        allowFallback: Bool = false) {
        guard let screen = resolveScreen(mode: osd.monitor, screenId: screenId,
                                         allowFallback: allowFallback) else { return }

        let showName = osd.showTvName && !(tvName ?? "").isEmpty
        model.mode = .brightness
        model.style = osd.style
        model.value = max(0, min(100, value))
        model.name = showName ? tvName : nil

        let size = osd.style == 0
            ? NSSize(width: Self.macWidth, height: showName ? Self.macHeightWithName : Self.macHeight)
            : NSSize(width: Self.winWidth, height: showName ? Self.winHeightWithName : Self.winHeight)
        show(on: screen, style: osd.style, position: osd.position, size: size,
             timeout: osd.timeoutSeconds)
    }

    /// Shows the "no TV on this screen — pair your TVs" prompt on the cursor's screen,
    /// WITHOUT changing any brightness.
    func showUnpaired(osd: OsdSettings) {
        guard let screen = ScreenService.screenAtCursor() ?? NSScreen.main else { return }
        model.mode = .message
        model.style = osd.style
        model.title = "No TV on this screen"
        model.subtitle = "Pair your TVs to their screens on the Home page."
        show(on: screen, style: osd.style, position: osd.position,
             size: NSSize(width: Self.msgWidth, height: Self.msgHeight),
             timeout: osd.timeoutSeconds)
    }

    // Resolves the screen to show the OSD on: 0 = primary, 1 = the adjusted TV's paired
    // screen, 2 = the screen under the cursor.
    private func resolveScreen(mode: Int, screenId: String?, allowFallback: Bool) -> NSScreen? {
        let primary = NSScreen.screens.first ?? NSScreen.main
        switch mode {
        case 2:
            return ScreenService.screenAtCursor() ?? primary
        case 1:
            if let paired = ScreenService.screen(withId: screenId) { return paired }
            // Only one display connected → it's unambiguously the one to use (not a fallback).
            if NSScreen.screens.count == 1 { return primary }
            return allowFallback ? primary : nil
        default:
            return primary
        }
    }

    // Common show path: place on the screen's visible frame, anchor, then slide + fade in
    // (or snap if already up). The macOS style always drops in below the menu bar at the
    // trailing edge (like the system volume/brightness pop-up); the Windows style uses
    // the configurable 6-corner anchor.
    private func show(on screen: NSScreen, style: Int, position: Int, size: NSSize,
                      timeout: TimeInterval) {
        let panel = ensurePanel()

        let work = screen.visibleFrame
        let x: CGFloat
        let y: CGFloat
        let top: Bool
        if style == 0 {
            x = work.maxX - size.width - Self.edgeMargin
            y = work.maxY - size.height - Self.macTopMargin
            top = true
        } else {
            top = position == 3 || position == 4 || position == 5
            x = switch position {
            case 1, 4: work.minX + Self.edgeMargin                       // left
            case 2, 5: work.maxX - size.width - Self.edgeMargin          // right
            default: work.midX - size.width / 2                          // centre (0, 3)
            }
            y = top
                ? work.maxY - size.height - Self.edgeMargin
                : work.minY + Self.bottomMargin
        }
        finalOrigin = NSPoint(x: x, y: y)
        anchoredTop = top

        applyBackdrop(style: style, size: size)

        let finalFrame = NSRect(origin: finalOrigin, size: size)

        if !visible {
            // Pre-place just off the resting spot (above for top anchors, below for bottom)
            // and fade up into place.
            panel.alphaValue = 0
            panel.setFrame(finalFrame.offsetBy(dx: 0, dy: anchoredTop ? Self.slide : -Self.slide),
                           display: false)
            panel.orderFrontRegardless()
            visible = true
            hiding = false
            animate(to: finalFrame, alpha: 1, duration: Self.fadeIn, easeOut: true)
        } else if hiding {
            // Interrupted mid fade-out: glide back to fully visible from wherever we are.
            hiding = false
            animate(to: finalFrame, alpha: 1, duration: Self.fadeIn, easeOut: true)
        } else {
            // Already up: snap to the (possibly new) anchor without re-running the entrance.
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
        }

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, min(5.0, timeout)),
                                         repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginHide() }
        }
    }

    private func beginHide() {
        guard let panel, visible else { return }
        hiding = true
        let exit = NSRect(origin: NSPoint(x: finalOrigin.x,
                                          y: finalOrigin.y + (anchoredTop ? Self.slide : -Self.slide)),
                          size: panel.frame.size)
        animate(to: exit, alpha: 0, duration: Self.fadeOut, easeOut: false) { [weak self] in
            guard let self, self.hiding else { return } // a re-show interrupted the hide
            self.panel?.orderOut(nil)
            self.visible = false
            self.hiding = false
        }
    }

    private func animate(to frame: NSRect, alpha: CGFloat, duration: TimeInterval,
                         easeOut: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: easeOut ? .easeOut : .easeIn)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            if let completion {
                Task { @MainActor in completion() }
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.macWidth, height: Self.macHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none // we drive the slide + fade ourselves

        let hosting = NSHostingView(rootView: OsdView(model: model))
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    // The macOS style renders inside a real Liquid Glass container (NSGlassEffectView,
    // macOS 26+) — the same material the system volume/brightness pop-up uses. Older
    // systems and the Windows style fall back to the SwiftUI material background drawn
    // by OsdView itself (`model.glassBackdrop` tells it which mode it's in).
    private func applyBackdrop(style: Int, size: NSSize) {
        guard let panel, let hosting else { return }

        if style == 0, model.mode == .brightness, #available(macOS 26.0, *) {
            let glass: NSGlassEffectView
            if let existing = glassView as? NSGlassEffectView {
                glass = existing
            } else {
                glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
                glass.autoresizingMask = [.width, .height]
                glassView = glass
            }
            glass.cornerRadius = size.height / 2 // full capsule, like the system HUD
            if panel.contentView !== glass {
                panel.contentView = glass
                glass.contentView = hosting
            }
            model.glassBackdrop = true
        } else {
            if panel.contentView !== hosting {
                hosting.removeFromSuperview() // detach from the glass container
                panel.contentView = hosting
            }
            model.glassBackdrop = false
        }
    }

    func close() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        glassView = nil
        visible = false
        hiding = false
    }
}

// MARK: - Content

@MainActor
@Observable
final class OsdModel {
    enum Mode { case brightness, message }
    var mode: Mode = .brightness
    /// 0 = macOS system pop-up look, 1 = Windows/LGforWin pill.
    var style = 0
    /// True when an NSGlassEffectView provides the backdrop, so the view draws none.
    var glassBackdrop = false
    var value = 50
    var name: String?
    var title = ""
    var subtitle = ""
}

/// The frosted HUD. Materials render as blur-behind-window because the hosting panel
/// is transparent.
struct OsdView: View {
    let model: OsdModel

    private var cornerRadius: CGFloat {
        model.mode == .brightness && model.style == 0 ? 23 : 14
    }

    var body: some View {
        Group {
            switch model.mode {
            case .brightness where model.style == 0: macBrightness
            case .brightness: winBrightness
            case .message: message
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The glass container (macOS 26+) supplies the backdrop for the macOS style;
            // everything else draws the classic frosted material itself.
            if !model.glassBackdrop {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            }
        }
    }

    /// Mirrors the macOS 26 volume/brightness pop-up: optional device-name row, then a
    /// thin dotted track with dim/bright sun icons at the ends. No numeric readout —
    /// the system HUD has none.
    private var macBrightness: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let name = model.name {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            HStack(spacing: 12) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.16))
                        // Step dots, revealed only where the fill hasn't covered them —
                        // like the system HUD's tick marks.
                        HStack(spacing: 0) {
                            ForEach(1..<16) { _ in
                                Circle()
                                    .fill(.primary.opacity(0.22))
                                    .frame(width: 2.5, height: 2.5)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        Capsule().fill(.primary.opacity(0.85))
                            .frame(width: max(4, geo.size.width * CGFloat(model.value) / 100))
                    }
                }
                .frame(height: 4)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }

    /// The LGforWin-style pill (icon + bar + numeric value).
    private var winBrightness: some View {
        VStack(spacing: 6) {
            if let name = model.name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.primary)
                            .frame(width: geo.size.width * CGFloat(model.value) / 100)
                    }
                }
                .frame(height: 5)
                Text("\(model.value)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title).font(.system(size: 13, weight: .semibold))
            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

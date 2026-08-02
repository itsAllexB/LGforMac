import SwiftUI

// The entry point must be SYNCHRONOUS: an async main() would run NSApplicationMain
// inside one never-ending main-actor task, permanently starving every other
// `Task { @MainActor … }` in the app (UI status updates would silently never run).
@main
enum Entry {
    static func main() {
        if CliMode.isRequested {
            Task.detached {
                _ = await CliMode.runIfRequested()
                exit(0)
            }
            dispatchMain() // service the main queue for the CLI's MainActor hops
        }
        LGforMacApp.main()
    }
}

struct LGforMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    /// Set once services are running; a duplicate instance that terminates early must NOT
    /// run the shutdown path (its fresh AppState would overwrite the primary's state files).
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second launch just surfaces the one already running.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.itsallexb.LGforMac")
        if running.count > 1 {
            running.first { $0 != .current }?.activate()
            NSApp.terminate(nil)
            return
        }

        let state = AppState.shared
        state.start()
        started = true

        // Manual launches always open the window; the launch-behavior preference applies
        // only to the at-login autostart launch (tagged with --autostart by the agent).
        let behavior = AutostartService.isAutostartLaunch ? state.settings.launchBehavior : 0
        switch behavior {
        case 2:
            break // menu bar only
        case 1:
            showMainWindow(activate: false)
            windowController?.window?.miniaturize(nil)
        default:
            showMainWindow(activate: !AutostartService.isAutostartLaunch)
        }
    }

    // Closing the window keeps the app alive in the menu bar (parity with hide-to-tray).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clicking the Dock icon (or reopening) surfaces the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard started else { return }
        AppState.shared.shutdown()
    }

    func showMainWindow(activate: Bool = true) {
        if windowController == nil {
            windowController = MainWindowController()
        }
        windowController?.showWindow(nil)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// The main settings window: an AppKit window hosting the SwiftUI MainView, so launch
/// behavior (hidden / minimized), close-to-menu-bar and show-from-menu-bar stay fully
/// under our control.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let hosting = NSHostingController(rootView: MainView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "LGforMac"
        window.setContentSize(NSSize(width: 900, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.setFrameAutosaveName("LGforMacMain")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    // Close hides to the menu bar instead of quitting (parity with LGforWin's tray icon).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

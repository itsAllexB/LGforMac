import Foundation
import ServiceManagement

/// Opt-in "launch at login" via an SMAppService launch agent bundled in the app.
/// The agent's plist passes `--autostart`, so the app can tell an at-login launch
/// from a manual one (manual launches always open the window).
enum AutostartService {
    static let autostartArg = "--autostart"

    private static let agent = SMAppService.agent(plistName: "com.itsallexb.LGforMac.autostart.plist")

    /// True when this process was launched by the login agent rather than the user.
    static var isAutostartLaunch: Bool {
        CommandLine.arguments.contains(autostartArg)
    }

    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                if agent.status != .enabled { try agent.register() }
            } else {
                if agent.status == .enabled { try agent.unregister() }
            }
        } catch {
            Log.write("autostart: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}

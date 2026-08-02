import SwiftUI
import UniformTypeIdentifiers

// MARK: - Schedules

/// Up to 10 daily brightness rules, applied to all TVs, with sleep/startup catch-up.
struct SchedulesView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        PageScaffold(
            title: "Schedules",
            subtitle: "Daily rules that set every TV's OLED Light at a time of day. Rules missed while the Mac was asleep are applied when it wakes; TVs that were off get the value the moment they're back."
        ) {
            GroupBox {
                Toggle(isOn: $state.applyScheduleOnStartup) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apply the current schedule at startup")
                        Text("On launch, set each TV to the most recent schedule that has already passed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            if state.settings.schedules.isEmpty {
                Text("No schedules yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach($state.settings.schedules) { $schedule in
                ScheduleRow(schedule: $schedule) {
                    state.removeSchedule(schedule)
                } onChange: {
                    state.persistSchedules()
                }
            }

            Button {
                state.addSchedule()
            } label: {
                Label("Add schedule", systemImage: "plus")
            }
            .disabled(state.settings.schedules.count >= 10)

            if state.settings.schedules.count >= 10 {
                Text("Up to 10 schedules are allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScheduleRow: View {
    @Binding var schedule: BrightnessSchedule
    let onDelete: () -> Void
    let onChange: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Toggle("", isOn: Binding(
                    get: { schedule.enabled },
                    set: { schedule.enabled = $0; onChange() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()

                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(schedule.brightness) },
                    set: { schedule.brightness = Int($0.rounded()); onChange() }
                ), in: 0...100)
                Text("\(schedule.brightness)%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(6)
            .opacity(schedule.enabled ? 1 : 0.55)
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                schedule.hour = Calendar.current.component(.hour, from: date)
                schedule.minute = Calendar.current.component(.minute, from: date)
                onChange()
            }
        )
    }
}

// MARK: - Power

/// TV power automation: follow the Mac's startup, sleep, shutdown and display-sleep.
struct PowerView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        PageScaffold(
            title: "Power",
            subtitle: "Turn the TVs on and off together with the Mac. All rules apply to every TV, and waking uses Wake-on-LAN."
        ) {
            GroupBox("Turn on") {
                VStack(alignment: .leading, spacing: 10) {
                    toggle("When LGforMac starts",
                           "With launch-at-login enabled, that's when you sign in.",
                           \.onAppStart)
                    toggle("When the Mac wakes from sleep", nil, \.onResume)
                    toggle("When the displays wake", nil, \.followDisplayOn)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Turn off") {
                VStack(alignment: .leading, spacing: 10) {
                    toggle("When the Mac goes to sleep", nil, \.offOnSleep)
                    toggle("When the Mac shuts down, restarts or you log out", nil, \.offOnShutdown)
                    toggle("When macOS puts the displays to sleep",
                           "The idle display-sleep timer in System Settings → Lock Screen.",
                           \.followDisplayOff)

                    Picker("Display-sleep action", selection: Binding(
                        get: { state.settings.power.displayOffAction },
                        set: { state.settings.power.displayOffAction = $0; state.saveSettings() }
                    )) {
                        Text("Screen off — instant resume").tag(0)
                        Text("Power off fully — wakes via Wake-on-LAN").tag(1)
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(!state.settings.power.followDisplayOff)
                    .padding(.leading, 20)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("For the turn-on rules, enable Quick Start+ on the TV (General → Devices → External Devices — wording varies); that's what lets it answer Wake-on-LAN. Note that once macOS sleeps a display it stops sending a picture, so the TV usually powers itself off on “no signal” a few minutes later even in screen-off mode; waking covers both cases.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ title: String, _ caption: String?,
                        _ keyPath: WritableKeyPath<PowerSettings, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { state.settings.power[keyPath: keyPath] },
            set: { state.settings.power[keyPath: keyPath] = $0; state.saveSettings() }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Hotkeys

/// Global brightness hotkeys: customizable modifier combo + step.
struct HotkeysView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        PageScaffold(
            title: "Hotkeys",
            subtitle: "Global shortcuts that nudge brightness on the TV whose screen the cursor is on. With a single TV they always target it — no pairing needed."
        ) {
            GroupBox("Modifier keys") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Control (⌃)", isOn: $state.hotkeyControl)
                    Toggle("Option (⌥)", isOn: $state.hotkeyOption)
                    Toggle("Shift (⇧)", isOn: $state.hotkeyShift)
                    Toggle("Command (⌘)", isOn: $state.hotkeyCommand)
                    Text("Combined with the ↑ / ↓ arrow keys. At least one modifier is always kept — bare arrows would be swallowed system-wide.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                LabeledContent("Current shortcut") {
                    Text(state.hotkeyComboText)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                }
                .padding(6)
            }

            GroupBox("Step") {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { Double(state.hotkeyStep) },
                        set: { state.hotkeyStep = Int($0.rounded()) }
                    ), in: 1...25, step: 1)
                    Text("\(state.hotkeyStep) points")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(6)
            }
        }
    }
}

// MARK: - On-screen display

/// The brightness OSD overlay preferences.
struct OsdSettingsView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        PageScaffold(
            title: "On-screen display",
            subtitle: "A brief overlay that confirms the new brightness when you use the hotkeys."
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show the on-screen display", isOn: Binding(
                        get: { state.settings.osd.enabled },
                        set: { state.settings.osd.enabled = $0; state.saveSettings() }
                    ))

                    Picker("Style", selection: Binding(
                        get: { state.settings.osd.style },
                        set: { state.settings.osd.style = $0; state.saveSettings() }
                    )) {
                        Text("macOS — system pop-up under the menu bar").tag(0)
                        Text("Windows — LGforWin-style pill").tag(1)
                    }
                    .pickerStyle(.radioGroup)

                    Picker("Position", selection: Binding(
                        get: { state.settings.osd.position },
                        set: { state.settings.osd.position = $0; state.saveSettings() }
                    )) {
                        Text("Bottom centre").tag(0)
                        Text("Bottom left").tag(1)
                        Text("Bottom right").tag(2)
                        Text("Top centre").tag(3)
                        Text("Top left").tag(4)
                        Text("Top right").tag(5)
                    }
                    .fixedSize()
                    .disabled(state.settings.osd.style == 0)
                    if state.settings.osd.style == 0 {
                        Text("The macOS style always appears below the menu bar, like the system volume and brightness pop-ups. Position applies to the Windows style.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Picker("Screen", selection: Binding(
                        get: { state.settings.osd.monitor },
                        set: { state.settings.osd.monitor = $0; state.saveSettings() }
                    )) {
                        Text("Primary display").tag(0)
                        Text("The adjusted TV's screen").tag(1)
                        Text("Screen under the cursor").tag(2)
                    }
                    .fixedSize()

                    HStack(spacing: 10) {
                        Text("Duration")
                        Slider(value: Binding(
                            get: { state.settings.osd.timeoutSeconds },
                            set: { state.settings.osd.timeoutSeconds = max(0.5, min(5.0, $0)); state.saveSettings() }
                        ), in: 0.5...5.0, step: 0.1)
                        Text(String(format: "%.1f s", state.settings.osd.timeoutSeconds))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    Toggle("Show the TV's name", isOn: Binding(
                        get: { state.settings.osd.showTvName },
                        set: { state.settings.osd.showTvName = $0; state.saveSettings() }
                    ))

                    Toggle("Also show when a schedule changes brightness", isOn: Binding(
                        get: { state.settings.osd.showOnSchedule },
                        set: { state.settings.osd.showOnSchedule = $0; state.saveSettings() }
                    ))
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                state.previewOsd()
            } label: {
                Label("Preview", systemImage: "eye")
            }
        }
    }
}

// MARK: - Settings

/// App preferences: theme, launch at login, launch behavior, backup import/export.
struct SettingsView: View {
    @Bindable private var state = AppState.shared
    @State private var dialogMessage: DialogMessage?

    struct DialogMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    var body: some View {
        PageScaffold(
            title: "Settings",
            subtitle: "Appearance, startup and backups."
        ) {
            GroupBox("Appearance") {
                Picker("Theme", selection: $state.themeIndex) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch at login", isOn: $state.startAtLogin)
                    Picker("When launched at login, open", selection: $state.launchBehavior) {
                        Text("Normal window").tag(0)
                        Text("Minimized").tag(1)
                        Text("Menu bar only").tag(2)
                    }
                    .fixedSize()
                    Text("Launching it yourself always opens the window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            exportBackup()
                        } label: {
                            Label("Export settings…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            importBackup()
                        } label: {
                            Label("Import settings…", systemImage: "square.and.arrow.down")
                        }
                    }
                    Text("One JSON file with your TVs (including pairing keys), schedules and preferences. LGforWin backups import too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert(item: $dialogMessage) { message in
            Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LGforMac-backup.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try state.exportSettings().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                dialogMessage = DialogMessage(title: "Export failed", text: error.localizedDescription)
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let json = try String(contentsOf: url, encoding: .utf8)
                try state.importSettings(json)
                dialogMessage = DialogMessage(
                    title: "Import complete",
                    text: "Your TVs, schedules and preferences have been restored.")
            } catch {
                dialogMessage = DialogMessage(
                    title: "Import failed",
                    text: "Couldn't import that file.\n\n\(error.localizedDescription)")
            }
        }
    }
}

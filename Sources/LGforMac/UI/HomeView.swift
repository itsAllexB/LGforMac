import SwiftUI

/// The TVs page: add by name/IP or discovery, per-TV brightness slider, power toggle,
/// screen pairing, remove, and drag-to-reorder.
struct HomeView: View {
    @Bindable private var state = AppState.shared
    @State private var newName = ""
    @State private var newHost = ""
    @State private var showDiscover = false

    var body: some View {
        PageScaffold(
            title: "TVs",
            subtitle: "Drag a slider to set OLED Light. Global hotkeys adjust the TV on the screen your cursor is on — pair each TV to its display below. Drag rows to reorder."
        ) {
            if state.networkPermissionSuspected {
                NetworkPermissionBanner()
            }

            HStack(spacing: 8) {
                TextField("Name (e.g. Living Room C3)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("IP address", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Button("Add TV") {
                    state.addTv(name: newName, host: newHost)
                    newName = ""
                    newHost = ""
                }
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    showDiscover = true
                } label: {
                    Label("Find TVs", systemImage: "magnifyingglass")
                }
            }

            if state.tvs.isEmpty {
                ContentUnavailableView(
                    "No TVs yet",
                    systemImage: "tv",
                    description: Text("Click Find TVs to scan your network, or add one by IP address. Make sure “LG Connect Apps” is enabled on the TV (Settings → Network).")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                List {
                    ForEach(state.tvs) { tv in
                        TvCard(tv: tv)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { source, destination in
                        state.moveTvs(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .frame(height: CGFloat(state.tvs.count) * 118)
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverSheet()
        }
        .onAppear {
            state.refreshScreens() // freshly (un)plugged displays appear on revisit
        }
    }
}

private struct TvCard: View {
    @Bindable var tv: TvState
    private var state: AppState { AppState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tv.isConnected ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 9, height: 9)
                Text(tv.name)
                    .font(.headline)
                if tv.isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: Capsule())
                        .foregroundStyle(.tint)
                }
                if tv.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    Task { await tv.togglePower() }
                } label: {
                    Image(systemName: "power")
                }
                .help("Turn the TV off when it's on, wake it when it's off")
                Button("Remove", role: .destructive) {
                    state.removeTv(tv)
                }
            }

            Text("\(tv.host)  ·  \(tv.statusText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(tv.backlight) },
                    set: { tv.backlight = Int($0.rounded()) }
                ), in: 0...100)
                Text("\(tv.backlight)%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            // Pair the TV to the display it drives — needed for cursor-targeted hotkeys and
            // the "TV's screen" OSD mode. Only shown when there's a choice to make.
            if state.screens.count > 1 {
                Picker(selection: Binding(
                    get: { tv.device.pairedScreenId },
                    set: { newId in
                        guard !newId.isEmpty else { return } // never wipe a saved pairing
                        tv.device.pairedScreenId = newId
                        state.persist()
                    }
                )) {
                    if tv.device.pairedScreenId.isEmpty {
                        Text("Choose…").tag("")
                    } else if !state.screens.contains(where: { $0.id == tv.device.pairedScreenId }) {
                        Text("(disconnected screen)").tag(tv.device.pairedScreenId)
                    }
                    ForEach(state.screens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                } label: {
                    Label("Screen", systemImage: "display")
                        .font(.caption)
                }
                .fixedSize()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            state.setActive(tv)
        }
    }
}

/// Shown when TVs are repeatedly unreachable — on macOS the usual culprit is the Local
/// Network permission being off (or never granted), so guide the user straight there.
struct NetworkPermissionBanner: View {
    private let state = AppState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Can't reach your TVs")
                    .font(.headline)
                Text("If they're on, macOS may be blocking LGforMac's network access. Check Privacy & Security → Network (and Local Network) and enable LGforMac, or request the permission prompt again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Privacy Settings") {
                        state.openLocalNetworkSettings()
                    }
                    Button("Request access") {
                        state.requestLocalNetworkAccess()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The "Find TVs" sheet: live SSDP scan results with one-click add.
struct DiscoverSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let state = AppState.shared

    @State private var discovered: [DiscoveredTv] = []
    @State private var added: Set<String> = []
    @State private var scanning = false
    @State private var statusText = "Searching for LG TVs…"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Find TVs").font(.title3.bold())
                if scanning {
                    ProgressView().controlSize(.small)
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            List(discovered) { tv in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tv.name).font(.system(size: 13, weight: .semibold))
                        Text(tv.model.isEmpty || tv.model == tv.name ? tv.host : "\(tv.host)  ·  \(tv.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if added.contains(tv.host) || state.hasTv(host: tv.host) {
                        Text("Added").foregroundStyle(.secondary)
                    } else {
                        Button("Add") {
                            state.addDiscoveredTv(tv)
                            added.insert(tv.host)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180)

            HStack {
                Button("Scan again") {
                    Task { await scan() }
                }
                .disabled(scanning)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 340)
        .task { await scan() }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        discovered = []
        statusText = "Searching for LG TVs…"

        let found = await SsdpDiscovery.findTvs { tv in
            if !discovered.contains(where: { $0.host == tv.host }) {
                discovered.append(tv)
            }
        }
        for tv in found where !discovered.contains(where: { $0.host == tv.host }) {
            discovered.append(tv)
        }

        statusText = switch discovered.count {
        case 0: "No TVs found. Check that the TV is on (not in standby) and connected to the same network."
        case 1: "1 TV found."
        case let n: "\(n) TVs found."
        }
        scanning = false
    }
}

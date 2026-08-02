import SwiftUI

/// The menu bar popover: quick brightness sliders and power controls for every TV.
struct MenuBarView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.networkPermissionSuspected {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("TVs unreachable — check Local Network permission")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Fix") {
                        state.openLocalNetworkSettings()
                    }
                    .controlSize(.mini)
                }
            }
            if state.tvs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No TVs yet")
                        .font(.headline)
                    Text("Open LGforMac and click Find TVs to add your LG TV.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(state.tvs) { tv in
                    MenuBarTvRow(tv: tv)
                }
            }

            Divider()

            HStack {
                Button("Open LGforMac") {
                    (NSApp.delegate as? AppDelegate)?.showMainWindow()
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct MenuBarTvRow: View {
    @Bindable var tv: TvState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tv.isConnected ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(tv.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(tv.backlight)%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    Task { await tv.togglePower() }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Turn the TV off when it's on, wake it when it's off")
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(tv.backlight) },
                    set: { tv.backlight = Int($0.rounded()) }
                ), in: 0...100)
                .controlSize(.small)
                Image(systemName: "sun.max")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

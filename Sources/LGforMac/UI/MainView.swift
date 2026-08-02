import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case tvs = "TVs"
    case schedules = "Schedules"
    case power = "Power"
    case hotkeys = "Hotkeys"
    case osd = "On-screen display"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tvs: "tv"
        case .schedules: "clock"
        case .power: "power"
        case .hotkeys: "keyboard"
        case .osd: "rectangle.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

/// The main window: sidebar navigation over the six feature pages, mirroring LGforWin.
struct MainView: View {
    @State private var page: AppPage = .tvs
    private let state = AppState.shared

    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: Binding(get: { page }, set: { page = $0 ?? .tvs })) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text("LGforMac \(state.appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        } detail: {
            switch page {
            case .tvs: HomeView()
            case .schedules: SchedulesView()
            case .power: PowerView()
            case .hotkeys: HotkeysView()
            case .osd: OsdSettingsView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}

/// Shared page chrome: large title + description, scrollable content column.
struct PageScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

import AppKit
import ElectricityCore
import SwiftUI

/// Sidebar entries of the dashboard window (SPEC 9).
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview, reports, details, cleanliness
    case general, sources, display, method, notifications
    case methodology, about

    var id: String { rawValue }

    enum Group: CaseIterable {
        case data, settings, about
    }

    static func sections(in group: Group) -> [DashboardSection] {
        switch group {
        case .data: [.overview, .reports, .details, .cleanliness]
        case .settings: [.general, .sources, .display, .method, .notifications]
        case .about: [.methodology, .about]
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "section.overview"
        case .reports: "section.reports"
        case .details: "section.details"
        case .cleanliness: "section.cleanliness"
        case .general: "section.general"
        case .sources: "section.sources"
        case .display: "section.display"
        case .method: "section.method"
        case .notifications: "section.notifications"
        case .methodology: "section.methodology"
        case .about: "section.about"
        }
    }

    var icon: Icon {
        switch self {
        case .overview: Icons.gauge
        case .reports: Icons.calendarBlank
        case .details: Icons.table
        case .cleanliness: Icons.leaf
        case .general: Icons.gearSix
        case .sources: Icons.integrations
        case .display: Icons.monitor
        case .method: Icons.function
        case .notifications: Icons.bell
        case .methodology: Icons.bookOpen
        case .about: Icons.info
        }
    }

    var color: Color {
        switch self {
        case .overview: .orange
        case .reports: .yellow
        case .details: .red
        case .cleanliness: .green
        case .sources: .teal
        case .display: .orange
        case .notifications: .red
        case .general, .method, .methodology, .about: .gray
        }
    }
}

/// Shared objects for dashboard pages.
@MainActor
struct DashboardContext {
    let model: AppModel
    let settings: AppSettings
    let coordinator: IngestCoordinator
    let autoExport: AutoExportSettings
    let grid: GridCoordinator
}

@MainActor
@Observable
final class DashboardNavigation {
    var selection: DashboardSection? = .overview
}

struct DashboardView: View {
    let context: DashboardContext
    @Bindable var navigation: DashboardNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(DashboardSection.Group.allCases, id: \.self) { group in
                    Section(Self.groupTitle(group)) {
                        ForEach(DashboardSection.sections(in: group)) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                IconBadge(section.icon, color: section.color, size: 20)
                            }
                            .tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let section = navigation.selection ?? .overview
            page(for: section)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .toolbar {
                    // Page title in the title bar, level with the window buttons, as in System Settings.
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .navigation) { pageTitle(section) }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .navigation) { pageTitle(section) }
                    }
                }
        }
    }

    private func pageTitle(_ section: DashboardSection) -> some View {
        HStack(spacing: 10) {
            IconBadge(section.icon, color: section.color, size: 26)
            Text(section.title).font(.title2.weight(.bold))
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private static func groupTitle(_ group: DashboardSection.Group) -> LocalizedStringKey {
        switch group {
        case .data: "sidebar.group.data"
        case .settings: "sidebar.group.settings"
        case .about: "sidebar.group.about"
        }
    }

    @ViewBuilder
    private func page(for section: DashboardSection) -> some View {
        switch section {
        case .overview: OverviewPage(context: context) { navigation.selection = $0 }
        case .reports: ReportsPage(context: context)
        case .details: DetailsPage(context: context)
        case .cleanliness: CleanlinessPage(context: context)
        case .general: GeneralSettingsPage(context: context)
        case .sources: SourcesSettingsPage(context: context)
        case .display: DisplaySettingsPage(context: context)
        case .method: MethodSettingsPage(context: context)
        case .notifications: NotificationSettingsPage(context: context)
        case .methodology: MethodologyPage(context: context)
        case .about: AboutPage()
        }
    }
}

/// Hosts the dashboard. The app shows a Dock icon while the window is open (SPEC 8.1).
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let context: DashboardContext
    private let navigation = DashboardNavigation()
    private var window: NSWindow?

    init(context: DashboardContext) {
        self.context = context
    }

    func show(section: DashboardSection? = nil) {
        if let section { navigation.selection = section }
        if window == nil {
            let hosting = NSHostingController(rootView: DashboardView(context: context, navigation: navigation))
            // SwiftUI's toolbar goes into the window. With a toolbar, the sidebar runs up around the window buttons.
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = AppIdentity.displayName
            // No visible title bar: the sidebar runs to the top and holds the window buttons.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.setContentSize(NSSize(width: 700, height: 740))
            window.contentMinSize = NSSize(width: 600, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            // New name, so the larger frame saved by earlier versions is not restored.
            window.setFrameAutosaveName("Dashboard.v2")
            if !window.setFrameUsingName("Dashboard.v2") { window.center() }
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

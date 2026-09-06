import SwiftData
import SwiftUI

@main
struct ObservorApp: App {
    @State private var monitor = AppMonitor()

    /// Uptime history is the only thing observor persists, and it persists it
    /// locally: nothing else produces it and nothing else needs to read it.
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: HealthSample.self)
        } catch {
            // A monitor that silently loses its history is worse than one that
            // refuses to start, so fail loudly here.
            fatalError("Could not open the local history store: \(error)")
        }
    }

    var body: some Scene {
        Window("observor", id: "dashboard") {
            DashboardView()
                .environment(monitor)
                .frame(minWidth: 720, minHeight: 560)
                .task { bootstrap() }
        }
        .modelContainer(container)
        .defaultSize(width: 960, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await monitor.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
                .task { bootstrap() }
        } label: {
            MenuBarLabel()
                .environment(monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }

    /// Both scenes call this; `start` is idempotent. The menu bar extra exists
    /// even when the window is closed, so the refresh loops must not depend on
    /// the window being open.
    private func bootstrap() {
        monitor.start(modelContext: container.mainContext)
        monitor.pruneHistory()
    }
}

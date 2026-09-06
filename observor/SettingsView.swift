import SwiftUI

struct SettingsView: View {
    @Environment(AppMonitor.self) private var monitor

    var body: some View {
        TabView {
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "link") }
            IntervalSettings()
                .tabItem { Label("Checks", systemImage: "timer") }
        }
        .frame(width: 460)
        .padding(20)
    }
}

// MARK: - Connection

private struct ConnectionSettings: View {
    @Environment(AppMonitor.self) private var monitor

    @State private var supabaseURL = ""
    @State private var serviceKey = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case testing
        case saved
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://your-project.supabase.co", text: $supabaseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("service_role key", text: $serviceKey)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Supabase")
            } footer: {
                Text("""
                    Project Settings → API. Use the **service_role** key, not the anon key: \
                    the analytics tables have no public read policy, so the anon key can \
                    write but cannot read. The key is stored in your login Keychain and \
                    never leaves this Mac.
                    """)
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 4)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Test and save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isComplete || status == .testing)

                    if monitor.isConfigured {
                        Button("Disconnect", role: .destructive) { disconnect() }
                    }

                    Spacer()
                    statusLabel
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            supabaseURL = monitor.credentials?.supabaseURL ?? ""
            serviceKey = monitor.credentials?.serviceKey ?? ""
        }
    }

    private var isComplete: Bool {
        ObservorCredentials(supabaseURL: supabaseURL, serviceKey: serviceKey).isComplete
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption)
            }
        case .saved:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.statusGood)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.statusCritical)
                .lineLimit(3)
        }
    }

    /// Round-trip before persisting, so a typo in the URL or a pasted anon key
    /// is caught here rather than showing up as an empty dashboard later.
    private func save() {
        let candidate = ObservorCredentials(supabaseURL: supabaseURL, serviceKey: serviceKey)
        status = .testing
        Task {
            do {
                try await monitor.verify(candidate)
                try monitor.saveCredentials(candidate)
                status = .saved
                await monitor.refreshStats()
            } catch {
                status = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    private func disconnect() {
        do {
            try monitor.clearCredentials()
            supabaseURL = ""
            serviceKey = ""
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Intervals

private struct IntervalSettings: View {
    @Environment(AppMonitor.self) private var monitor

    private let healthOptions = [30, 60, 120, 300]
    private let statsOptions = [60, 300, 900, 1800]

    var body: some View {
        @Bindable var monitor = monitor

        Form {
            Section {
                Picker("Uptime check", selection: $monitor.healthIntervalSeconds) {
                    ForEach(healthOptions, id: \.self) { Text(label(for: $0)).tag($0) }
                }
                Picker("Visit refresh", selection: $monitor.statsIntervalSeconds) {
                    ForEach(statsOptions, id: \.self) { Text(label(for: $0)).tag($0) }
                }
            } footer: {
                Text("""
                    Uptime probes run from this Mac, so history has gaps whenever \
                    observor is closed or the machine is asleep — the strip shows those \
                    as grey, meaning "not measured" rather than "down".
                    """)
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 4)
            }

            Section {
                LabeledContent("Monitored apps", value: "\(monitor.apps.count)")
                LabeledContent("Last uptime check", value: Format.relative(monitor.lastHealthCheck))
                LabeledContent("Last visit refresh", value: Format.relative(monitor.lastStatsRefresh))
            }
        }
        .formStyle(.grouped)
    }

    private func label(for seconds: Int) -> String {
        seconds < 60
            ? "Every \(seconds) seconds"
            : "Every \(seconds / 60) minute\(seconds == 60 ? "" : "s")"
    }
}

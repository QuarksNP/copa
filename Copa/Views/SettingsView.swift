import ServiceManagement
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Query private var items: [ClipItem]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmClear = false

    private let limits = [100, 250, 500, 1000, 0]

    var body: some View {
        @Bindable var monitor = app.monitor
        @Bindable var store = app.store
        @Bindable var linkPreviews = app.linkPreviews

        Form {
            Section("General") {
                Toggle("Open Copa at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Pause capturing", isOn: $monitor.isPaused)
            }

            Section {
                Toggle("Show link previews", isOn: $linkPreviews.isEnabled)
            } header: {
                Text("Links")
            } footer: {
                Text("Loads each link's title, image and icon from the website, like Messages does. Turn off to keep Copa fully offline.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep", selection: $store.historyLimit) {
                    ForEach(limits, id: \.self) { limit in
                        Text(limit == 0 ? "Everything" : "Last \(limit) items").tag(limit)
                    }
                }
                LabeledContent("Saved clips", value: "\(items.count) (\(items.filter(\.isPinned).count) pinned)")
                Button("Clear History…", role: .destructive) { confirmClear = true }
            } header: {
                Text("History")
            } footer: {
                Text("Pinned clips are never removed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Clipboard access", value: accessDescription)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Passwords copied from password managers are never saved. If macOS asks whether Copa may paste from other apps, choose “Always Allow” — you can change it later in System Settings › Privacy & Security › Paste from Other Apps.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { app.store.clearUnpinned() }
        } message: {
            Text("All clips except pinned ones will be deleted. This can't be undone.")
        }
    }

    private var accessDescription: String {
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: "Always allowed"
        case .alwaysDeny: "Denied — Copa can't see new copies"
        case .ask: "Ask each time"
        default: "Allowed"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Copa: launch at login failed – \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Shows the settings in a regular window (Copa has no Dock icon or main window).
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(app: AppModel) {
        if window == nil {
            let root = SettingsView()
                .environment(app)
                .modelContainer(app.store.container)
                .tint(.accentColor)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Copa Settings"
            window.styleMask = [.titled, .closable]
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

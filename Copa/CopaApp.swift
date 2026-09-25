import SwiftUI

@main
struct CopaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Copa has no Dock icon; this menu bar item is the way to reach settings or quit.
        MenuBarExtra {
            MenuBarContent(app: delegate.app, notch: { delegate.notch })
        } label: {
            Image(systemName: delegate.app.monitor.isPaused ? "clipboard" : "doc.on.clipboard")
        }
    }
}

private struct MenuBarContent: View {
    @Bindable var monitor: ClipboardMonitor
    let app: AppModel
    let notch: () -> NotchController?

    init(app: AppModel, notch: @escaping () -> NotchController?) {
        self.app = app
        self.monitor = app.monitor
        self.notch = notch
    }

    var body: some View {
        Button("Show Copa") { notch()?.expand(fromMenu: true) }
        Toggle("Pause Capture", isOn: $monitor.isPaused)
        Divider()
        Button("Settings…") { SettingsWindowController.shared.show(app: app) }
            .keyboardShortcut(",")
        Button("Quit Copa") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    private(set) var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.monitor.start()
        notch = NotchController(app: app)
    }
}

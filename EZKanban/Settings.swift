import SwiftUI
import KeyboardShortcuts
import ServiceManagement

/// A plain AppKit window, so it reliably comes to the front from a menu bar–only app.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(boardURL: URL) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(boardURL: boardURL)))
            window.title = "EZKanban Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // macOS may decline the activation above; this still raises the window over other apps.
        window?.orderFrontRegardless()
    }
}

private struct SettingsView: View {
    let boardURL: URL
    @AppStorage("showInboxCount") private var showInboxCount = false
    @State private var launchAtLogin = false
    @State private var loginStatusNote: String?

    var body: some View {
        VStack(spacing: 16) {
            form
            Text("By Marc Hoag | Copyright © 2026 [Axiomic, LLC](https://axiomic.ai)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: refreshLoginStatus)
    }

    private var form: some View {
        Form {
            KeyboardShortcuts.Recorder("Quick capture:", name: .quickCapture)
            KeyboardShortcuts.Recorder("Open board:", name: .toggleBoard)
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            if let loginStatusNote {
                Text(loginStatusNote).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show Inbox count in menu bar", isOn: $showInboxCount)
            LabeledContent("Board file:") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Reveal board.json in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([boardURL])
                    }
                    Text("Done cards older than 48 hours move to archive.jsonl next to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            NSLog("EZKanban: launch at login change failed: \(error)")
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginStatusNote = status == .requiresApproval
            ? "Approve EZKanban in System Settings › General › Login Items."
            : nil
    }
}

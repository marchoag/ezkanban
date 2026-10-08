import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let quickCapture = Self("quickCapture", default: .init(.space, modifiers: [.option, .shift]))
    static let toggleBoard = Self("toggleBoard", default: .init(.k, modifiers: [.option, .shift]))
}

@main
struct EZKanbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    // The board lives in a panel under our own status item (see MenuBarController), so the
    // app needs no windows of its own; an empty Settings scene satisfies SwiftUI.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = BoardStore()
    lazy var board = BoardController(store: store)
    private lazy var capture = QuickCaptureController(store: store)
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(store: store, board: board)
        KeyboardShortcuts.onKeyDown(for: .quickCapture) { [weak self] in
            self?.capture.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleBoard) { [weak self] in
            self?.menuBar?.toggle()
        }
    }
}

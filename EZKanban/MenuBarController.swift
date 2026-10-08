import AppKit
import SwiftUI
import Combine

/// Owns the menu bar icon and the board panel that drops down from it.
/// (SwiftUI's MenuBarExtra can't be opened or closed from code, which the hotkey and Settings need.)
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private static let boardSize = NSSize(width: 640, height: 420)
    private static let cornerRadius: CGFloat = 12

    private let store: BoardStore
    private let board: BoardController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel = makePanel()
    private var observers: Set<AnyCancellable> = []
    private var lastClosed = Date.distantPast

    init(store: BoardStore, board: BoardController) {
        self.store = store
        self.board = board
        super.init()
        board.closeBoard = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "EZKanban")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        // @Published fires before the change lands, so count from the incoming value.
        store.$cards
            .sink { [weak self] cards in self?.updateCount(cards.filter { $0.column == .inbox }.count) }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                updateCount(store.count(in: .inbox))
            }
            .store(in: &observers)
    }

    func toggle() {
        panel.isVisible ? close() : open()
    }

    func open() {
        // A click on the icon while open can close the panel (resign key) just before this runs.
        guard Date.now.timeIntervalSince(lastClosed) > 0.25 else { return }
        panel.setFrameOrigin(origin(for: panel.frame.size))
        board.isOpen = true
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        store.clearExpiredDone()
    }

    func close() {
        guard panel.isVisible else { return }
        // Pause the animated glow while the panel is still on screen; a hidden window
        // never gets the update, and its animation would keep redrawing in the background.
        board.isOpen = false
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderOut(nil)
        lastClosed = .now
        statusItem.button?.highlight(false)
    }

    @objc private func statusItemClicked() {
        toggle()
    }

    private func updateCount(_ count: Int) {
        let show = UserDefaults.standard.bool(forKey: "showInboxCount") && count > 0
        statusItem.button?.title = show ? "\(count)" : ""
    }

    /// Just under the status item, kept on screen.
    private func origin(for size: NSSize) -> NSPoint {
        let anchor = statusItem.button?.window?.frame
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        let x = min(max((anchor?.midX ?? visible.midX) - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor?.minY ?? visible.maxY, visible.maxY) - 6
        return NSPoint(x: x, y: top - size.height)
    }

    // MARK: NSWindowDelegate

    /// Clicking anywhere else closes the board, like a menu.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        // Non-activating: the board takes keyboard focus without pulling the app you were in
        // to the background, so focus returns there when it closes.
        let panel = BoardPanel(
            contentRect: NSRect(origin: .zero, size: Self.boardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        let content = ZStack {
            GlassBackground(cornerRadius: Self.cornerRadius)
            BoardView()
                .environmentObject(store)
                .environmentObject(board)
                .clipShape(shape)
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.boardSize)
        panel.contentView = host
        return panel
    }
}

private final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

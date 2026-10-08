import SwiftUI
import Combine

/// Where a dragged card would land: `index` counts the column's other cards.
struct DragSlot: Equatable {
    var column: Column
    var index: Int
}

/// UI state for the board (selection, editing, live drag) and its keyboard navigation.
@MainActor
final class BoardController: ObservableObject {
    static let moveAnimation = Animation.snappy(duration: 0.3)

    @Published var selectedID: Card.ID?
    @Published var editingID: Card.ID?
    @Published var isAddingCard = false

    @Published private(set) var draggingID: Card.ID?
    @Published private(set) var dragSlot: DragSlot?
    /// Set while a drag hovers a full Doing column.
    @Published private(set) var blockedColumn: Column?
    /// The column a card last moved into, drawn on top so the card stays visible in flight.
    @Published private(set) var raisedColumn: Column?
    /// Whether the board panel is showing; animations pause while it isn't.
    @Published var isOpen = false
    /// A brief message in the footer, e.g. after a delete.
    @Published private(set) var toast: String?

    /// Card frames in their column's coordinate space, used to place drops.
    var cardFrames: [Card.ID: CGRect] = [:]

    let store: BoardStore
    private(set) weak var window: NSWindow?
    private var keyMonitor: Any?
    private var cardsObserver: AnyCancellable?
    private var dragEndTimer: Timer?
    private var releasedTicks = 0
    private var toastToken = 0

    init(store: BoardStore) {
        self.store = store
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        // Drop selection/editing state for cards that vanished (e.g. deleted in board.json).
        cardsObserver = store.$cards.sink { [weak self] cards in
            guard let self else { return }
            let ids = Set(cards.map(\.id))
            if let id = selectedID, !ids.contains(id) { selectedID = nil }
            if let id = editingID, !ids.contains(id) { editingID = nil }
        }
    }

    func attach(to window: NSWindow) {
        self.window = window
    }

    // MARK: Opening and closing

    /// Hides the board; set by the menu bar controller that owns the panel.
    var closeBoard: () -> Void = {}

    /// Brings Settings forward while the board still has focus (macOS only lets the app
    /// activate in response to its own input), then closes the board so it can't sit on top.
    func openSettings() {
        SettingsWindow.show(boardURL: store.fileURL)
        closeBoard()
    }

    // MARK: Editing

    func delete(_ id: Card.ID) {
        withAnimation(Self.moveAnimation) { store.delete(id) }
        showToast("Card deleted.")
    }

    func undo() {
        select(withAnimation(Self.moveAnimation) { store.undo() })
    }

    func redo() {
        select(withAnimation(Self.moveAnimation) { store.redo() })
    }

    private func select(_ ids: [Card.ID]) {
        toast = nil
        if let id = ids.first(where: { id in store.cards.contains { $0.id == id } }) { selectedID = id }
    }

    private func showToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        withAnimation { toast = message }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, toastToken == token else { return }
            withAnimation { self.toast = nil }
        }
    }

    // MARK: Drag and drop

    /// The column's cards as currently shown, with a dragged card at its live position.
    func displayedCards(in column: Column) -> [Card] {
        var cards = store.cards(in: column)
        guard let id = draggingID, let slot = dragSlot,
              let card = store.cards.first(where: { $0.id == id }) else { return cards }
        cards.removeAll { $0.id == id }
        if slot.column == column { cards.insert(card, at: min(slot.index, cards.count)) }
        return cards
    }

    func beginDrag(_ id: Card.ID) {
        draggingID = id
        dragSlot = nil
        blockedColumn = nil
        selectedID = id
        if editingID != nil { editingID = nil }

        // SwiftUI doesn't report cancelled drags, so watch for the mouse coming up without a drop.
        releasedTicks = 0
        dragEndTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDragReleased() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragEndTimer = timer
    }

    func dragUpdated(in column: Column, at location: CGPoint) {
        guard let id = draggingID, let card = store.cards.first(where: { $0.id == id }) else { return }
        if column == .doing, card.column != .doing, store.count(in: .doing) >= BoardStore.wipLimit {
            guard blockedColumn != .doing else { return }
            withAnimation(Self.moveAnimation) {
                blockedColumn = .doing
                dragSlot = nil
            }
            return
        }
        let index = store.cards(in: column)
            .filter { $0.id != id && (cardFrames[$0.id]?.midY ?? .infinity) < location.y }
            .count
        let slot = DragSlot(column: column, index: index)
        guard slot != dragSlot || blockedColumn != nil else { return }
        withAnimation(Self.moveAnimation) {
            if column != (dragSlot?.column ?? card.column) { raisedColumn = column }
            dragSlot = slot
            blockedColumn = nil
        }
    }

    func dragExited(_ column: Column) {
        if blockedColumn == column {
            withAnimation(Self.moveAnimation) { blockedColumn = nil }
        }
    }

    func performDrop(in column: Column) -> Bool {
        guard let id = draggingID else { return false }
        let slot = dragSlot
        let blocked = blockedColumn == column
        var moved = false
        withAnimation(Self.moveAnimation) {
            if blocked {
                store.move(id, to: column, at: 0)  // refused; makes Doing shake
            } else if let slot {
                moved = store.move(id, to: slot.column, at: slot.index)
            }
            clearDrag()
        }
        return moved
    }

    private func checkDragReleased() {
        guard draggingID != nil else { return clearDrag() }
        releasedTicks = NSEvent.pressedMouseButtons & 1 == 0 ? releasedTicks + 1 : 0
        if releasedTicks >= 2 {
            withAnimation(Self.moveAnimation) { clearDrag() }
        }
    }

    private func clearDrag() {
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        draggingID = nil
        dragSlot = nil
        blockedColumn = nil
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Only the board window, and never while a text field is being edited.
        guard let window, event.window === window, !(window.firstResponder is NSText) else { return event }
        let command = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if command, key == "z" {
            event.modifierFlags.contains(.shift) ? redo() : undo()
            return nil
        }
        if command, key == "," {
            openSettings()
            return nil
        }
        switch event.keyCode {
        case 53: closeBoard()                                                 // Esc
        case 126: command ? reorderSelected(by: -1) : moveSelection(by: -1)  // ↑
        case 125: command ? reorderSelected(by: 1) : moveSelection(by: 1)    // ↓
        case 123: shiftSelected(by: -1)                                       // ←
        case 124: shiftSelected(by: 1)                                        // →
        case 36, 76: editingID = selectedID                                   // Return, Enter
        case 51, 117: deleteSelected()                                        // ⌫, ⌦
        default:
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty, key == "n" else { return event }
            isAddingCard = true
        }
        return nil
    }

    private var selectedCard: Card? {
        store.cards.first { $0.id == selectedID }
    }

    private func moveSelection(by delta: Int) {
        guard let card = selectedCard else {
            selectedID = Column.allCases.lazy.compactMap { self.store.cards(in: $0).first }.first?.id
            return
        }
        let list = store.cards(in: card.column)
        if let i = list.firstIndex(of: card), list.indices.contains(i + delta) {
            selectedID = list[i + delta].id
        }
    }

    private func reorderSelected(by delta: Int) {
        guard let card = selectedCard else { return }
        let list = store.cards(in: card.column)
        if let i = list.firstIndex(of: card), list.indices.contains(i + delta) {
            withAnimation(Self.moveAnimation) { _ = store.move(card.id, to: card.column, at: i + delta) }
        }
    }

    /// Moves the selected card to the top of the neighbouring column.
    private func shiftSelected(by delta: Int) {
        guard let card = selectedCard,
              let i = Column.allCases.firstIndex(of: card.column),
              Column.allCases.indices.contains(i + delta) else { return }
        let destination = Column.allCases[i + delta]
        raisedColumn = destination
        withAnimation(Self.moveAnimation) { _ = store.move(card.id, to: destination, at: 0) }
    }

    private func deleteSelected() {
        guard let card = selectedCard else { return }
        let list = store.cards(in: card.column)
        let i = list.firstIndex(of: card) ?? 0
        let next = list.indices.contains(i + 1) ? list[i + 1] : (i > 0 ? list[i - 1] : nil)
        delete(card.id)
        selectedID = next?.id
    }
}

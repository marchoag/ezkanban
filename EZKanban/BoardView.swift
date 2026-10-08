import SwiftUI
import UniformTypeIdentifiers
import KeyboardShortcuts

struct BoardView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var board: BoardController
    @Namespace private var cardNamespace

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Column.allCases) { column in
                    ColumnView(column: column, namespace: cardNamespace)
                        .zIndex(board.raisedColumn == column ? 1 : 0)
                }
            }
            footer
        }
        .padding(10)
        .frame(width: 640, height: 420)
        .background(BoardSheen(isActive: board.isOpen))
        .background(WindowAccessor { board.attach(to: $0) })
        .onAppear { store.clearExpiredDone() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === board.window { store.clearExpiredDone() }
        }
    }

    private var footer: some View {
        HStack {
            if let toast = board.toast {
                Text(toast)
                Button("Undo") { board.undo() }
                    .buttonStyle(.link)
            } else if let shortcut = KeyboardShortcuts.getShortcut(for: .quickCapture) {
                Text("\(shortcut.description) capture · ↑↓ select · ←→ move · ⌘↑↓ reorder · N new · ⌘Z undo")
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Settings…") { board.openSettings() }
                Divider()
                Button("Quit EZKanban") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Column

private struct ColumnView: View {
    let column: Column
    let namespace: Namespace.ID
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var board: BoardController
    @State private var isTargeted = false
    @State private var shakes = 0
    @State private var showWIPWarning = false

    private var isBlocked: Bool { board.blockedColumn == column }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(count: store.count(in: column))
            if column == .inbox && board.isAddingCard {
                NewCardField()
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(board.displayedCards(in: column)) { card in
                        CardView(card: card, column: column)
                            .matchedGeometryEffect(id: card.id, in: namespace)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            // Clip vertically only, so cards flying in from a neighbouring column stay visible.
            .scrollClipDisabled()
            .mask(Rectangle().padding(.horizontal, -1000))
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 2)
                .animation(.easeOut(duration: 0.15), value: borderColor)
        }
        .overlay(alignment: .bottom) {
            if showWIPWarning || isBlocked {
                Text("Finish something first.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.red))
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(.named(column))
        .onDrop(of: [.text], delegate: ColumnDropDelegate(column: column, board: board, isTargeted: $isTargeted))
        .modifier(Shake(animatableData: CGFloat(shakes)))
        .onChange(of: store.wipRejections) {
            if column == .doing { rejectMove() }
        }
    }

    private var borderColor: Color {
        if showWIPWarning || isBlocked { return .red }
        return isTargeted ? .accentColor : .clear
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Text(column.title).font(.headline)
            Text(column == .doing ? "\(count)/\(BoardStore.wipLimit)" : "\(count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            if column == .inbox {
                Button { board.isAddingCard.toggle() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New card (N)")
            }
        }
    }

    private func rejectMove() {
        withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        withAnimation { showWIPWarning = true }
        let attempt = shakes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if shakes == attempt { withAnimation { showWIPWarning = false } }
        }
    }
}

private struct ColumnDropDelegate: DropDelegate {
    let column: Column
    let board: BoardController
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        board.draggingID != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        board.dragUpdated(in: column, at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        board.dragUpdated(in: column, at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        board.dragExited(column)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return board.performDrop(in: column)
    }
}

private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 6), y: 0))
    }
}

// MARK: - Card

private struct CardView: View {
    let card: Card
    /// The column the card is shown in, which differs from `card.column` mid-drag.
    let column: Column
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var board: BoardController
    @State private var isHovering = false

    private var isEditing: Bool { board.editingID == card.id }
    /// The card being dragged; its slot shows where it will land.
    private var isGhost: Bool { board.draggingID == card.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isEditing {
                CardEditor(card: card)
            } else {
                Text(card.text).lineLimit(3)
            }
            Text(card.createdAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
        .opacity(isGhost ? 0.45 : 1)
        .overlay {
            if isGhost {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            } else if board.selectedID == card.id {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering && !isEditing && !isGhost {
                Button {
                    board.delete(card.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .padding(6)
                .help("Delete")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            board.selectedID = card.id
            board.editingID = card.id
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(column)) } action: { frame in
            board.cardFrames[card.id] = frame
        }
        .onDrag {
            board.beginDrag(card.id)
            return NSItemProvider(object: card.dragPayload as NSString)
        } preview: {
            CardDragPreview(card: card, width: board.cardFrames[card.id]?.width ?? 180)
        }
    }
}

/// The full card, lifted, shown under the cursor while dragging.
private struct CardDragPreview: View {
    let card: Card
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.text).lineLimit(3)
            Text(card.createdAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5))
        .frame(width: width)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .padding(12)
    }
}

private extension View {
    func cardStyle() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            }
    }
}

private struct CardEditor: View {
    let card: Card
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var board: BoardController
    @State private var text = ""
    @State private var finished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Card", text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onAppear {
                text = card.text
                DispatchQueue.main.async { isFocused = true }
            }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: isFocused) { _, focused in if !focused { finish(save: true) } }
            .onDisappear { finish(save: true) }
    }

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        if save { store.updateText(card.id, to: text) }
        if board.editingID == card.id { board.editingID = nil }
    }
}

private struct NewCardField: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var board: BoardController
    @State private var text = ""
    @State private var finished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("New card", text: $text)
            .textFieldStyle(.plain)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1))
            .focused($isFocused)
            .onAppear { DispatchQueue.main.async { isFocused = true } }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: isFocused) { _, focused in if !focused { finish(save: true) } }
    }

    /// Clicking away still keeps what was typed.
    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        withAnimation(BoardController.moveAnimation) {
            if save, let card = store.add(text) { board.selectedID = card.id }
            board.isAddingCard = false
        }
    }
}

// MARK: - Window access

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReportingView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReportingView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

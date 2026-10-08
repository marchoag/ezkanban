import AppKit
import SwiftUI

/// Spotlight-style floating panel for capturing a card from anywhere.
/// The panel is non-activating, so the frontmost app stays active while you type.
@MainActor
final class QuickCaptureController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// Stands in for line breaks in the single-line field; each segment becomes a card.
    static let lineBreak = "⏎"

    private let store: BoardStore
    private let field = NSTextField()
    private let fieldEditor = CaptureFieldEditor()
    private let glow = CaptureGlowState()
    private lazy var panel = makePanel()
    private var previousApp: NSRunningApplication?

    init(store: BoardStore) {
        self.store = store
        super.init()
    }

    func toggle() {
        panel.isVisible ? dismiss() : show()
    }

    private func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : frontmost
        glow.isActive = true
        glow.shownAt = .now
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if !panel.makeFirstResponder(field) {
            DispatchQueue.main.async { self.panel.makeFirstResponder(self.field) }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        glow.isActive = false
        // Only needed if we somehow got activated; normally the previous app never lost it.
        if NSApp.isActive, let previousApp { previousApp.activate() }
        previousApp = nil
    }

    /// Centres the bar horizontally, a fifth of the way down the screen under the mouse.
    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return .zero
        }
        let visible = screen.visibleFrame
        let barTop = visible.maxY - visible.height * 0.2
        return NSPoint(x: visible.midX - size.width / 2, y: barTop + CaptureView.glowPadding - size.height)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            store.add(lines: field.stringValue.components(separatedBy: Self.lineBreak))
            clear()
            dismiss()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            clear()
            dismiss()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateCardCount()
    }

    private func clear() {
        field.stringValue = ""
        updateCardCount()
    }

    private func updateCardCount() {
        glow.cardCount = field.stringValue.components(separatedBy: Self.lineBreak)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    // MARK: NSWindowDelegate

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as AnyObject?) === field ? fieldEditor : nil
    }

    /// Clicking elsewhere hides the panel but keeps the draft for next time.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let size = NSSize(width: CaptureView.barSize.width + CaptureView.glowPadding * 2,
                          height: CaptureView.barSize.height + CaptureView.glowPadding * 2)
        let panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the glow does the lifting
        panel.delegate = self

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = "Capture a task…"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        let host = NSHostingView(rootView: CaptureView(field: field, glow: glow))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        return panel
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Pasting several lines keeps them apart (one card each) instead of mashing them together.
private final class CaptureFieldEditor: NSTextView {
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isFieldEditor = true
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string),
              string.contains(where: \.isNewline) else { return super.paste(sender) }
        let lines = string.components(separatedBy: .newlines)
            // Drop list markers like "- ", "• ", "1. " and "- [ ] " from pasted notes.
            .map { $0.replacingOccurrences(of: #"^\s*(?:[-*•–]|\d+[.)])\s+(?:\[[ xX]?\]\s+)?"#,
                                           with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        insertText(lines.joined(separator: " \(QuickCaptureController.lineBreak) "), replacementRange: selectedRange())
    }
}

// MARK: - Glowing bar

final class CaptureGlowState: ObservableObject {
    @Published var isActive = false
    @Published var shownAt = Date.distantPast
    /// How many cards Return will create (more than one after pasting several lines).
    @Published var cardCount = 0
}

/// Frosted bar with a slowly rotating, Apple Intelligence–style colour glow around its edge.
private struct CaptureView: View {
    static let barSize = CGSize(width: 600, height: 60)
    static let glowPadding: CGFloat = 36
    static let cornerRadius: CGFloat = 16

    let field: NSTextField
    @ObservedObject var glow: CaptureGlowState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !glow.isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let edge = AngularGradient(colors: Sheen.palette, center: .center, angle: .degrees(t * 45))
            // A burst of light when the bar opens that settles into a slow breathing glow.
            let flare = max(0, 1 - timeline.date.timeIntervalSince(glow.shownAt) / 0.9)
            let breathe = 0.5 + 0.5 * sin(t * 1.8)
            let drift = 0.5 + 0.5 * sin(t * 0.6)

            ZStack {
                // Outer glow, padded so the blur isn't clipped. drawingGroup() renders the
                // animated gradients on the GPU instead of redrawing them on the CPU each frame.
                ZStack {
                    shape.stroke(edge, lineWidth: 10 + 14 * flare)
                        .blur(radius: 20)
                        .opacity(0.45 + 0.2 * breathe + 0.35 * flare)
                    shape.stroke(edge, lineWidth: 3)
                        .blur(radius: 5)
                        .opacity(0.85)
                }
                .frame(width: Self.barSize.width, height: Self.barSize.height)
                .padding(Self.glowPadding)
                .drawingGroup()

                ZStack {
                    GlassBackground(cornerRadius: Self.cornerRadius)
                    // Colour wash drifting across the glass, a soft highlight along the top, and the rim.
                    ZStack {
                        shape.fill(LinearGradient(colors: Sheen.palette,
                                                  startPoint: UnitPoint(x: -0.6 + drift, y: 0),
                                                  endPoint: UnitPoint(x: 0.6 + drift, y: 1)))
                            .opacity(0.13)
                        shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                        shape.strokeBorder(edge, lineWidth: 1.5)
                    }
                    .drawingGroup()
                    HStack(spacing: 12) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 20))
                            .foregroundStyle(edge)
                        CaptureField(field: field)
                        if glow.cardCount > 1 {
                            Text("\(glow.cardCount) cards")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary))
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(width: Self.barSize.width, height: Self.barSize.height)
            }
        }
    }
}

private struct CaptureField: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ nsView: NSTextField, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: nsView.intrinsicContentSize.height)
    }
}

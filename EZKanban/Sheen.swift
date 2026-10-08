import SwiftUI

/// The Apple Intelligence–style colours shared by the capture bar and the board.
enum Sheen {
    static let palette: [Color] = [
        Color(red: 0.03, green: 0.58, blue: 1.00),  // blue
        Color(red: 0.79, green: 0.35, blue: 0.87),  // purple
        Color(red: 1.00, green: 0.18, blue: 0.33),  // pink
        Color(red: 1.00, green: 0.56, blue: 0.02),  // orange
        Color(red: 0.03, green: 0.58, blue: 1.00),  // back to blue
    ]
}

/// A faint, slowly drifting colour wash behind the board, with a soft glow along its edges.
struct BoardSheen: View {
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let drift = 0.5 + 0.5 * sin(t * 0.25)
            let strength = colorScheme == .dark ? 1.0 : 0.7
            ZStack {
                LinearGradient(colors: Sheen.palette,
                               startPoint: UnitPoint(x: -0.5 + drift, y: 0),
                               endPoint: UnitPoint(x: 0.5 + drift, y: 1))
                    .opacity(0.10 * strength)
                Rectangle()
                    .strokeBorder(AngularGradient(colors: Sheen.palette, center: .center, angle: .degrees(t * 20)),
                                  lineWidth: 3)
                    .blur(radius: 8)
                    .opacity(0.55 * strength)
            }
            .drawingGroup()  // GPU-rendered; drawn on the CPU this costs ~30% while open
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Behind-window blur, masked to a rounded rect (SwiftUI clipping doesn't reach the blur).
struct GlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

import Foundation

enum Column: String, Codable, CaseIterable, Identifiable {
    case inbox, doing, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .doing: "Doing"
        case .done: "Done"
        }
    }
}

struct Card: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var column: Column
    var order: Int
    var createdAt: Date
    var movedAt: Date

    init(text: String, column: Column = .inbox, order: Int = -1, now: Date = .now) {
        id = UUID()
        self.text = text
        self.column = column
        self.order = order
        createdAt = now
        movedAt = now
    }

    /// Lenient so a hand-edited file still loads: only `text` is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        let rawColumn = (try? c.decode(String.self, forKey: .column)) ?? ""
        column = Column(rawValue: rawColumn.lowercased()) ?? .inbox
        order = (try? c.decode(Int.self, forKey: .order)) ?? .max
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .now
        movedAt = (try? c.decode(Date.self, forKey: .movedAt)) ?? createdAt
    }
}

struct BoardFile: Codable {
    var cards: [Card]
}

// MARK: - Drag and drop

extension Card {
    private static let dragPrefix = "ezkanban-card:"

    var dragPayload: String { Self.dragPrefix + id.uuidString }

    static func id(fromDragPayload payload: String) -> UUID? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(dragPrefix.count)))
    }
}

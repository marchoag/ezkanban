import Foundation

/// Owns the board and its JSON file. Every mutation is written to disk atomically,
/// and external edits to the file are picked up live.
@MainActor
final class BoardStore: ObservableObject {
    static let wipLimit = 3
    static let doneRetention: TimeInterval = 48 * 60 * 60

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EZKanban", isDirectory: true)
            .appendingPathComponent("board.json")
    }

    /// Always grouped by column (inbox, doing, done) and sorted by `order` within each.
    @Published private(set) var cards: [Card] = []
    /// Bumped whenever a move into Doing is refused by the WIP limit.
    @Published private(set) var wipRejections = 0

    let fileURL: URL
    /// The bytes last read from or written to disk; used to ignore our own writes.
    private var lastDiskData: Data?
    /// The file on disk failed to parse. It gets backed up before we overwrite it.
    private var diskFileIsInvalid = false
    private var watcher: FileWatcher?

    init(fileURL: URL = BoardStore.defaultFileURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        syncWithDisk()
        if !FileManager.default.fileExists(atPath: fileURL.path) { save() }
        clearExpiredDone()
        watcher = FileWatcher(url: fileURL) { [weak self] in
            Task { @MainActor in self?.syncWithDisk() }
        }
    }

    // MARK: Queries

    func cards(in column: Column) -> [Card] {
        cards.filter { $0.column == column }
    }

    func count(in column: Column) -> Int {
        cards.reduce(0) { $0 + ($1.column == column ? 1 : 0) }
    }

    // MARK: Mutations

    /// Adds a card to the top of Inbox.
    @discardableResult
    func add(_ text: String) -> Card? {
        add(lines: [text]).first
    }

    /// Adds one card per non-empty line to the top of Inbox, keeping their order.
    @discardableResult
    func add(lines: [String]) -> [Card] {
        let texts = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return [] }
        syncWithDisk()
        let now = Date.now
        let new = texts.enumerated().map { i, text in Card(text: text, order: i - texts.count, now: now) }
        commitUndoable(cards + new, affecting: new.map(\.id))
        return new.compactMap { card in cards.first { $0.id == card.id } }
    }

    func updateText(_ id: Card.ID, to text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        syncWithDisk()
        commitUndoable(cards.map { card in
            var card = card
            if card.id == id { card.text = text }
            return card
        }, affecting: [id])
    }

    func delete(_ id: Card.ID) {
        syncWithDisk()
        commitUndoable(cards.filter { $0.id != id }, affecting: [id])
    }

    /// Moves a card to `index` within `column`, where `index` counts the destination's
    /// cards *without* the moving card. Returns false if blocked by the WIP limit.
    @discardableResult
    func move(_ id: Card.ID, to column: Column, at index: Int) -> Bool {
        syncWithDisk()
        guard var card = cards.first(where: { $0.id == id }) else { return false }
        if column == .doing, card.column != .doing, count(in: .doing) >= Self.wipLimit {
            wipRejections += 1
            return false
        }
        if card.column != column {
            card.column = column
            card.movedAt = .now
        }
        card.order = index
        commitUndoable(Self.placing(card, id: id, in: cards), affecting: [id])
        return true
    }

    /// Moves Done cards older than 48 hours out of the board and into archive.jsonl.
    func clearExpiredDone(now: Date = .now) {
        syncWithDisk()
        let expired = cards.filter { $0.column == .done && now.timeIntervalSince($0.movedAt) >= Self.doneRetention }
        guard !expired.isEmpty, archive(expired, at: now) else { return }
        let ids = Set(expired.map(\.id))
        commit(cards.filter { !ids.contains($0.id) })
    }

    // MARK: Undo

    /// One card's state before and after an action; nil means the card didn't exist.
    private struct CardChange {
        let id: Card.ID
        let before: Card?
        let after: Card?
    }

    private var undoStack: [[CardChange]] = []
    private var redoStack: [[CardChange]] = []

    /// Reverts the last add, edit, move or delete. Returns the ids of the cards it touched.
    @discardableResult
    func undo() -> [Card.ID] {
        syncWithDisk()
        guard let changes = undoStack.last, restore(changes.map { ($0.id, $0.before) }) else { return [] }
        redoStack.append(undoStack.removeLast())
        return changes.map(\.id)
    }

    @discardableResult
    func redo() -> [Card.ID] {
        syncWithDisk()
        guard let changes = redoStack.last, restore(changes.map { ($0.id, $0.after) }) else { return [] }
        undoStack.append(redoStack.removeLast())
        return changes.map(\.id)
    }

    /// Puts each card back into the given state, unless that would overfill Doing.
    private func restore(_ states: [(Card.ID, Card?)]) -> Bool {
        let result = states.reduce(cards) { cards, state in Self.placing(state.1, id: state.0, in: cards) }
        let doing = result.filter { $0.column == .doing }.count
        if doing > Self.wipLimit, doing > count(in: .doing) {
            wipRejections += 1
            return false
        }
        commit(result)
        return true
    }

    private func commitUndoable(_ newCards: [Card], affecting ids: [Card.ID]) {
        let before = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commit(newCards)
        let changes = ids.compactMap { id -> CardChange? in
            let after = cards.first { $0.id == id }
            return before[id] == after ? nil : CardChange(id: id, before: before[id], after: after)
        }
        guard !changes.isEmpty else { return }
        undoStack.append(changes)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: Persistence

    private func commit(_ newCards: [Card]) {
        cards = Self.normalized(newCards)
        save()
    }

    /// Removes the card with `id`, then inserts `card` (if any) at its `order` within its column.
    private static func placing(_ card: Card?, id: Card.ID, in cards: [Card]) -> [Card] {
        let rest = cards.filter { $0.id != id }
        guard let card else { return rest }
        var destination = rest.filter { $0.column == card.column }
        destination.insert(card, at: min(max(card.order, 0), destination.count))
        for i in destination.indices { destination[i].order = i }
        return rest.filter { $0.column != card.column } + destination
    }

    /// Groups by column, sorts by order (ties keep file order), renumbers from 0,
    /// and gives duplicate ids (e.g. a card copy-pasted in the JSON) fresh ones.
    private static func normalized(_ cards: [Card]) -> [Card] {
        var seen = Set<Card.ID>()
        return Column.allCases.flatMap { column in
            cards.enumerated()
                .filter { $0.element.column == column }
                .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
                .enumerated()
                .map { order, entry in
                    var card = entry.element
                    card.order = order
                    if !seen.insert(card.id).inserted { card.id = UUID() }
                    return card
                }
        }
    }

    /// Adopts the file's contents if they changed since we last read or wrote it.
    func syncWithDisk() {
        guard let data = try? Data(contentsOf: fileURL), data != lastDiskData else { return }
        lastDiskData = data
        do {
            let loaded = Self.normalized(try Self.decoder.decode(BoardFile.self, from: data).cards)
            diskFileIsInvalid = false
            if loaded != cards { cards = loaded }
        } catch {
            diskFileIsInvalid = true
            NSLog("EZKanban: board.json is invalid; keeping the in-memory board. \(error)")
        }
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(BoardFile(cards: cards))
            guard data != lastDiskData else { return }
            if diskFileIsInvalid { backUpInvalidFile() }
            try data.write(to: fileURL, options: .atomic)
            lastDiskData = data
            diskFileIsInvalid = false
        } catch {
            NSLog("EZKanban: failed to save board.json: \(error)")
        }
    }

    var archiveURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("archive.jsonl")
    }

    /// Appends one JSON line per card. Returns false (so nothing is dropped) if it can't.
    private func archive(_ cards: [Card], at date: Date) -> Bool {
        do {
            var data = Data()
            for card in cards {
                data += try Self.archiveEncoder.encode(ArchivedCard(card: card, archivedAt: date))
                data += Data("\n".utf8)
            }
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                let handle = try FileHandle(forWritingTo: archiveURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: archiveURL, options: .atomic)
            }
            return true
        } catch {
            NSLog("EZKanban: failed to archive Done cards: \(error)")
            return false
        }
    }

    /// Never silently overwrite a hand edit that didn't parse.
    private func backUpInvalidFile() {
        let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("board.invalid-\(stamp).json")
        try? FileManager.default.copyItem(at: fileURL, to: backup)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let archiveEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unrecognized date: \(string)"))
        }
        return decoder
    }()
}

/// A card as written to archive.jsonl: its usual fields plus `archivedAt`.
private struct ArchivedCard: Encodable {
    let card: Card
    let archivedAt: Date

    private enum CodingKeys: String, CodingKey { case archivedAt }

    func encode(to encoder: Encoder) throws {
        try card.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(archivedAt, forKey: .archivedAt)
    }
}

/// Accepts ISO 8601 with or without fractional seconds, or a bare yyyy-MM-dd.
private func parseDate(_ string: String) -> Date? {
    (try? Date.ISO8601FormatStyle().parse(string))
        ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
        ?? (try? Date.ISO8601FormatStyle().year().month().day().parse(string))
}

/// Watches a file (and its directory, to catch atomic replaces) and calls back on change.
private final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        directorySource = makeSource(path: url.deletingLastPathComponent().path, events: .write)
        watchFile()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    /// Re-armed after every event because atomic saves swap in a new inode.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, events: [.write, .extend, .delete, .rename])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.watchFile()
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

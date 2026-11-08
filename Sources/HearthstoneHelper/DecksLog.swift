import Foundation

/// Parses Decks.log — the client's own deck journal. Blocks look like:
///
///     I 13:30:00.7607270 Finding Game With Deck:
///     I 13:30:00.7607270 ### 100战
///     I 13:30:00.7607270 # Deck ID: 1280876647
///     I 13:30:00.7607270 AAECAQcO…
///
/// `Finding Game With Deck:` marks the deck a match was queued with, which is
/// how a game in Power.log is attributed to a deck (same session, same clock).
public struct DecksLogFile: Equatable, Sendable {
    public enum Marker: String, Equatable, Sendable {
        case finding = "Finding Game With Deck"
        case editing = "Finished Editing Deck"
        case contents = "Deck Contents Received"
    }

    public struct DeckEntry: Equatable, Sendable {
        public let time: String
        public let marker: Marker
        public let name: String
        public let deckID: Int
        public let code: String
    }

    public let entries: [DeckEntry]

    public init(entries: [DeckEntry]) {
        self.entries = entries
    }

    public static func parse(_ text: String) -> DecksLogFile {
        var entries: [DeckEntry] = []
        var marker: Marker?
        var name: String?
        var entryTime = ""
        var deckID: Int?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (time, message) = splitLine(line)

            if message.hasPrefix("###") {
                name = String(message.dropFirst(3).trimmingCharacters(in: .whitespaces))
                entryTime = time
                deckID = nil
                continue
            }
            if message.hasPrefix("# Deck ID:") {
                deckID = Int(message.dropFirst("# Deck ID:".count).trimmingCharacters(in: .whitespaces))
                continue
            }
            if message.hasPrefix("AA") {
                if let name, let deckID {
                    entries.append(
                        DeckEntry(
                            time: entryTime,
                            marker: marker ?? .contents,
                            name: name,
                            deckID: deckID,
                            code: message
                        )
                    )
                }
                name = nil
                deckID = nil
                marker = nil
                continue
            }
            if let parsed = Marker(rawValue: message.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) {
                marker = parsed
            }
        }

        return DecksLogFile(entries: entries)
    }

    private static func splitLine(_ line: String) -> (String, String) {
        // "I 13:30:00.7607270 Finding Game With Deck:"
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return ("", line) }
        return (String(parts[1]), String(parts[2]))
    }

    /// All decks ever seen — including ones that only ever appeared in a
    /// "Finding Game With Deck" queue — deduplicated by deckID, newest wins.
    public var library: [DeckEntry] {
        var byID: [Int: DeckEntry] = [:]
        for entry in entries {
            byID[entry.deckID] = entry
        }
        return byID.values.sorted { $0.name < $1.name }
    }

    /// The deck queued for the game that started at `time`: the latest finding
    /// at or before it. Times are same-session HH:MM:SS.ffffff strings.
    public func deckUsed(at time: String) -> DeckEntry? {
        entries
            .filter { $0.marker == .finding && $0.time <= time }
            .max(by: { $0.time < $1.time })
    }
}

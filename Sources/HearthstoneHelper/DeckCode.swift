import Foundation

/// Decodes Hearthstone deck codes (the base64 `AAE…` deckstring format).
/// Layout per HearthSim's reference implementation: header (reserved, version,
/// format), heroes, then cards split into three sections — 1-copy, 2-copy and
/// n-copy — each with its own count prefix, optionally followed by sideboards.
public enum DeckCode {
    public struct CardRef: Equatable, Sendable {
        public let dbfID: Int
        public let count: Int
    }

    public struct DecodedDeck: Equatable, Sendable {
        public let format: Int
        public let heroDbfID: Int
        public let cards: [CardRef]

        public var totalCardCount: Int {
            cards.reduce(0) { $0 + $1.count }
        }
    }

    public static func decode(_ code: String) -> DecodedDeck? {
        guard let data = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let bytes = [UInt8](data)
        var index = 0

        func readVarint() -> Int? {
            var value = 0
            var shift = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 35 { return nil }
            }
            return nil
        }

        // header: reserved 0x00, version, format
        guard index < bytes.count, bytes[index] == 0x00 else { return nil }
        index += 1
        guard let version = readVarint(), version == 1 else { return nil }
        guard let format = readVarint() else { return nil }

        // heroes
        guard let heroCount = readVarint(), heroCount >= 1, let heroDbfID = readVarint() else {
            return nil
        }
        for _ in 1..<heroCount {
            guard readVarint() != nil else { return nil }
        }

        // cards: three sections with implicit copy counts of 1, 2 and n
        var cards: [CardRef] = []
        guard let singles = readVarint() else { return nil }
        for _ in 0..<singles {
            guard let dbfID = readVarint() else { return nil }
            cards.append(CardRef(dbfID: dbfID, count: 1))
        }
        guard let doubles = readVarint() else { return nil }
        for _ in 0..<doubles {
            guard let dbfID = readVarint() else { return nil }
            cards.append(CardRef(dbfID: dbfID, count: 2))
        }
        guard let others = readVarint() else { return nil }
        for _ in 0..<others {
            guard let dbfID = readVarint(), let count = readVarint() else { return nil }
            cards.append(CardRef(dbfID: dbfID, count: count))
        }

        // sideboards (0x01 flag + triples) are tolerated but ignored
        return DecodedDeck(format: format, heroDbfID: heroDbfID, cards: cards)
    }

    /// Encodes a deck list back into a base64 deckstring (three card sections,
    /// no sideboards) — used to export reconstructed opponent decks.
    public static func encode(
        heroDbfID: Int,
        cards: [(dbfID: Int, count: Int)],
        format: Int = 2
    ) -> String {
        var bytes: [UInt8] = [0x00, 0x01]
        appendVarint(format, to: &bytes)
        appendVarint(1, to: &bytes)           // single hero
        appendVarint(heroDbfID, to: &bytes)

        let singles = cards.filter { $0.count == 1 }.map(\.dbfID)
        let doubles = cards.filter { $0.count == 2 }.map(\.dbfID)
        let others = cards.filter { $0.count > 2 }

        appendVarint(singles.count, to: &bytes)
        for dbfID in singles { appendVarint(dbfID, to: &bytes) }
        appendVarint(doubles.count, to: &bytes)
        for dbfID in doubles { appendVarint(dbfID, to: &bytes) }
        appendVarint(others.count, to: &bytes)
        for entry in others {
            appendVarint(entry.dbfID, to: &bytes)
            appendVarint(entry.count, to: &bytes)
        }
        bytes.append(0x00)                    // no sideboards

        return Data(bytes).base64EncodedString()
    }

    private static func appendVarint(_ value: Int, to bytes: inout [UInt8]) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining > 0
    }
}

import Foundation
import Testing
@testable import HearthstoneCore

struct DeckCodeTests {
    /// The real deckstring the user's client printed for "套娃龙战".
    private static let longWarriorDeck = "AAECAQcKjtQEw4MHzI8HhJ0Hm6UHnaUHnqUHsMEHstgHhesHCqf8Bqn8BsP8BuiHB+qnB/yvB4+xB5vCB5zCB5TZBwAA"

    @Test
    func should_decode_real_deckstring_to_thirty_cards() throws {
        let deck = try #require(DeckCode.decode(Self.longWarriorDeck))
        #expect(deck.totalCardCount == 30)
        #expect(deck.cards.count > 15)
        #expect(deck.format > 0)
        #expect(deck.heroDbfID > 0)
    }

    @Test
    func should_reject_malformed_codes() {
        #expect(DeckCode.decode("这不是卡组代码") == nil)
        #expect(DeckCode.decode("AAAAAAAA") == nil)
    }

    @Test
    func should_roundtrip_encode_decode() throws {
        let cards: [(dbfID: Int, count: Int)] = [
            (7, 1), (100, 2), (315, 2), (99999, 3), (12345, 1)
        ]
        let code = DeckCode.encode(heroDbfID: 7, cards: cards, format: 2)
        let decoded = try #require(DeckCode.decode(code))

        #expect(decoded.heroDbfID == 7)
        #expect(decoded.format == 2)
        #expect(decoded.totalCardCount == 9)
        for (dbfID, count) in cards {
            #expect(decoded.cards.contains { $0.dbfID == dbfID && $0.count == count })
        }
    }
}

struct DecksLogTests {
    private static let sample = """
        I 13:10:13.2930990 Deck Contents Received:
        I 13:10:13.2930990 ### 龙战
        I 13:10:13.2930990 # Deck ID: 1280751715
        I 13:10:13.2930990 AAECAQcC1111
        I 13:10:13.2930990 ### 套娃龙战
        I 13:10:13.2930990 # Deck ID: 1280860546
        I 13:10:13.2930990 AAECAQcK2222
        I 13:10:16.6873250 Finding Game With Deck:
        I 13:10:16.6873250 ### 套娃龙战
        I 13:10:16.6873250 # Deck ID: 1280860546
        I 13:10:16.6873250 AAECAQcK2222
        I 13:30:00.7607270 Finding Game With Deck:
        I 13:30:00.7607270 ### 100战
        I 13:30:00.7607270 # Deck ID: 1280876647
        I 13:30:00.7607270 AAECAQcO3333
        """

    @Test
    func should_build_library_deduplicated_by_deck_id() {
        let file = DecksLogFile.parse(Self.sample)

        let library = file.library
        #expect(library.count == 3)
        #expect(library.map(\.name).contains("龙战"))
        #expect(library.map(\.name).contains("100战"))
    }

    @Test
    func should_attribute_game_to_deck_queued_before_it() throws {
        let file = DecksLogFile.parse(Self.sample)

        let deck = try #require(file.deckUsed(at: "13:10:27.3301610"))
        #expect(deck.name == "套娃龙战")
        #expect(deck.deckID == 1280860546)

        let later = try #require(file.deckUsed(at: "13:31:05.0000000"))
        #expect(later.name == "100战")

        #expect(file.deckUsed(at: "13:00:00.0000000") == nil)
    }
}

struct DeckViewRemainingTests {
    @Test
    func should_show_queued_deck_minus_drawn_when_deck_list_injected() throws {
        let fixtures = MatchSessionTrackerTests()
        var tracker = MatchSessionTracker()
        var parser = PowerLogLineParser()
        for line in fixtures.standardOpening() {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }

        tracker.setDeckList([("CS2_029", 2), ("NEW_009", 3)])

        var record = tracker.snapshot()
        var unwrapped = try #require(record)
        var remaining = unwrapped.playerRemainingCards
        #expect(remaining.contains { $0.cardID == "CS2_029" && $0.copies == 2 })
        #expect(remaining.contains { $0.cardID == "NEW_009" && $0.copies == 3 })

        // draw the in-deck CS2_029 (entity 68): deck view drops to 1 copy
        for line in [
            "D 10:00:02.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=68 tag=ZONE value=HAND"
        ] {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }

        record = tracker.snapshot()
        unwrapped = try #require(record)
        remaining = unwrapped.playerRemainingCards
        #expect(remaining.contains { $0.cardID == "CS2_029" && $0.copies == 1 })
        #expect(remaining.contains { $0.cardID == "NEW_009" && $0.copies == 3 })
    }

    @Test
    func should_merge_shuffled_in_foreign_cards_into_deck_view_as_generated() throws {
        let fixtures = MatchSessionTrackerTests()
        var tracker = MatchSessionTracker()
        var parser = PowerLogLineParser()
        for line in fixtures.standardOpening() + [
            // 一张本卡组没有的外来牌被洗进己方牌库（T5 会物化成明文卡）
            "D 10:00:05.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=200 CardID=BOT_601",
            "        tag=ZONE value=DECK",
            "        tag=CONTROLLER value=1"
        ] {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }

        tracker.setDeckList([("CS2_029", 2)])

        let snapshot = tracker.snapshot()
        let record = try #require(snapshot)
        let remaining = record.playerRemainingCards
        let original = try #require(remaining.first { $0.cardID == "CS2_029" })
        #expect(original.origin == .original)
        let shuffled = try #require(remaining.first { $0.cardID == "BOT_601" })
        #expect(shuffled.origin == .generated)
        #expect(shuffled.copies == 1)
    }

    @Test
    func should_report_whose_turn_it_is_for_countdown_attribution() throws {
        let fixtures = MatchSessionTrackerTests()
        var tracker = MatchSessionTracker()
        var parser = PowerLogLineParser()
        for line in fixtures.standardOpening() + [
            // friendly is player 1 → opponent (player 2) holds the turn first
            "D 10:00:02.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=3 tag=CURRENT_PLAYER value=2"
        ] {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }
        #expect(tracker.snapshot()?.currentActorIsOpponent == true)

        for line in [
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=2 tag=CURRENT_PLAYER value=1"
        ] {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }
        #expect(tracker.snapshot()?.currentActorIsOpponent == false)
    }
}

struct MatchResultTests {
    private let fixtures = MatchSessionTrackerTests()

    private func makeTracker(after lines: [String]) -> MatchSessionTracker {
        var parser = PowerLogLineParser()
        var tracker = MatchSessionTracker()
        for line in lines {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }
        return tracker
    }

    @Test
    func should_report_friendly_outcome_from_playstate() throws {
        var tracker = makeTracker(after: fixtures.standardOpening() + [
            // friendly is player 1 whose entity is 2; opponent concedes path uses LOST
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=2 tag=PLAYSTATE value=WON",
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=3 tag=PLAYSTATE value=LOST"
        ])

        let record = tracker.snapshot()!
        #expect(record.result == .win)
    }

    @Test
    func should_report_loss_and_ignore_running_states() throws {
        var tracker = makeTracker(after: fixtures.standardOpening() + [
            "D 10:00:10.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=2 tag=PLAYSTATE value=PLAYING",
            "D 10:00:10.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=3 tag=PLAYSTATE value=PLAYING",
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=2 tag=PLAYSTATE value=LOST",
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=3 tag=PLAYSTATE value=WON"
        ])

        #expect(tracker.snapshot()?.result == .loss)
    }

    @Test
    func should_resolve_named_playstate_via_mulligan_choice_mapping() throws {
        let fixtures = MatchSessionTrackerTests()
        var tracker = makeTracker(after: fixtures.standardOpening() + [
            // mulligan choice block: the log pairs the friendly BattleTag with
            // its playerID (entity 2 = player 1 = friendly here)
            "D 10:00:00.5000000 GameState.DebugPrintEntityChoices() - id=2 Player=我自己#1140 TaskList=8 ChoiceType=MULLIGAN CountMin=0 CountMax=3",
            "D 10:00:00.5000000 GameState.DebugPrintEntityChoices() -   Entities[0]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=69 zone=DECK zonePos=0 cardId= player=1]",
            // this client announces results under BattleTags only
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=对手#23828 tag=PLAYSTATE value=CONCEDED",
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=我自己#1140 tag=PLAYSTATE value=WON"
        ])

        #expect(tracker.snapshot()?.result == .win)
    }
}
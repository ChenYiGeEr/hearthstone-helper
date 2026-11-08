import Foundation
import Testing
@testable import HearthstoneCore

struct MatchSessionTrackerTests {
    /// Drives the tracker with synthetic Power.log lines through the real line parser,
    /// so parser context handling and reducer rules are exercised together.
    func tracker(after lines: [String]) -> MatchSessionTracker {
        var parser = PowerLogLineParser()
        var tracker = MatchSessionTracker()
        for line in lines {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }
        return tracker
    }

    func standardOpening() -> [String] {
        var lines = [
            "D 10:00:00.0000000 GameState.DebugPrintPower() - CREATE_GAME",
            "D 10:00:00.0000000 GameState.DebugPrintPower() -     Player EntityID=2 PlayerID=1 GameAccountId=[hi]",
            "D 10:00:00.0000000 GameState.DebugPrintPower() -     Player EntityID=3 PlayerID=2 GameAccountId=[lo]",
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=4 CardID=HERO_06",
            "        tag=ZONE value=PLAY",
            "        tag=CONTROLLER value=1",
            "        tag=CARDTYPE value=HERO",
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=5 CardID=HERO_05",
            "        tag=ZONE value=PLAY",
            "        tag=CONTROLLER value=2",
            "        tag=CARDTYPE value=HERO",
            // friendly deck card: created hidden, revealed later (T5 style)
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=68 CardID=",
            "        tag=ZONE value=DECK",
            "        tag=CONTROLLER value=1",
            "D 10:00:00.1000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=68 zone=DECK] CardID=CS2_029",
            "        tag=COST value=4",
            // friendly opening hand: printed hand cards are the side identifier
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=69 CardID=CS2_030",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=1",
            "        tag=COST value=3",
            // coin: printed but controlled by the opponent
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=140 CardID=GAME_005",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=2"
        ]
        // opponent: 27 hidden deck entities + 3 hidden hand entities = 30-card deck
        for index in 0..<27 {
            lines.append(contentsOf: [
                "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=\(100 + index) CardID=",
                "        tag=ZONE value=DECK",
                "        tag=CONTROLLER value=2"
            ])
        }
        for index in 0..<3 {
            lines.append(contentsOf: [
                "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=\(130 + index) CardID=",
                "        tag=ZONE value=HAND",
                "        tag=CONTROLLER value=2"
            ])
        }
        lines.append(
            "D 10:00:01.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=GameEntity tag=TURN value=1"
        )
        return lines
    }

    @Test
    func should_classify_opponent_reveals_from_initial_batch_as_original_and_derive_deck_size() throws {
        var tracker = tracker(after: standardOpening() + [
            "D 10:00:05.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=100 zone=HAND] CardID=EX1_001"
        ])

        let record = tracker.snapshot()!
        #expect(record.integrity == .complete)
        #expect(record.candidate.expectedCardCount == 30)
        #expect(record.opponentClass == "HERO_05")

        let originals = record.opponentCards(for: .original)
        #expect(originals.map(\.name) == ["EX1_001"])
        #expect(originals.first?.playedTurn == 1)
    }

    @Test
    func should_classify_midgame_generated_reveal_as_derived_with_creator_trail() throws {
        var tracker = tracker(after: standardOpening() + [
            "D 10:00:02.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=GameEntity tag=TURN value=2",
            // opponent plays the card revealed above
            "D 10:00:03.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=100 zone=HAND] CardID=EX1_001",
            // generated card: created mid-game, creator is the revealed entity 100
            "D 10:00:04.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=200 CardID=",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=2",
            "        tag=CREATOR value=100",
            "D 10:00:05.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=200 zone=HAND] CardID=NEW_001"
        ])

        let record = tracker.snapshot()!
        let generated = record.opponentCards(for: .generated)
        #expect(generated.map(\.name) == ["NEW_001"])
        #expect(generated.first?.sourceTrail == ["EX1_001"])
        #expect(generated.first?.isBoardOnly == false)
    }

    @Test
    func should_mark_summoned_entities_that_skip_hand_as_board_only() throws {
        var tracker = tracker(after: standardOpening() + [
            "D 10:00:02.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=210 CardID=",
            "        tag=ZONE value=PLAY",
            "        tag=CONTROLLER value=2",
            "D 10:00:03.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=210 zone=PLAY] CardID=TOTEM_01"
        ])

        let record = tracker.snapshot()!
        // board-only summons stay out of the per-origin main lists (folded into
        // their source event per design) but remain in the raw record
        let totem = try #require(record.opponentCards.first { $0.name == "TOTEM_01" })
        #expect(totem.origin == .generated)
        #expect(totem.isBoardOnly)
        #expect(record.opponentCards(for: .generated).isEmpty)
    }

    @Test
    func should_flag_match_over_on_game_state_complete() throws {
        var tracker = tracker(after: standardOpening())
        var parser = PowerLogLineParser()
        for line in [
            "D 10:00:20.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=GameEntity tag=STATE value=COMPLETE"
        ] {
            if let event = parser.parse(line) {
                tracker.apply(event)
            }
        }

        #expect(tracker.isMatchOver)
        #expect(tracker.snapshot()?.integrity == .complete)
    }

    @Test
    func should_record_partial_match_with_unknown_origin_when_create_game_was_missed() throws {
        var tracker = tracker(after: [
            // app joined mid-game: a printed friendly card in HAND and a hidden opponent card
            "D 11:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=300 CardID=CS2_030",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=1",
            "D 11:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=301 CardID=",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=2",
            "D 11:00:00.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=GameEntity tag=TURN value=5",
            "D 11:00:01.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=301 zone=HAND] CardID=OG_123"
        ])

        let record = tracker.snapshot()!
        #expect(record.integrity == .partial)
        #expect(record.opponentCards(for: .unknown).map(\.name) == ["OG_123"])
        #expect(record.opponentCards(for: .original).isEmpty)
        #expect(record.opponentCards(for: .generated).isEmpty)
        #expect(!record.candidate.isExportable)
    }

    @Test
    func should_reset_state_when_next_game_starts() throws {
        var tracker = tracker(after: standardOpening() + [
            "D 10:00:05.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=100 zone=HAND] CardID=EX1_001",
            "D 10:00:06.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=GameEntity tag=STATE value=COMPLETE",
            "D 10:00:10.0000000 GameState.DebugPrintPower() - CREATE_GAME"
        ])

        #expect(!tracker.isMatchOver)
        #expect(tracker.currentTurn == 0)
        let record = tracker.snapshot()!
        #expect(record.opponentCards.isEmpty)
    }

    @Test
    func should_track_friendly_played_cards_with_cost_turn_and_remaining_deck() throws {
        var tracker = tracker(after: standardOpening() + [
            // friendly card 68 (CS2_029) drawn into hand, then played on turn 3
            "D 10:00:02.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=68 tag=ZONE value=HAND",
            "D 10:00:02.0000000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=68 zone=HAND] CardID=CS2_029",
            "        tag=COST value=4",
            "D 10:00:02.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=1 tag=TURN value=3",
            "D 10:00:03.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=68 tag=ZONE value=PLAY"
        ])

        let record = tracker.snapshot()!
        let played = try #require(record.playerPlayedCards.first { $0.name == "CS2_029" })
        #expect(played.cost == 4)
        #expect(played.playedTurn == 3)
        #expect(played.origin == .original)
        // the only friendly deck card was played, so the remaining deck is empty
        #expect(record.playerRemainingCards.isEmpty)
    }

    @Test
    func should_record_friendly_generated_cards_as_shuffled_and_derived_when_played() throws {
        var tracker = tracker(after: standardOpening() + [
            // a generated friendly card enters hand mid-game, created by entity 68
            "D 10:00:02.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=300 CardID=NEW_002",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=1",
            "        tag=COST value=2",
            "        tag=CREATOR value=68",
            "D 10:00:02.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=1 tag=TURN value=4",
            "D 10:00:03.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=300 tag=ZONE value=PLAY"
        ])

        let record = tracker.snapshot()!
        let shuffled = try #require(record.playerShuffledCards.first { $0.name == "NEW_002" })
        #expect(shuffled.origin == .generated)
        #expect(shuffled.cost == 2)

        let played = try #require(record.playerPlayedCards.first { $0.name == "NEW_002" })
        #expect(played.origin == .generated)
        #expect(played.sourceTrail == ["CS2_029"])
        #expect(played.playedTurn == 4)
    }

    @Test
    func should_exclude_coin_from_friendly_deck_size_when_friendly_goes_second() throws {
        let lines = [
            "D 10:00:00.0000000 GameState.DebugPrintPower() - CREATE_GAME",
            // friendly plays second (controller 2): a printed deck card, a
            // printed hand card (the side identifier) and the coin
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=68 CardID=CS2_029",
            "        tag=ZONE value=DECK",
            "        tag=CONTROLLER value=2",
            "        tag=COST value=4",
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=69 CardID=CS2_030",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=2",
            "        tag=COST value=3",
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=140 CardID=GAME_005",
            "        tag=ZONE value=HAND",
            "        tag=CONTROLLER value=2",
            // opponent (controller 1) keeps hidden cards
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=100 CardID=",
            "        tag=ZONE value=DECK",
            "        tag=CONTROLLER value=1",
            "D 10:00:01.0000000 GameState.DebugPrintPower() - TAG_CHANGE Entity=1 tag=TURN value=1"
        ]

        var tracker = tracker(after: lines)
        let record = tracker.snapshot()!

        #expect(record.playerDeckName == "己方卡组（2 张）")
        #expect(record.playerRemainingCards.map(\.name) == ["CS2_029"])
        // the coin must never appear as deck content
        #expect(!record.playerShuffledCards.contains { $0.name == "GAME_005" })
        #expect(!record.playerPlayedCards.contains { $0.name == "GAME_005" })
    }

    @Test
    func should_attribute_nested_tag_rows_to_the_current_entity_block() throws {
        var parser = PowerLogLineParser()
        var state = PowerLogState()

        for line in [
            "D 10:00:00.0000000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=7 CardID=",
            "        tag=ZONE value=DECK",
            "        tag=CONTROLLER value=2",
            "        tag=CREATOR value=42"
        ] {
            if let event = parser.parse(line) {
                state.apply(event)
            }
        }

        let entity = try #require(state.entities[7])
        #expect(entity.zone == "DECK")
        #expect(entity.controller == 2)
        #expect(entity.creatorEntityID == 42)
        #expect(!entity.hasEnteredHand)
    }
}

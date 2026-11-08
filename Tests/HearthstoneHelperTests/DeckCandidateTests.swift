import Foundation
import Testing
@testable import HearthstoneCore

struct DeckCandidateTests {
    @Test
    func should_allow_export_when_complete_record_has_expected_original_card_count() {
        let candidate = DeckCandidate(
            expectedCardCount: 30,
            confirmedOriginalCards: [
                TrackedCard(name: "测试卡", cost: 1, copies: 30, origin: .original, playedTurn: 1)
            ],
            integrity: .complete
        )

        #expect(candidate.isExportable)
    }

    @Test
    func should_keep_candidate_as_draft_when_record_is_partial() {
        let candidate = DeckCandidate(
            expectedCardCount: 40,
            confirmedOriginalCards: [
                TrackedCard(name: "测试卡", cost: 1, copies: 40, origin: .original, playedTurn: 1)
            ],
            integrity: .partial
        )

        #expect(!candidate.isExportable)
        #expect(candidate.statusText.contains("不可导出"))
    }
}

struct PowerLogParserTests {
    @Test
    func should_parse_reveals_and_reduce_entity_identity_when_power_log_lines_arrive() throws {
        var parser = PowerLogLineParser()
        let lines = [
            "D 19:04:21.1010000 GameState.DebugPrintPower() - FULL_ENTITY - Creating ID=64 CardID=",
            "D 19:04:21.1010000 GameState.DebugPrintPower() - SHOW_ENTITY - Updating Entity=[name= id=64 zone=HAND] CardID=CS2_029",
            "D 19:04:21.1010000 GameState.DebugPrintPower() - TAG_CHANGE Entity=[name=Fireball id=64 zone=HAND] tag=ZONE value=PLAY"
        ]

        var state = PowerLogState()
        for line in lines {
            guard let event = parser.parse(line) else {
                Issue.record("unparsed line: \(line)")
                return
            }
            state.apply(event)
        }

        let entity = try #require(state.entities[64])
        #expect(entity.cardID == "CS2_029")
        #expect(entity.zone == "PLAY")
    }

    @Test
    func should_buffer_partial_lines_when_tailing_power_log() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "power-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data("FULL_ENTITY - Creating ID=7 Card".utf8).write(to: fileURL)
        var tailer = PowerLogTailer(fileURL: fileURL)
        #expect(try tailer.readNewEvents().isEmpty)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ID=EX1_116\n".utf8))
        try handle.close()

        let events = try tailer.readNewEvents()
        #expect(events == [.fullEntity(entityID: 7, cardID: "EX1_116")])
    }
}

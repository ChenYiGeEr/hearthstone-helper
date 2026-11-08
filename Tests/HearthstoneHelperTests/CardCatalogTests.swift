import Foundation
import Testing
@testable import HearthstoneCore

struct CardCatalogTests {
    private func makeCatalog() throws -> CardCatalog {
        let json = """
        [
          {"id":"HERO_08","dbfId":637,"name":"吉安娜·普罗德摩尔","cardClass":"MAGE","type":"HERO"},
          {"id":"CS2_029","dbfId":315,"name":"火球术","cost":4,"cardClass":"MAGE","type":"SPELL"},
          {"id":"GAME_005","dbfId":1746,"name":"幸运币","cost":0,"cardClass":"NEUTRAL","type":"ABILITY"}
        ]
        """
        return try CardCatalog(jsonData: Data(json.utf8))
    }

    @Test
    func should_map_card_ids_to_localized_name_and_cost() throws {
        let catalog = try makeCatalog()

        #expect(catalog.displayName(for: "CS2_029") == "火球术")
        #expect(catalog.cost(for: "CS2_029") == 4)
        #expect(catalog.displayName(for: "UNKNOWN_01") == "UNKNOWN_01")
        #expect(catalog.cost(for: "UNKNOWN_01") == nil)
        #expect(catalog.info(for: "CS2_029")?.dbfId == 315)
    }

    @Test
    func should_resolve_class_from_hero_cards_only() throws {
        let catalog = try makeCatalog()

        #expect(catalog.classDisplayName(forHeroCardID: "HERO_08") == "法师")
        // a spell sharing the hero's cardClass must not pose as a class
        #expect(catalog.classDisplayName(forHeroCardID: "CS2_029") == nil)
        #expect(catalog.classDisplayName(forHeroCardID: "未知职业") == nil)
    }

    @Test
    func should_localize_match_record_while_preserving_identity_and_fallbacks() throws {
        let catalog = try makeCatalog()
        let record = MatchRecord(
            playerDeckName: "未识别卡组",
            opponentClass: "HERO_08",
            startedAt: .now,
            integrity: .complete,
            playerRemainingCards: [],
            playerShuffledCards: [],
            playerPlayedCards: [],
            opponentCards: [
                TrackedCard(name: "CS2_029", cost: 0, origin: .original, playedTurn: 2),
                TrackedCard(name: "UNKNOWN_01", cost: 0, origin: .generated, playedTurn: 3, sourceTrail: ["GAME_005"])
            ],
            candidate: DeckCandidate(
                expectedCardCount: 30,
                confirmedOriginalCards: [
                    TrackedCard(name: "CS2_029", cost: 0, origin: .original, playedTurn: 2)
                ],
                integrity: .complete
            )
        )

        let localized = catalog.apply(to: record)

        #expect(localized.id == record.id)
        #expect(localized.opponentClass == "法师")

        let fireball = try #require(localized.opponentCards.first { $0.name == "火球术" })
        #expect(fireball.cost == 4)
        #expect(fireball.id == record.opponentCards[0].id)

        let unknown = try #require(localized.opponentCards.first { $0.name == "UNKNOWN_01" })
        #expect(unknown.cost == 0)
        #expect(unknown.sourceTrail == ["幸运币"])

        #expect(localized.candidate.confirmedOriginalCards.first?.name == "火球术")
        #expect(localized.candidate.confirmedOriginalCards.first?.cost == 4)

        // regression: hand cards must survive localization, not be dropped
        let withHand = MatchRecord(
            playerDeckName: "d",
            opponentClass: "HERO_08",
            startedAt: .now,
            integrity: .complete,
            playerHandCards: [TrackedCard(name: "CS2_029", cost: 4, origin: .original, playedTurn: 0)],
            playerRemainingCards: [],
            playerShuffledCards: [],
            playerPlayedCards: [],
            opponentCards: [],
            candidate: DeckCandidate(expectedCardCount: 30, confirmedOriginalCards: [], integrity: .complete)
        )
        let localizedHand = catalog.apply(to: withHand)
        #expect(localizedHand.playerHandCards.map(\.name) == ["火球术"])
    }

    @Test
    func should_tag_deathrattle_battlecry_and_dragon_synergy_mechanics() throws {
        let json = """
        [
          {"id":"DR_1","name":"亡语随从","text":"<b>亡语：</b>抽一张牌","type":"MINION"},
          {"id":"TRIG_1","name":"亡语触发器","text":"<b>战吼：</b>触发一个友方随从的亡语","type":"MINION"},
          {"id":"TRIG_1b","name":"亡语触发器二号","text":"触发所有友方随从的亡语","type":"MINION"},
          {"id":"BC_1","name":"普通战吼","text":"<b>战吼：</b>造成1点伤害","type":"MINION"},
          {"id":"BC_R","name":"战吼重复","text":"你的<b>战吼</b>会触发两次","type":"MINION"},
          {"id":"BC_Rb","name":"战吼重复二号","text":"你的<b>战吼</b>会触发两次","type":"MINION"},
          {"id":"DRG_1","name":"小龙","race":"DRAGON","text":"飞行","type":"MINION"},
          {"id":"DRG_S","name":"龙联动","text":"若你手牌中有<b>龙</b>牌，则获得+2攻击力","type":"MINION"},
          {"id":"PLAIN","name":"白板","text":"没有什么特别的效果","type":"MINION"}
        ]
        """
        let catalog = try CardCatalog(jsonData: Data(json.utf8))

        #expect(catalog.mechanics(for: "DR_1").contains(.deathrattle))
        #expect(catalog.mechanics(for: "TRIG_1").contains(.deathrattleTrigger))
        // amplifier texts must not also count as the base mechanic
        #expect(!catalog.mechanics(for: "TRIG_1").contains(.deathrattle))
        #expect(catalog.mechanics(for: "BC_1").contains(.battlecry))
        #expect(catalog.mechanics(for: "BC_R").contains(.battlecryRepeat))
        // a battlecry-repeater is not itself a battlecry target
        #expect(!catalog.mechanics(for: "BC_R").contains(.battlecry))
        #expect(catalog.mechanics(for: "DRG_1").contains(.dragon))
        #expect(catalog.mechanics(for: "DRG_S").contains(.dragonSynergy))
        #expect(catalog.mechanics(for: "PLAIN").isEmpty)

        // complementary pairs light up as combos both directions
        #expect(catalog.hasCombo("DR_1", with: "TRIG_1"))
        #expect(catalog.hasCombo("TRIG_1", with: "DR_1"))
        #expect(catalog.hasCombo("BC_1", with: "BC_R"))
        #expect(catalog.hasCombo("DRG_1", with: "DRG_S"))
        // two amplifiers (or two bases) of the same family are NOT a combo
        #expect(!catalog.hasCombo("TRIG_1", with: "TRIG_1b"))
        #expect(!catalog.hasCombo("BC_R", with: "BC_Rb"))
        // same-tag cards or unrelated cards are not combos
        #expect(!catalog.hasCombo("DR_1", with: "BC_1"))
        #expect(!catalog.hasCombo("DR_1", with: "DR_1"))
    }

    @Test
    func should_pair_tribes_and_spell_damage_as_combos() throws {
        let json = """
        [
          {"id":"MECH_1","name":"机械随从","race":"MECHANICAL","text":"磁力","type":"MINION"},
          {"id":"MECH_S","name":"机械联动","text":"你的机械获得+1/+1","type":"MINION"},
          {"id":"MUR_1","name":"鱼人随从","race":"MURLOC","text":"冲锋","type":"MINION"},
          {"id":"MUR_S","name":"鱼人联动","text":"你的其他鱼人获得+2生命值","type":"MINION"},
          {"id":"SD_1","name":"法伤随从","text":"法术伤害+2","type":"MINION"},
          {"id":"DMG_1","name":"火球术","text":"造成6点伤害","type":"SPELL"}
        ]
        """
        let catalog = try CardCatalog(jsonData: Data(json.utf8))

        #expect(catalog.mechanics(for: "MECH_1").contains(.mech))
        #expect(catalog.mechanics(for: "MECH_S").contains(.mechSynergy))
        #expect(catalog.hasCombo("MECH_1", with: "MECH_S"))
        #expect(catalog.mechanics(for: "MUR_1").contains(.murloc))
        #expect(catalog.hasCombo("MUR_1", with: "MUR_S"))
        #expect(catalog.mechanics(for: "SD_1").contains(.spellDamage))
        #expect(catalog.mechanics(for: "DMG_1").contains(.damageSpell))
        #expect(catalog.hasCombo("SD_1", with: "DMG_1"))
        // tribes are cross-family independent
        #expect(!catalog.hasCombo("MECH_1", with: "MUR_S"))
    }
}

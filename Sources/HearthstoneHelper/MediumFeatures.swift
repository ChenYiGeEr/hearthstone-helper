import AppKit
import ApplicationServices
import SwiftUI
import HearthstoneCore

// MARK: - Opponent inference

enum InferenceConfidence: String {
    case known
    case inferred
    case unknown

    var title: String {
        switch self {
        case .known: HearthChrome.L("已知", "Known")
        case .inferred: HearthChrome.L("推测", "Inferred")
        case .unknown: HearthChrome.L("未知", "Unknown")
        }
    }
}

struct InferenceLine: Identifiable {
    let id: String
    let name: String
    let detail: String
    let confidence: InferenceConfidence
}

enum OpponentInference {
    /// Shown cards were revealed by the log. Cards still sitting in the deck
    /// with a name are known. A second copy is only a guess when the card is
    /// not legendary and we have seen fewer than two. Unnamed deck slots stay unknown.
    static func lines(cards: [TrackedCard], deckCount: Int?, catalog: CardCatalog?) -> (shown: [InferenceLine], unseen: Int, likely: [InferenceLine]) {
        let shownCards = cards.filter { $0.currentZone != "DECK" }
        let inDeck = cards.filter { $0.currentZone == "DECK" }
        let shown = shownCards.map { card in
            InferenceLine(
                id: "shown-\(card.cardID ?? card.name)",
                name: display(card, catalog: catalog),
                detail: "×\(card.copies)",
                confidence: .known
            )
        }
        var likely = inDeck.map { card in
            InferenceLine(
                id: "deck-\(card.cardID ?? card.name)",
                name: display(card, catalog: catalog),
                detail: HearthChrome.L("仍在牌库 ×\(card.copies)", "still in deck ×\(card.copies)"),
                confidence: .known
            )
        }
        let knownDeckCopies = inDeck.reduce(0) { $0 + $1.copies }
        let unseen = max(0, (deckCount ?? knownDeckCopies) - knownDeckCopies)
        for card in cards where card.origin == .original {
            let id = card.cardID ?? card.name
            let cap = catalog?.rarity(for: id) == "LEGENDARY" ? 1 : 2
            let extra = cap - card.copies
            guard extra > 0 else { continue }
            likely.append(InferenceLine(
                id: "maybe-\(id)",
                name: display(card, catalog: catalog),
                detail: HearthChrome.L("可能还有 \(extra) 张", "maybe \(extra) more"),
                confidence: .inferred
            ))
        }
        return (shown, unseen, likely)
    }

    private static func display(_ card: TrackedCard, catalog: CardCatalog?) -> String {
        let id = card.cardID ?? card.name
        return catalog?.displayName(for: id) ?? card.name
    }
}

struct OpponentInferenceView: View {
    let cards: [TrackedCard]
    let deckCount: Int?
    let catalog: CardCatalog?
    var extraOnly: Bool = false

    var body: some View {
        if extraOnly {
            extraBody
        } else if cards.isEmpty && (deckCount ?? 0) == 0 {
            EmptyView()
        } else {
            inferenceBody
        }
    }

    /// Overlay mode: the zone lists already show revealed and in-deck cards.
    /// Only the guessed second copies are extra.
    @ViewBuilder
    private var extraBody: some View {
        let lines = OpponentInference.lines(cards: cards, deckCount: deckCount, catalog: catalog)
            .likely.filter { $0.confidence == .inferred }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(HearthChrome.L("推测还可能有", "Maybe still in deck"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.gold)
                    .help(HearthChrome.L(
                        "非传说且只见过一张。没有对上完整牌库，所以只是猜测。",
                        "Non-legendary and seen once. The deck list was not matched, so this is a guess."
                    ))
                ForEach(lines.prefix(6)) { row in
                    HStack(spacing: 4) {
                        Text(row.name).lineLimit(1).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hearthText)
                        Spacer(minLength: 4)
                        Text(row.detail).font(.caption2).foregroundStyle(Color.mist)
                        Text(InferenceConfidence.inferred.title)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.onGold)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var inferenceBody: some View {
        let built = OpponentInference.lines(cards: cards, deckCount: deckCount, catalog: catalog)
        return VStack(alignment: .leading, spacing: 6) {
            Text(HearthChrome.L("对手牌推断", "Opponent inference"))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.hearthText)
            Text(HearthChrome.L(
                "已知 = 日志里亮出过。推测 = 非传说牌按最多两张猜还剩一张，没有对上牌库。未知 = 牌库里还没名字的张数。",
                "Known = revealed in the log. Inferred = a non-legendary card might still have a second copy; the deck list was not matched. Unknown = unnamed cards left in the deck."
            ))
            .font(.system(size: 9))
            .foregroundStyle(Color.mist)
            .fixedSize(horizontal: false, vertical: true)
            if deckCount == nil {
                Text(HearthChrome.L(
                    "这场记录没有牌库张数，所以不显示尚未见到的张数。",
                    "This record has no deck size, so unnamed cards are omitted."
                ))
                .font(.system(size: 9))
                .foregroundStyle(Color.mist)
            }
            bucket(HearthChrome.L("已亮出", "Shown"), built.shown)
            if built.unseen > 0 {
                HStack {
                    Text(HearthChrome.L("尚未见到", "Not yet seen"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.hearthText)
                    Spacer()
                    Text("×\(built.unseen)")
                        .font(.caption2.monospacedDigit())
                    confidence(.unknown)
                }
            }
            bucket(HearthChrome.L("可能还在牌库", "Likely remaining"), built.likely)
        }
        .padding(8)
        .background(Color.inkDeep.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func bucket(_ title: String, _ rows: [InferenceLine]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.gold)
            if !rows.isEmpty {
                ForEach(rows.prefix(8)) { row in
                    HStack(spacing: 4) {
                        Text(row.name).lineLimit(1).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hearthText)
                        Spacer(minLength: 4)
                        Text(row.detail).font(.caption2.monospacedDigit()).foregroundStyle(Color.mist)
                        confidence(row.confidence)
                    }
                }
            }
        }
    }

    private func confidence(_ kind: InferenceConfidence) -> some View {
        Text(kind.title)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(kind == .inferred ? Color.onGold : Color.hearthText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background((kind == .inferred ? Color.gold : Color.mist).opacity(0.25), in: Capsule())
    }
}

// MARK: - Mulligan advice

enum MulliganAdvice {
    struct Hint: Identifiable {
        let id: String
        let name: String
        let keep: Bool
        let reason: String
    }

    /// Cost heuristic only. Coin is kept. One and two drops are kept.
    /// A three drop is kept when the hand is not already full of cheap cards.
    /// Four and above are tossed.
    static func hints(cardIDs: [String], catalog: CardCatalog?) -> [Hint] {
        let costs = cardIDs.map { id -> (String, Int) in
            (id, catalog?.cost(for: id) ?? 0)
        }
        let cheap = costs.filter { $0.0 != "GAME_005" && $0.1 <= 2 }.count
        return costs.enumerated().map { index, item in
            let id = item.0
            let cost = item.1
            let name = catalog?.displayName(for: id) ?? id
            if id == "GAME_005" {
                return Hint(id: "\(id)#\(index)", name: name, keep: true, reason: HearthChrome.L("幸运币留着", "Keep the coin"))
            }
            if cost <= 2 {
                return Hint(id: "\(id)#\(index)", name: name, keep: true, reason: HearthChrome.L("低费，建议留", "Low cost, keep"))
            }
            if cost == 3 && cheap < 2 {
                return Hint(id: "\(id)#\(index)", name: name, keep: true, reason: HearthChrome.L("低费不够，这张三费可留", "Few cheap cards, keep this 3"))
            }
            return Hint(id: "\(id)#\(index)", name: name, keep: false, reason: HearthChrome.L("费用偏高，建议换", "Expensive, mulligan"))
        }
    }
}

struct MulliganAdviceView: View {
    let hints: [MulliganAdvice.Hint]

    var body: some View {
        let keep = hints.filter(\.keep).map(\.name).joined(separator: " ")
        let toss = hints.filter { !$0.keep }.map(\.name).joined(separator: " ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !keep.isEmpty {
                Text(HearthChrome.L("留", "Keep"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.mint)
                Text(keep)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hearthText)
                    .lineLimit(2)
            }
            if !toss.isEmpty {
                Text(HearthChrome.L("换", "Toss"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.gold)
                Text(toss)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hearthText)
                    .lineLimit(2)
            }
        }
        .help(HearthChrome.L("只按费用，不是胜率模型。", "Cost only, not a win-rate model."))
    }
}

// MARK: - Pace

struct PaceCompareView: View {
    let curve: [Int]
    let turns: [TurnLog]
    var compact: Bool = false

    var body: some View {
        let points = turns.map { turn in
            (turn.turn, turn.friendlyPlays.reduce(0) { $0 + $1.cost * max($1.copies, 1) }, min(max(turn.turn, 1), 10))
        }
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            if !compact {
                Text(HearthChrome.L("构筑曲线与本局节奏", "Curve vs pace"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.hearthText)
                Text(HearthChrome.L(
                    "灰条是该回合可用法力（回合数，最高 10）。金条是本局打出牌的费用合计，不含英雄技能。",
                    "Gray is mana available that turn (turn number, max 10). Gold is the cost of cards you played, not hero power."
                ))
                .font(.system(size: 9))
                .foregroundStyle(Color.mist)
                .fixedSize(horizontal: false, vertical: true)
                if !curve.isEmpty {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(curve.prefix(8).enumerated()), id: \.offset) { index, count in
                            VStack(spacing: 1) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.gold.opacity(0.8))
                                    .frame(height: CGFloat(max(count, 0)) * 4 + 2)
                                Text(index == 7 ? "7+" : "\(index)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.mist)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 42)
                }
            }
            if points.isEmpty && !compact {
                Text(HearthChrome.L("本局还没有打出记录", "No plays recorded yet"))
                    .font(.caption2)
                    .foregroundStyle(Color.mist)
            } else if !points.isEmpty {
                ForEach(compact ? Array(points.suffix(6)) : points, id: \.0) { turn, spent, available in
                    HStack(spacing: 6) {
                        Text("T\(turn)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(Color.gold)
                            .frame(width: 28, alignment: .leading)
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            let availW = width * CGFloat(available) / 10
                            let spentW = width * CGFloat(min(spent, 12)) / 10
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.mist.opacity(0.25)).frame(width: availW)
                                Capsule().fill(spent > available ? Color.gold : Color.mint).frame(width: max(spentW, spent > 0 ? 4 : 0))
                            }
                        }
                        .frame(height: 6)
                        Text("\(spent)/\(available)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.mist)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(compact ? 2 : 8)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.inkDeep.opacity(0.45))
            }
        }
        .help(HearthChrome.L(
            "灰条是可用法力，金条是打出牌的费用，不含英雄技能。",
            "Gray is mana available. Gold is the cost of cards played, not hero power."
        ))
    }
}

// MARK: - Rank trajectory

enum RankLog {
    struct Sample: Codable, Identifiable, Equatable {
        var date: Date
        var leagueID: Int
        var stars: Int
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/rank-log.json")
    }

    static func record(leagueID: Int?, stars: Int?) {
        guard let leagueID, (0...5).contains(leagueID) else { return }
        var all = load()
        let sample = Sample(date: Date(), leagueID: leagueID, stars: max(stars ?? 0, 0))
        if let last = all.last, last.leagueID == sample.leagueID, last.stars == sample.stars { return }
        if let last = all.last, Calendar.current.isDate(last.date, inSameDayAs: sample.date) {
            all[all.count - 1] = sample
        } else {
            all.append(sample)
        }
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        all = all.filter { $0.date >= cutoff }
        save(all)
    }

    static func recent() -> [Sample] {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        return load().filter { $0.date >= cutoff }
    }

    static func score(_ sample: Sample) -> Int {
        sample.leagueID * 20 + min(sample.stars, 15)
    }

    private static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data) else { return [] }
        return decoded
    }

    private static func save(_ samples: [Sample]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

struct RankTrajectoryCard: View {
    let store: MatchStore

    var body: some View {
        let _ = store.live.localLeagueID
        let samples = RankLog.recent()
        VStack(alignment: .leading, spacing: 6) {
            Text(HearthChrome.L("段位走势", "Rank trajectory"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.hearthText)
            Text(HearthChrome.L(
                "最近 90 天里，每次对局读到的本机天梯段位记一个点。没有官方赛季分界，同一天只留最后一次。纵轴是段位×20+星数，只看升降。",
                "Each match records the local ladder rank seen in the last 90 days. There is no official season boundary; one point per day, the last reading. Height is league×20+stars, only for direction."
            ))
            .font(.caption2)
            .foregroundStyle(Color.mist)
            .fixedSize(horizontal: false, vertical: true)
            if samples.isEmpty {
                Text(HearthChrome.L("还没有段位记录。打一局天梯后会出现。", "No rank samples yet. Play a ranked game."))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                let peak = max(samples.map(RankLog.score).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(samples.suffix(24)), id: \.id) { sample in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gold)
                                .frame(height: max(8, CGFloat(RankLog.score(sample)) / CGFloat(peak) * 48))
                            Text(HearthChrome.league(MirrorLiveStore.leagueName(sample.leagueID) ?? "?").prefix(1))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.mist)
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(HearthChrome.league(MirrorLiveStore.leagueName(sample.leagueID) ?? "?")) ★\(sample.stars)")
                    }
                }
                .frame(height: 64)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
    }
}

// MARK: - Updates

enum AppRelease {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0"
    }

    static let notes = """
    0.9.0
    · 深色 / 浅色 / 跟随系统，中英文，动效开关
    · 浮窗布局、收藏、标签、本地导入代码
    · 对局搜索、筛选和备注
    · 对手牌推断、起手费用建议、节奏对比、段位走势
    · 手动检查 GitHub 版本，以及一键诊断
    """

    struct Remote: Equatable {
        var tag: String
        var body: String
        var url: URL
    }

    static func isNewer(_ remote: String, than local: String) -> Bool? {
        func parts(_ raw: String) -> [Int]? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let numbers = trimmed.split(separator: ".").map { Int($0) }
            guard numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 }
        }
        guard var left = parts(remote), var right = parts(local) else { return nil }
        let count = max(left.count, right.count)
        left += Array(repeating: 0, count: count - left.count)
        right += Array(repeating: 0, count: count - right.count)
        for index in 0..<count {
            if left[index] != right[index] { return left[index] > right[index] }
        }
        return false
    }

    static func check() async -> Remote? {
        guard let url = URL(string: "https://api.github.com/repos/ChenYiGeEr/hearthstone-helper/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("HearthstoneHelper", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = json["html_url"] as? String,
              let pageURL = URL(string: page)
        else { return nil }
        return Remote(tag: tag, body: json["body"] as? String ?? "", url: pageURL)
    }
}

struct UpdateNotesSection: View {
    @State private var status = ""
    @State private var remote: AppRelease.Remote?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HearthChrome.L("当前版本 \(AppRelease.current)", "Current version \(AppRelease.current)"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.mist)
            Text(AppRelease.notes)
                .font(.caption)
                .foregroundStyle(Color.hearthText)
                .fixedSize(horizontal: false, vertical: true)
            Button(HearthChrome.L("检查更新", "Check for updates")) {
                Task { await lookUp() }
            }
            .buttonStyle(.bordered)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Color.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remote {
                Button(HearthChrome.L("打开发布页", "Open release")) {
                    NSWorkspace.shared.open(remote.url)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gold)
            }
            Text(HearthChrome.L(
                "检查更新只读 GitHub 上的公开 Release，不需要密钥。装新版本请重新运行 scripts/deploy.sh，或从发布页下载。",
                "The check only reads the public GitHub Release. No token. Install by re-running scripts/deploy.sh, or download from the release page."
            ))
            .font(.caption2)
            .foregroundStyle(Color.mist)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lookUp() async {
        status = HearthChrome.L("正在检查…", "Checking…")
        remote = nil
        guard let found = await AppRelease.check() else {
            status = HearthChrome.L("没有读到 Release。下面仍是内置说明。", "No release could be read. The notes above are built in.")
            return
        }
        remote = found
        if let newer = AppRelease.isNewer(found.tag, than: AppRelease.current) {
            status = newer
                ? HearthChrome.L("发现 \(found.tag)。\(found.body)", "Found \(found.tag). \(found.body)")
                : HearthChrome.L("已是最新（\(found.tag)）。", "Up to date (\(found.tag)).")
            if !newer { remote = nil }
        } else {
            status = HearthChrome.L("读到 \(found.tag)，但版本号对不上，请自己看发布页。", "Saw \(found.tag), but the version text could not be compared.")
        }
    }
}

// MARK: - Diagnostics

@MainActor
enum DiagnosticsReport {
    @MainActor
    static func text(store: MatchStore) -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper")
        var lines: [String] = []
        lines.append("HearthstoneHelper \(AppRelease.current)")
        lines.append(HearthChrome.L("状态", "Status") + ": \(String(describing: store.status))")
        lines.append("log.config: \(HearthstoneLogLocator.isLogConfigPresent() ? "yes" : "no")")
        for directory in HearthstoneLogLocator.powerLogDirectories {
            let exists = FileManager.default.fileExists(atPath: directory.path)
            lines.append("logs \(directory.path): \(exists ? "yes" : "no")")
        }
        lines.append("Accessibility: \(AXIsProcessTrusted() ? "yes" : "no")")
        lines.append("mirror attached: \(store.mirror.isAttached ? "yes" : "no")")
        lines.append("memory stage: \(store.memory.stage)")
        lines.append("live attached: \(store.live.attached ? "yes" : "no")")
        lines.append("battleTag: \(store.live.battleTag ?? "-")")
        lines.append("--- memory_debug.log ---")
        lines.append(tail(support.appendingPathComponent("memory_debug.log")))
        lines.append("--- mirror.log ---")
        lines.append(tail(support.appendingPathComponent("mirror.log")))
        return lines.joined(separator: "\n")
    }

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper")
    }

    private static func tail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "(missing)" }
        return text.split(separator: "\n").suffix(12).joined(separator: "\n")
    }
}

struct DiagnosticsSection: View {
    let store: MatchStore
    @State private var report = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HearthChrome.L(
                "汇总日志位置、辅助功能权限、内存附着状态，以及最近的错误片段。不会重新去附着炉石。",
                "Shows log paths, Accessibility, and whether memory attach is ready, plus recent lines. It does not attach to Hearthstone again."
            ))
            .font(.caption2)
            .foregroundStyle(Color.mist)
            .fixedSize(horizontal: false, vertical: true)
            Text(report.isEmpty ? HearthChrome.L("点下面生成报告", "Generate a report below") : report)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.hearthText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(HearthChrome.L("生成并复制", "Copy report")) {
                    report = DiagnosticsReport.text(store: store)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .buttonStyle(.bordered)
                Button(HearthChrome.L("打开日志文件夹", "Open log folder")) {
                    let folder = DiagnosticsReport.supportFolder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                .buttonStyle(.bordered)
                Button(HearthChrome.L("打开控制台", "Open Console")) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            if report.isEmpty { report = DiagnosticsReport.text(store: store) }
        }
    }
}

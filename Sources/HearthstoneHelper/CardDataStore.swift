import Foundation
import HearthstoneCore

/// Downloads and caches the public HearthstoneJSON card dump (zhCN locale).
/// Per the confirmed privacy design this is the app's ONLY network access;
/// nothing recorded locally is ever uploaded.
@MainActor
@Observable
final class CardDataStore {
    enum State: Equatable {
        case missing
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .missing
    private(set) var catalog: CardCatalog?

    private static let sourceURL = URL(
        string: "https://api.hearthstonejson.com/v1/latest/zhCN/cards.json"
    )!

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/cards-zhCN.json")
    }

    func bootstrap() async {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let parsed = try? await Self.parse(data) {
            catalog = parsed
            state = .ready
            return
        }
        await download()
    }

    func download() async {
        state = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.sourceURL)
            let parsed = try await Self.parse(data)
            try FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.cacheURL, options: .atomic)
            catalog = parsed
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// A 10MB JSON parse must not run on the render loop.
    private static func parse(_ data: Data) async throws -> CardCatalog {
        try await Task.detached(priority: .userInitiated) {
            try CardCatalog(jsonData: data)
        }.value
    }
}

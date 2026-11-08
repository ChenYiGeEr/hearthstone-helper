import AppKit
import Foundation
import Observation

/// Full-card renders from HearthstoneJSON (official art, zhCN localization —
/// exactly what the game shows), downloaded once and cached on disk forever.
/// Also produces the horizontal name-band strip used as row backgrounds.
/// Two channels: 256px for overlays/deck rows, 512px HD for the collection
/// browser; decoding happens off the main thread.
@MainActor
@Observable
final class CardImageStore {
    private(set) var images: [String: NSImage] = [:]
    private(set) var strips: [String: NSImage] = [:]
    private(set) var thumbs: [String: NSImage] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]

    // HD channel (512px renders), separate cache directory
    private(set) var hdImages: [String: NSImage] = [:]
    private var hdInflight: [String: Task<Void, Never>] = [:]

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/CardImages", isDirectory: true)
    }

    private static var hdCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/CardImagesHD", isDirectory: true)
    }

    private static func renderSource(for cardID: String, hd: Bool) -> URL {
        let size = hd ? "512x" : "256x"
        return URL(string: "https://art.hearthstonejson.com/v1/render/latest/zhCN/\(size)/\(cardID).png")!
    }

    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    func fullImage(for cardID: String) -> NSImage? {
        if images[cardID] != nil { return images[cardID] }
        load(cardID)
        return nil
    }

    func strip(for cardID: String) -> NSImage? {
        if strips[cardID] != nil { return strips[cardID] }
        load(cardID)
        return nil
    }

    /// Small card-face crop (the art region) for Firestone-style row thumbnails.
    func thumb(for cardID: String) -> NSImage? {
        if thumbs[cardID] != nil { return thumbs[cardID] }
        load(cardID)
        return nil
    }

    /// Kick off loads for every card a panel might render; deduplicated internally.
    func prefetch(_ cardIDs: [String]) {
        for cardID in Set(cardIDs) where !cardID.isEmpty {
            load(cardID)
        }
    }

    /// High-definition channel for the collection browser grid.
    func hdImage(for cardID: String) -> NSImage? {
        if hdImages[cardID] != nil { return hdImages[cardID] }
        loadHD(cardID)
        return nil
    }

    func prefetchHD(_ cardIDs: [String]) {
        for cardID in Set(cardIDs) where !cardID.isEmpty {
            loadHD(cardID)
        }
    }

    private func load(_ cardID: String) {
        guard images[cardID] == nil, inflight[cardID] == nil else { return }

        inflight[cardID] = Task { [weak self] in
            defer { self?.inflight[cardID] = nil }
            guard let self else { return }

            if let image = await Self.fetch(
                cardID: cardID, hd: false, cacheDirectory: Self.cacheDirectory
            ) {
                self.images[cardID] = image
                self.strips[cardID] = Self.nameBandStrip(from: image)
                self.thumbs[cardID] = Self.artThumb(from: image)
            }
        }
    }

    private func loadHD(_ cardID: String) {
        guard hdImages[cardID] == nil, hdInflight[cardID] == nil else { return }

        hdInflight[cardID] = Task { [weak self] in
            defer { self?.hdInflight[cardID] = nil }
            guard let self else { return }

            if let image = await Self.fetch(
                cardID: cardID, hd: true, cacheDirectory: Self.hdCacheDirectory
            ) {
                self.hdImages[cardID] = image
            }
        }
    }

    /// Download (or read from disk) and decode off the main thread — the
    /// browser page is 48 renders at once and decoding them on main stutters
    /// scrolling badly.
    private static func fetch(
        cardID: String,
        hd: Bool,
        cacheDirectory: URL
    ) async -> NSImage? {
        let fileURL = cacheDirectory.appendingPathComponent("\(cardID).png")
        var data: Data?

        if let cached = try? Data(contentsOf: fileURL),
           [UInt8](cached.prefix(8)) == pngMagic {
            data = cached
        } else if let (downloaded, _) = try? await URLSession.shared.data(
            from: renderSource(for: cardID, hd: hd)
        ), [UInt8](downloaded.prefix(8)) == pngMagic {
            data = downloaded
            try? FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try? downloaded.write(to: fileURL, options: .atomic)
        }

        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            NSImage(data: data)
        }.value
    }

    /// Crops the art region (top ~45%) of a render into a mini card-face thumb.
    private static func artThumb(from image: NSImage) -> NSImage? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: width * 0.04,
            y: height * (1 - 0.45),
            width: width * 0.92,
            height: height * 0.45
        )
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 96, height: 96 * 0.45 * height / width))
    }

    /// Crops the card-name banner band out of a full render; CG coordinates are
    /// bottom-up while the plate sits at roughly 52–66% from the top of the card.
    private static func nameBandStrip(from image: NSImage) -> NSImage? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let bandTopFraction: CGFloat = 0.66
        let bandHeightFraction: CGFloat = 0.14
        let bandRect = CGRect(
            x: 0,
            y: height * (1 - bandTopFraction),
            width: width,
            height: height * bandHeightFraction
        )
        guard let cropped = cgImage.cropping(to: bandRect) else { return nil }

        let strip = NSImage(
            cgImage: cropped,
            size: NSSize(width: 256, height: 256 * bandHeightFraction)
        )
        return strip
    }
}

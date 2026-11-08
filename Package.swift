// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HearthstoneHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HearthstoneCore", targets: ["HearthstoneCore"]),
        .executable(name: "HearthstoneHelper", targets: ["HearthstoneHelper"])
    ],
    targets: [
        .binaryTarget(name: "HearthMirror", path: "vendor/HearthMirror.xcframework"),
        .target(name: "MirrorGuardC", path: "Sources/MirrorGuardC"),
        .target(
            name: "HearthstoneCore",
            path: "Sources/HearthstoneHelper",
            exclude: ["DashboardView.swift", "HearthstoneHelperApp.swift", "CardDataStore.swift", "CardImageStore.swift", "CollectionBrowser.swift", "DeckLibrary.swift", "DeckMarks.swift", "HearthChrome.swift", "LifecycleAutomation.swift", "LogPipeline.swift", "MatchHistory.swift", "MatchStore.swift", "MediumFeatures.swift", "MirrorBridge.swift", "MirrorFaultGuard.swift", "MirrorLiveStore.swift", "MirrorMemory.swift", "OverlayPanels.swift", "OverlayWindowManager.swift"],
            sources: ["CardCatalog.swift", "DeckCode.swift", "DecksLog.swift", "MatchModels.swift", "MatchSessionTracker.swift", "PowerLogParser.swift"]
        ),
        .executableTarget(
            name: "HearthstoneHelper",
            dependencies: ["HearthstoneCore", "HearthMirror", "MirrorGuardC"],
            path: "Sources/HearthstoneHelper",
            exclude: ["CardCatalog.swift", "DeckCode.swift", "DecksLog.swift", "MatchModels.swift", "MatchSessionTracker.swift", "PowerLogParser.swift"],
            sources: [
                "CardDataStore.swift",
                "CardImageStore.swift",
                "CollectionBrowser.swift",
                "DashboardView.swift",
                "DeckLibrary.swift",
                "DeckMarks.swift",
                "HearthChrome.swift",
                "HearthstoneHelperApp.swift",
                "LifecycleAutomation.swift",
                "LogPipeline.swift",
                "MatchHistory.swift",
                "MatchStore.swift",
                "MediumFeatures.swift",
                "MirrorBridge.swift",
                "MirrorFaultGuard.swift",
                "MirrorLiveStore.swift",
                "MirrorMemory.swift",
                "OverlayPanels.swift",
                "OverlayWindowManager.swift"
            ]
        ),
        .testTarget(name: "HearthstoneHelperTests", dependencies: ["HearthstoneCore"])
    ]
)

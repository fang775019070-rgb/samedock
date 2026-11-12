// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "EchoDock", platforms: [.macOS(.v13)], targets: [
    .executableTarget(name: "EchoDock", path: "EchoDock", exclude: ["Resources"]),
    .testTarget(name: "EchoDockTests", dependencies: ["EchoDock"], path: "EchoDockTests", sources: [
        "NativeDock/NativeDockContentSyncTests.swift",
        "NativeDock/NativeDockPrivacyTests.swift",
        "NativeDock/NativeDockCollapseTests.swift",
        "Displays/NativeDockPlacementTests.swift",
        "Displays/NativeDockAutomaticTargetTests.swift",
        "Displays/WindowReservationBehaviorTests.swift",
        "Files/DockFileOperatorTests.swift",
        "NativeDock/NativeDockThumbnailTests.swift",
        "Dock/DockIncrementalRefreshTests.swift",
        "App/ApplicationTerminationDeliveryTests.swift",
        "Dock/DockTrashIconTests.swift",
        "Dock/DockWindowLevelTests.swift",
        "Dock/DockPanelContentAnchorTests.swift",
        "Displays/WindowAppearingReservationTests.swift",
                "Displays/WindowClearanceTriggerTests.swift"
    ])
])

//
//  Domain.swift
//  XcodeCacheCleaner
//
//  领域模型：分类、快照、Runtime 等。
//

import Foundation

// MARK: - Preferences

struct Preferences: Codable, Equatable {
    var scanIntervalSeconds: TimeInterval
    var autoCleanSchedule: AutoCleanSchedule
    var categories: [CacheCategoryPreference]
    
    static var defaultValue: Preferences {
        Preferences(
            scanIntervalSeconds: 30 * 60,
            autoCleanSchedule: .off,
            categories: CacheCategoryPreference.defaultCategories
        )
    }
}

enum AutoCleanSchedule: String, Codable, CaseIterable, Identifiable {
    case off
    case every1h
    case every4h
    case every12h
    case every24h
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .off: return String(localized: "schedule.off")
        case .every1h: return String(localized: "schedule.every1h")
        case .every4h: return String(localized: "schedule.every4h")
        case .every12h: return String(localized: "schedule.every12h")
        case .every24h: return String(localized: "schedule.every24h")
        }
    }
    
    var intervalSeconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .every1h: return 1 * 60 * 60
        case .every4h: return 4 * 60 * 60
        case .every12h: return 12 * 60 * 60
        case .every24h: return 24 * 60 * 60
        }
    }
}

struct CacheCategoryPreference: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var description: String
    /// 用于统计体积的路径（即便该分类的清理方式是 command，也应该能统计出占用）
    var scanPaths: [String]?
    var includedInOneTapClean: Bool
    var action: CleanActionDefinition
    
    static let defaultCategories: [CacheCategoryPreference] = [
        .init(
            id: "derivedData",
            title: "category.derivedData.title",
            description: "category.derivedData.desc",
            scanPaths: ["~/Library/Developer/Xcode/DerivedData"],
            includedInOneTapClean: true,
            action: .itemList
        ),
        .init(
            id: "xcodeCaches",
            title: "category.xcodeCaches.title",
            description: "category.xcodeCaches.desc",
            scanPaths: ["~/Library/Caches/com.apple.dt.Xcode"],
            includedInOneTapClean: true,
            action: .deletePaths(["~/Library/Caches/com.apple.dt.Xcode"])
        ),
        .init(
            id: "simulatorLogsCaches",
            title: "category.simulatorLogsCaches.title",
            description: "category.simulatorLogsCaches.desc",
            scanPaths: [
                "~/Library/Logs/CoreSimulator",
                "~/Library/Caches/com.apple.CoreSimulator",
                "~/Library/Developer/CoreSimulator/Temp",
                "~/Library/Developer/CoreSimulator/Caches",
            ],
            includedInOneTapClean: true,
            action: .itemList
        ),
        .init(
            id: "swiftuiPreviews",
            title: "category.swiftuiPreviews.title",
            description: "category.swiftuiPreviews.desc",
            scanPaths: ["~/Library/Developer/Xcode/UserData/Previews"],
            includedInOneTapClean: true,
            action: .itemList
        ),
        .init(
            id: "simulatorDevices",
            title: "category.simulatorDevices.title",
            description: "category.simulatorDevices.desc",
            scanPaths: ["~/Library/Developer/CoreSimulator/Devices"],
            includedInOneTapClean: false,
            action: .command(program: "/usr/bin/xcrun", arguments: ["simctl", "erase", "all"])
        ),
        .init(
            id: "unavailableSimulators",
            title: "category.unavailableSimulators.title",
            description: "category.unavailableSimulators.desc",
            scanPaths: nil,
            includedInOneTapClean: true,
            action: .unavailableSimulators
        ),
        .init(
            id: "deviceSupport",
            title: "category.deviceSupport.title",
            description: "category.deviceSupport.desc",
            scanPaths: ["~/Library/Developer/Xcode/iOS DeviceSupport"],
            includedInOneTapClean: false,
            action: .deletePaths(["~/Library/Developer/Xcode/iOS DeviceSupport"])
        ),
        .init(
            id: "deviceLogs",
            title: "category.deviceLogs.title",
            description: "category.deviceLogs.desc",
            scanPaths: ["~/Library/Developer/Xcode/DeviceLogs"],
            includedInOneTapClean: false,
            action: .itemList
        ),
        .init(
            id: "xcodeProducts",
            title: "category.xcodeProducts.title",
            description: "category.xcodeProducts.desc",
            scanPaths: ["~/Library/Developer/Xcode/Products"],
            includedInOneTapClean: false,
            action: .itemList
        ),
        .init(
            id: "archives",
            title: "category.archives.title",
            description: "category.archives.desc",
            scanPaths: ["~/Library/Developer/Xcode/Archives"],
            includedInOneTapClean: false,
            action: .archives
        ),
        .init(
            id: "xcodeLogs",
            title: "category.xcodeLogs.title",
            description: "category.xcodeLogs.desc",
            scanPaths: ["~/Library/Developer/Xcode/Logs"],
            includedInOneTapClean: false,
            action: .deletePaths(["~/Library/Developer/Xcode/Logs"])
        ),
        .init(
            id: "swiftpm",
            title: "category.swiftpm.title",
            description: "category.swiftpm.desc",
            scanPaths: [
                "~/Library/Caches/org.swift.swiftpm",
                "~/Library/Caches/swift-package",
                "~/Library/org.swift.swiftpm",
                "~/Library/Developer/Xcode/SourcePackages",
            ],
            includedInOneTapClean: false,
            action: .itemList
        ),
        .init(
            id: "runtimes",
            title: "category.runtimes.title",
            description: "category.runtimes.desc",
            scanPaths: nil,
            includedInOneTapClean: true,
            action: .runtimes
        ),
    ]
}

enum CleanActionDefinition: Codable, Equatable {
    case deletePaths([String])
    case command(program: String, arguments: [String])
    case runtimes
    case archives
    case itemList
    case unavailableSimulators
}

// MARK: - Snapshot

struct ScanSnapshot: Codable, Equatable {
    var createdAt: Date
    var disk: DiskInfo
    var categories: [CategorySize]
    var runtimesByPlatform: [String: [RuntimeItem]]
    var archiveItems: [ArchiveItem]?
    var itemListsByCategory: [String: [CleanableItem]]?
    var unavailableSimulators: [SimulatorDeviceItem]?
    /// 扫描过程中的非致命错误（例如权限/路径不存在）。key = 分类 id
    var categoryErrors: [String: String]?

    var xcodeTotalBytes: Int64 { categories.reduce(0) { $0 + $1.sizeBytes } }
    var allRuntimes: [RuntimeItem] { runtimesByPlatform.values.flatMap { $0 } }
    var allArchives: [ArchiveItem] { archiveItems ?? [] }
    var allCleanableItems: [CleanableItem] {
        itemListsByCategory?.values.flatMap { $0 } ?? []
    }

    func cleanableItems(for categoryID: String) -> [CleanableItem] {
        itemListsByCategory?[categoryID] ?? []
    }
}

struct DiskInfo: Codable, Equatable {
    var totalBytes: Int64
    var availableBytes: Int64
    
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedPercent: Double { totalBytes == 0 ? 0 : (Double(usedBytes) / Double(totalBytes)) * 100.0 }
}

struct CategorySize: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var sizeBytes: Int64
}

// MARK: - Runtime

struct RuntimeItem: Codable, Equatable, Identifiable {
    var id: String
    var platformIdentifier: String
    var version: String
    var build: String?
    var deletable: Bool?
    var sizeBytes: Int64?
    
    /// 用于删除的参数。
    var deleteArgument: String {
        // `simctl runtime delete` 接收 runtime identifier。新 Xcode 的
        // `simctl runtime list -j` 会给 UUID；旧输出可能是 SimRuntime bundle id。
        id
    }

    /// 选择态 key：和删除参数保持一致，避免 build 相同导致错删/删不掉。
    var deletionKey: String {
        id
    }
}

// MARK: - Archives

struct ArchiveItem: Codable, Equatable, Identifiable {
    var id: String
    var path: String
    var name: String
    var createdAt: Date?
    var sizeBytes: Int64

    var deletionKey: String { path }
}

// MARK: - Cleanable file-system items

struct CleanableItem: Codable, Equatable, Identifiable {
    var id: String
    var categoryID: String
    var path: String
    var name: String
    var detail: String?
    var createdAt: Date?
    var sizeBytes: Int64

    var deletionKey: String { "\(categoryID)|\(path)" }
}

// MARK: - Simulator devices

struct SimulatorDeviceItem: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var runtimeIdentifier: String
    var state: String?
    var availabilityError: String?
    var dataPath: String?
    var sizeBytes: Int64?

    var deletionKey: String { id }
}

// MARK: - Version compare

struct Version: Comparable {
    private let parts: [Int]
    init(_ raw: String) {
        self.parts = raw
            .split(separator: ".")
            .compactMap { Int($0) }
    }
    static func < (lhs: Version, rhs: Version) -> Bool {
        let maxCount = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<maxCount {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

// MARK: - CleanerPlan

struct CleanerPlan {
    var categories: [CacheCategoryPreference]
    var runtimesToDelete: [RuntimeItem]
    var archivesToDelete: [ArchiveItem]
    var cleanableItemsToDelete: [CleanableItem]
    var simulatorDevicesToDelete: [SimulatorDeviceItem]
}

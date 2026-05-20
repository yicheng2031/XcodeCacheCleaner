//
//  Services.swift
//  XcodeCacheCleaner
//
//  扫描与清理服务：使用 du / simctl 做统计与删除。
//

import Foundation

enum ServiceError: LocalizedError {
    case commandFailed(command: String, output: String)
    case invalidOutput(command: String, output: String)
    case multipleFailures([String])

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, output):
            return String(format: String(localized: "error.command_failed.format"), command, output)
        case let .invalidOutput(command, output):
            return String(format: String(localized: "error.invalid_output.format"), command, output)
        case let .multipleFailures(messages):
            return messages.joined(separator: "\n")
        }
    }
}

// MARK: - ProcessRunner

final class ProcessRunner {
    private var cachedDeveloperDir: String?

    /// 统一封装 simctl 调用：使用 xcrun 以获得最佳兼容性（匹配当前选中的 Developer Dir）。
    func runSimctl(_ arguments: [String]) async throws -> String {
        let developerDir = try? await developerDir()
        let env: [String: String] = {
            guard let developerDir, !developerDir.isEmpty else { return [:] }
            return ["DEVELOPER_DIR": developerDir]
        }()
        return try await run("/usr/bin/xcrun", ["simctl"] + arguments, environment: env)
    }

    func run(_ program: String, _ arguments: [String], environment: [String: String]? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            if let environment {
                // 以当前进程环境为基底，避免丢失系统默认环境变量
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { p in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                let merged = ([out, err].filter { !$0.isEmpty }).joined(separator: "\n")

                if p.terminationStatus == 0 {
                    continuation.resume(returning: merged.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: ServiceError.commandFailed(command: Self.displayCommand(program, arguments), output: merged))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func developerDir() async throws -> String? {
        if let cachedDeveloperDir { return cachedDeveloperDir }
        let value = try await run("/usr/bin/xcode-select", ["-p"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cachedDeveloperDir = value.isEmpty ? nil : value
        return cachedDeveloperDir
    }

    nonisolated private static func displayCommand(_ program: String, _ arguments: [String]) -> String {
        ([program] + arguments).map { arg in
            guard arg.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return arg }
            return "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        .joined(separator: " ")
    }
}

// MARK: - DiskInfoService

final class DiskInfoService {
    func readRootDisk() throws -> DiskInfo {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return DiskInfo(totalBytes: total, availableBytes: free)
    }
}

// MARK: - ScannerService

final class ScannerService {
    private let runner = ProcessRunner()
    private let diskInfo = DiskInfoService()

    func scan(preferences: Preferences) async throws -> ScanSnapshot {
        let disk = try diskInfo.readRootDisk()

        // Runtime 可能因为系统/权限策略失败：允许失败但不影响其他结果，但要把错误提示出来。
        var runtimeError: String?
        let runtimes: [String: [RuntimeItem]]
        do {
            runtimes = try await scanRuntimes()
        } catch {
            runtimes = [:]
            runtimeError = (error as NSError).localizedDescription
        }

        var archiveError: String?
        let archiveItems: [ArchiveItem]
        do {
            archiveItems = try await scanArchives()
        } catch {
            archiveItems = []
            archiveError = (error as NSError).localizedDescription
        }

        let itemListsByCategory = try await scanItemLists(for: preferences.categories)
        let unavailableSimulators = try await scanUnavailableSimulators()

        var categoryErrors: [String: String] = [:]
        let categories = try await scanCategories(
            preferences.categories,
            runtimesByPlatform: runtimes,
            archiveItems: archiveItems,
            itemListsByCategory: itemListsByCategory,
            unavailableSimulators: unavailableSimulators,
            categoryErrors: &categoryErrors
        )
        if let runtimeError {
            categoryErrors["runtimes"] = runtimeError
        }
        if let archiveError {
            categoryErrors["archives"] = archiveError
        }

        return ScanSnapshot(
            createdAt: Date(),
            disk: disk,
            categories: categories,
            runtimesByPlatform: runtimes,
            archiveItems: archiveItems,
            itemListsByCategory: itemListsByCategory,
            unavailableSimulators: unavailableSimulators,
            categoryErrors: categoryErrors.isEmpty ? nil : categoryErrors
        )
    }

    private func scanCategories(
        _ categories: [CacheCategoryPreference],
        runtimesByPlatform: [String: [RuntimeItem]],
        archiveItems: [ArchiveItem],
        itemListsByCategory: [String: [CleanableItem]],
        unavailableSimulators: [SimulatorDeviceItem],
        categoryErrors: inout [String: String]
    ) async throws -> [CategorySize] {
        var results: [CategorySize] = []
        results.reserveCapacity(categories.count)

        // 控制并发：简单串行，避免 IO 抢占；后续可做 2~3 并发。
        for cat in categories {
            do {
                let bytes = try await sizeBytes(
                    for: cat,
                    runtimesByPlatform: runtimesByPlatform,
                    archiveItems: archiveItems,
                    itemListsByCategory: itemListsByCategory,
                    unavailableSimulators: unavailableSimulators
                )
                results.append(.init(id: cat.id, title: cat.title, sizeBytes: bytes))
            } catch {
                categoryErrors[cat.id] = (error as NSError).localizedDescription
                results.append(.init(id: cat.id, title: cat.title, sizeBytes: 0))
            }
        }
        return results
    }

    private func sizeBytes(
        for category: CacheCategoryPreference,
        runtimesByPlatform: [String: [RuntimeItem]],
        archiveItems: [ArchiveItem],
        itemListsByCategory: [String: [CleanableItem]],
        unavailableSimulators: [SimulatorDeviceItem]
    ) async throws -> Int64 {
        switch category.action {
        case let .deletePaths(paths):
            return try await duBytes(paths: paths.map(expandTilde))
        case .command:
            // command 类型仍然需要统计“占用”（用户要求不管开关都要扫描）。
            // 使用 scanPaths 作为统计口径；若没有 scanPaths，则返回 0。
            return try await duBytes(paths: (category.scanPaths ?? []).map(expandTilde))
        case .runtimes:
            // Runtime 的体积来自 simctl runtime list -j 的 sizeBytes（如果系统提供）。
            // 若 sizeBytes 缺失则按 0 处理（不同系统版本可能不给）。
            return runtimesByPlatform.values
                .flatMap { $0 }
                .compactMap { $0.sizeBytes }
                .reduce(0, +)
        case .archives:
            return archiveItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        case .itemList:
            return itemListsByCategory[category.id, default: []].reduce(Int64(0)) { $0 + $1.sizeBytes }
        case .unavailableSimulators:
            return unavailableSimulators.compactMap(\.sizeBytes).reduce(Int64(0), +)
        }
    }

    private func duBytes(paths: [String]) async throws -> Int64 {
        let existingPaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existingPaths.isEmpty else { return 0 }

        let output = try await runner.run("/usr/bin/du", ["-sk"] + existingPaths)
        return try output
            .split(separator: "\n")
            .reduce(Int64(0)) { total, line in
                let first = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
                guard let first, let kb = Int64(first) else {
                    throw ServiceError.invalidOutput(command: "du -sk \(existingPaths.joined(separator: " "))", output: output)
                }
                return total + (kb * 1024)
            }
    }

    private func scanRuntimes() async throws -> [String: [RuntimeItem]] {
        // simctl 在不同 Xcode/macOS 版本上命令与 JSON 结构可能不同，这里做多路兜底。
        let candidates: [[String]] = [
            ["runtime", "list", "-j"],          // 新一些的写法
            ["list", "runtimes", "-j"],         // 常见写法（旧版也可能支持）
            ["list", "-j", "runtimes"],         // 另一种参数顺序
        ]

        var output: String?
        var lastError: Error?
        for args in candidates {
            do {
                output = try await runner.runSimctl(args)
                if let output, !output.isEmpty { break }
            } catch {
                lastError = error
            }
        }

        guard let output else { throw (lastError ?? ServiceError.commandFailed(command: "xcrun simctl ...", output: "")) }

        func inferPlatform(from identifier: String) -> String {
            if identifier.contains(".iOS-") { return "com.apple.platform.iphonesimulator" }
            if identifier.contains(".watchOS-") { return "com.apple.platform.watchsimulator" }
            if identifier.contains(".tvOS-") { return "com.apple.platform.appletvsimulator" }
            if identifier.contains(".xrOS-") || identifier.contains(".visionOS-") { return "com.apple.platform.xrsimulator" }
            return "unknown"
        }

        var byPlatform: [String: [RuntimeItem]] = [:]

        func parseTextRuntimes(_ text: String) {
            // 典型行：iOS 18.4 (18.4 - 22E238) - com.apple.CoreSimulator.SimRuntime.iOS-18-4
            for lineSub in text.split(separator: "\n") {
                let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.contains("SimRuntime"), line.contains(" - ") else { continue }
                let parts = line.components(separatedBy: " - ")
                guard parts.count >= 2 else { continue }
                let left = parts[0]
                let id = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let platform = inferPlatform(from: id)

                // version：从左侧提取 “iOS 18.4”
                let version = left
                    .replacingOccurrences(of: "iOS", with: "")
                    .replacingOccurrences(of: "watchOS", with: "")
                    .replacingOccurrences(of: "tvOS", with: "")
                    .replacingOccurrences(of: "xrOS", with: "")
                    .replacingOccurrences(of: "visionOS", with: "")
                    .components(separatedBy: " (").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

                // build：括号内通常是 “18.4 - 22E238” 或 “18.3.1 - 22D8075”，取最后一段作为 build
                var build: String?
                if let start = left.firstIndex(of: "("), let end = left.firstIndex(of: ")"), start < end {
                    let inside = String(left[left.index(after: start)..<end])
                    if let last = inside.components(separatedBy: " - ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !last.isEmpty {
                        build = last
                    } else {
                        build = inside.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                byPlatform[platform, default: []].append(
                    RuntimeItem(id: id, platformIdentifier: platform, version: version, build: build, deletable: nil, sizeBytes: nil)
                )
            }
        }
        // 1) 先尝试 JSON（最准确）
        do {
            let data = Data(output.utf8)
            let json = try JSONSerialization.jsonObject(with: data, options: [])


            if let root = json as? [String: Any] {
                // 结构 1：{ "runtimes": { "<uuid>": { ... } } }
                if let runtimesDict = root["runtimes"] as? [String: Any] {
                    for (key, value) in runtimesDict {
                        guard let dict = value as? [String: Any] else { continue }
                        let id = (dict["identifier"] as? String) ?? key
                        let platform = (dict["platformIdentifier"] as? String) ?? inferPlatform(from: id)
                        let version = (dict["version"] as? String) ?? "unknown"
                        let build = dict["build"] as? String
                        let deletable = dict["deletable"] as? Bool
                        let sizeBytes = (dict["sizeBytes"] as? NSNumber)?.int64Value
                        byPlatform[platform, default: []].append(
                            RuntimeItem(id: id, platformIdentifier: platform, version: version, build: build, deletable: deletable, sizeBytes: sizeBytes)
                        )
                    }
                }
                // 结构 2：{ "runtimes": [ { ... }, ... ] }
                else if let runtimesArr = root["runtimes"] as? [[String: Any]] {
                    for dict in runtimesArr {
                        let id = (dict["identifier"] as? String)
                            ?? (dict["bundleIdentifier"] as? String)
                            ?? (dict["runtimeIdentifier"] as? String)
                            ?? (dict["name"] as? String)
                            ?? UUID().uuidString
                        let platform = (dict["platformIdentifier"] as? String) ?? inferPlatform(from: id)
                        let version = (dict["version"] as? String)
                            ?? (dict["runtimeVersion"] as? String)
                            ?? "unknown"
                        let build = dict["build"] as? String
                        let deletable = dict["deletable"] as? Bool
                        let sizeBytes = (dict["sizeBytes"] as? NSNumber)?.int64Value
                        byPlatform[platform, default: []].append(
                            RuntimeItem(id: id, platformIdentifier: platform, version: version, build: build, deletable: deletable, sizeBytes: sizeBytes)
                        )
                    }
                } else {
                    // 结构 3：兜底：把 root 当作 map
                    for (key, value) in root {
                        guard let dict = value as? [String: Any] else { continue }
                        let id = (dict["identifier"] as? String) ?? key
                        let platform = (dict["platformIdentifier"] as? String) ?? inferPlatform(from: id)
                        let version = (dict["version"] as? String) ?? "unknown"
                        let build = dict["build"] as? String
                        let deletable = dict["deletable"] as? Bool
                        let sizeBytes = (dict["sizeBytes"] as? NSNumber)?.int64Value
                        byPlatform[platform, default: []].append(
                            RuntimeItem(id: id, platformIdentifier: platform, version: version, build: build, deletable: deletable, sizeBytes: sizeBytes)
                        )
                    }
                }
            }
        } catch {
            // 2) JSON 失败就退回到文本解析（覆盖更老/更怪的 simctl 输出）
            let text = (try? await runner.runSimctl(["list", "runtimes"])) ?? ""
            parseTextRuntimes(text)
        }

        // 3) JSON 解析可能“成功但结构不含 runtimes”（或字段名变化），再做一次文本兜底。
        if byPlatform.isEmpty {
            let text = (try? await runner.runSimctl(["list", "runtimes"])) ?? ""
            parseTextRuntimes(text)
        }

        // 4) 如果解析后仍为空，说明命令可能输出了我们未覆盖的结构或“空但成功”。
        //    这时直接抛错，把原始输出带到 UI（方便开源用户定位）。
        if byPlatform.isEmpty {
            let snippet = output.prefix(600)
            throw ServiceError.invalidOutput(command: "simctl runtimes", output: String(snippet))
        }

        // 排序：版本降序
        for (platform, items) in byPlatform {
            byPlatform[platform] = items.sorted(by: { Version($0.version) > Version($1.version) })
        }
        return byPlatform
    }

    private func scanArchives() async throws -> [ArchiveItem] {
        let archivesRoot = expandTilde("~/Library/Developer/Xcode/Archives")
        guard FileManager.default.fileExists(atPath: archivesRoot) else { return [] }

        let rootURL = URL(fileURLWithPath: archivesRoot, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let archiveURLs = Self.archiveURLs(in: rootURL, includingPropertiesForKeys: keys)

        var items: [ArchiveItem] = []
        items.reserveCapacity(archiveURLs.count)

        for url in archiveURLs.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedDescending }) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let bytes = try await duBytes(paths: [url.path])
            let name = archiveDisplayName(for: url)
            items.append(
                ArchiveItem(
                    id: url.path,
                    path: url.path,
                    name: name,
                    createdAt: values?.creationDate ?? values?.contentModificationDate,
                    sizeBytes: bytes
                )
            )
        }

        return items.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    nonisolated private static func archiveURLs(
        in rootURL: URL,
        includingPropertiesForKeys keys: [URLResourceKey]
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var archiveURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "xcarchive" {
            archiveURLs.append(url)
        }
        return archiveURLs
    }

    private func archiveDisplayName(for archiveURL: URL) -> String {
        let infoPlistURL = archiveURL.appendingPathComponent("Info.plist")
        if
            let dict = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
            let appProperties = dict["ApplicationProperties"] as? [String: Any],
            let appName = appProperties["ApplicationPath"] as? String
        {
            let displayName = URL(fileURLWithPath: appName).deletingPathExtension().lastPathComponent
            if !displayName.isEmpty {
                return "\(displayName) - \(archiveURL.deletingPathExtension().lastPathComponent)"
            }
        }
        return archiveURL.deletingPathExtension().lastPathComponent
    }

    private func scanItemLists(for categories: [CacheCategoryPreference]) async throws -> [String: [CleanableItem]] {
        var result: [String: [CleanableItem]] = [:]
        for category in categories where category.action == .itemList {
            result[category.id] = try await scanItems(for: category)
        }
        return result
    }

    private func scanItems(for category: CacheCategoryPreference) async throws -> [CleanableItem] {
        switch category.id {
        case "derivedData", "deviceLogs", "xcodeProducts":
            guard let root = category.scanPaths?.first.map(expandTilde) else { return [] }
            return try await scanChildren(of: root, categoryID: category.id)
        default:
            return try await scanConfiguredPaths(category)
        }
    }

    private func scanChildren(of rootPath: String, categoryID: String) async throws -> [CleanableItem] {
        guard FileManager.default.fileExists(atPath: rootPath) else { return [] }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var items: [CleanableItem] = []
        items.reserveCapacity(urls.count)

        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let values = try? url.resourceValues(forKeys: keys)
            let bytes = try await duBytes(paths: [url.path])
            items.append(
                CleanableItem(
                    id: "\(categoryID)|\(url.path)",
                    categoryID: categoryID,
                    path: url.path,
                    name: url.lastPathComponent,
                    detail: nil,
                    createdAt: values?.contentModificationDate ?? values?.creationDate,
                    sizeBytes: bytes
                )
            )
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func scanConfiguredPaths(_ category: CacheCategoryPreference) async throws -> [CleanableItem] {
        var items: [CleanableItem] = []
        for rawPath in category.scanPaths ?? [] {
            let path = expandTilde(rawPath)
            guard FileManager.default.fileExists(atPath: path) else { continue }

            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let bytes = try await duBytes(paths: [path])
            items.append(
                CleanableItem(
                    id: "\(category.id)|\(path)",
                    categoryID: category.id,
                    path: path,
                    name: displayName(forPath: path),
                    detail: (path as NSString).abbreviatingWithTildeInPath,
                    createdAt: values?.contentModificationDate ?? values?.creationDate,
                    sizeBytes: bytes
                )
            )
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func displayName(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        return parent.isEmpty ? name : "\(parent)/\(name)"
    }

    private func scanUnavailableSimulators() async throws -> [SimulatorDeviceItem] {
        let output = try await runner.runSimctl(["list", "devices", "-j"])
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard
            let root = json as? [String: Any],
            let devicesByRuntime = root["devices"] as? [String: Any]
        else {
            throw ServiceError.invalidOutput(command: "simctl list devices -j", output: output)
        }

        var items: [SimulatorDeviceItem] = []
        for (runtime, value) in devicesByRuntime {
            guard let devices = value as? [[String: Any]] else { continue }
            for device in devices {
                let isAvailable = (device["isAvailable"] as? Bool) ?? true
                let availabilityError = device["availabilityError"] as? String
                guard !isAvailable || availabilityError != nil else { continue }

                let udid = (device["udid"] as? String) ?? UUID().uuidString
                let dataPath = device["dataPath"] as? String
                let bytes: Int64?
                if let dataPath, FileManager.default.fileExists(atPath: dataPath) {
                    bytes = try await duBytes(paths: [dataPath])
                } else {
                    bytes = nil
                }
                items.append(
                    SimulatorDeviceItem(
                        id: udid,
                        name: (device["name"] as? String) ?? udid,
                        runtimeIdentifier: runtime,
                        state: device["state"] as? String,
                        availabilityError: availabilityError,
                        dataPath: dataPath,
                        sizeBytes: bytes
                    )
                )
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - CleanerService

final class CleanerService {
    private let runner = ProcessRunner()

    func execute(plan: CleanerPlan) async throws {
        var failures: [String] = []

        // 1) 清理目录类
        for cat in plan.categories {
            do {
                try await executeCategory(cat)
            } catch {
                failures.append("\(cat.id): \((error as NSError).localizedDescription)")
            }
        }

        // 2) Runtime
        if !plan.runtimesToDelete.isEmpty {
            for rt in plan.runtimesToDelete {
                // 你要求“简单”：直接删，不做解锁/二次确认
                do {
                    _ = try await runner.runSimctl(["runtime", "delete", rt.deleteArgument])
                } catch {
                    failures.append("\(rt.version): \((error as NSError).localizedDescription)")
                }
            }
            do {
                _ = try await runner.runSimctl(["delete", "unavailable"])
            } catch {
                failures.append("delete unavailable: \((error as NSError).localizedDescription)")
            }
        }

        // 3) Archives
        for archive in plan.archivesToDelete {
            do {
                guard FileManager.default.fileExists(atPath: archive.path) else { continue }
                try FileManager.default.removeItem(atPath: archive.path)
            } catch {
                failures.append("\(archive.name): \((error as NSError).localizedDescription)")
            }
        }

        // 4) File-system item lists
        for item in plan.cleanableItemsToDelete {
            do {
                guard FileManager.default.fileExists(atPath: item.path) else { continue }
                try FileManager.default.removeItem(atPath: item.path)
            } catch {
                failures.append("\(item.name): \((error as NSError).localizedDescription)")
            }
        }

        // 5) Unavailable simulator devices
        for device in plan.simulatorDevicesToDelete {
            do {
                _ = try await runner.runSimctl(["delete", device.id])
            } catch {
                failures.append("\(device.name): \((error as NSError).localizedDescription)")
            }
        }

        if !failures.isEmpty {
            throw ServiceError.multipleFailures(failures)
        }
    }

    private func executeCategory(_ category: CacheCategoryPreference) async throws {
        switch category.action {
        case let .deletePaths(paths):
            for p in paths {
                let path = expandTilde(p)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                try FileManager.default.removeItem(atPath: path)
            }
        case let .command(program, arguments):
            _ = try await runner.run(program, arguments)
        case .runtimes:
            // Runtime 删除不走“一键清理”（由主菜单里的 Runtime 勾选删除处理）。
            break
        case .archives:
            // Archives 删除由展开列表中的勾选项控制。
            break
        case .itemList:
            // 由展开列表中的勾选项控制。
            break
        case .unavailableSimulators:
            // 由不可用模拟器列表中的勾选项控制。
            break
        }
    }
}

// MARK: - Helpers

func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    return (path as NSString).expandingTildeInPath
}

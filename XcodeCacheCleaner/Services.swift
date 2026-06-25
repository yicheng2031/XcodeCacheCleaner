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
    private var cachedSimctlPath: String?

    private static let systemSimctlPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"

    /// 优先使用当前 Xcode 的 simctl；Xcode 已卸载时回退到系统 CoreSimulator 组件。
    func runSimctl(_ arguments: [String]) async throws -> String {
        let simctlPath = try await resolveSimctlPath()
        return try await run(simctlPath, arguments)
    }

    func listRuntimes() async throws -> [RuntimeItem] {
        let jsonCandidates = [
            ["runtime", "list", "-j"],
            ["list", "runtimes", "-j"],
            ["list", "-j", "runtimes"],
        ]

        var lastError: Error?
        var unrecognizedOutput: String?
        for arguments in jsonCandidates {
            do {
                let output = try await runSimctl(arguments)
                if let runtimes = RuntimeListParser.parseJSON(output) {
                    return runtimes
                }
                if !output.isEmpty { unrecognizedOutput = output }
            } catch {
                lastError = error
            }
        }

        for arguments in [["runtime", "list"], ["list", "runtimes"]] {
            do {
                let output = try await runSimctl(arguments)
                if let runtimes = RuntimeListParser.parseText(output) {
                    return runtimes
                }
                if !output.isEmpty { unrecognizedOutput = output }
            } catch {
                lastError = error
            }
        }

        if let unrecognizedOutput {
            throw ServiceError.invalidOutput(
                command: "simctl runtime list",
                output: String(unrecognizedOutput.prefix(600))
            )
        }
        throw lastError ?? ServiceError.commandFailed(command: "simctl runtime list", output: "")
    }

    private func resolveSimctlPath() async throws -> String {
        if let cachedSimctlPath,
           FileManager.default.isExecutableFile(atPath: cachedSimctlPath) {
            return cachedSimctlPath
        }
        cachedSimctlPath = nil

        let developerDir = try? await developerDir()
        let env: [String: String] = {
            guard let developerDir, !developerDir.isEmpty else { return [:] }
            return ["DEVELOPER_DIR": developerDir]
        }()

        var xcrunError: Error?
        do {
            let path = try await run("/usr/bin/xcrun", ["--find", "simctl"], environment: env)
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedSimctlPath = path
                return path
            }
        } catch {
            xcrunError = error
        }

        if FileManager.default.isExecutableFile(atPath: Self.systemSimctlPath) {
            cachedSimctlPath = Self.systemSimctlPath
            return Self.systemSimctlPath
        }

        throw xcrunError ?? ServiceError.commandFailed(
            command: "xcrun --find simctl",
            output: "CoreSimulator simctl is not installed"
        )
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

// MARK: - RuntimeListParser

enum RuntimeListParser {
    static func parseJSON(_ output: String) -> [RuntimeItem]? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)),
            let root = object as? [String: Any]
        else { return nil }

        if let runtimes = root["runtimes"] as? [String: Any] {
            return runtimes.compactMap { item(from: $0.value, fallbackIdentifier: $0.key) }
        }
        if let runtimes = root["runtimes"] as? [Any] {
            return runtimes.compactMap { item(from: $0, fallbackIdentifier: nil) }
        }

        // `simctl runtime list -j` 的根对象本身就是 UUID -> Runtime 的 map。
        if root.isEmpty { return [] }
        let runtimes = root.compactMap { item(from: $0.value, fallbackIdentifier: $0.key) }
        return runtimes.isEmpty ? nil : runtimes
    }

    static func parseText(_ output: String) -> [RuntimeItem]? {
        let pattern = #"^(.+?)\s+\(([^)]*)\)\s+-\s+([^\s]+)(?:\s+\(([^)]*)\))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var runtimes: [RuntimeItem] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4 else {
                continue
            }

            func capture(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
                return String(line[swiftRange])
            }

            guard let nameAndVersion = capture(1), let identifier = capture(3) else { continue }
            let version = version(from: nameAndVersion)
            let build = capture(2)?
                .components(separatedBy: " - ")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            runtimes.append(
                RuntimeItem(
                    id: identifier,
                    platformIdentifier: platformIdentifier(from: nameAndVersion, identifier: identifier),
                    version: version,
                    build: build,
                    deletable: nil,
                    sizeBytes: nil
                )
            )
        }

        if !runtimes.isEmpty { return runtimes }
        if output.contains("Total Disk Images: 0") { return [] }
        return nil
    }

    private static func item(from value: Any, fallbackIdentifier: String?) -> RuntimeItem? {
        guard let dictionary = value as? [String: Any] else { return nil }
        guard let identifier = (dictionary["identifier"] as? String)
            ?? (dictionary["uuid"] as? String)
            ?? fallbackIdentifier
            ?? (dictionary["runtimeIdentifier"] as? String)
            ?? (dictionary["bundleIdentifier"] as? String)
        else { return nil }

        // 防止把未知 JSON 中的普通字典误当成 Runtime。
        let looksLikeRuntime = dictionary["platformIdentifier"] != nil
            || dictionary["runtimeIdentifier"] != nil
            || dictionary["version"] != nil
            || dictionary["runtimeVersion"] != nil
            || dictionary["kind"] != nil
        guard looksLikeRuntime else { return nil }

        let name = (dictionary["name"] as? String) ?? identifier
        let platform = (dictionary["platformIdentifier"] as? String)
            ?? platformIdentifier(from: name, identifier: identifier)
        let version = (dictionary["version"] as? String)
            ?? (dictionary["runtimeVersion"] as? String)
            ?? version(from: name)
        let build = (dictionary["build"] as? String)
            ?? (dictionary["buildversion"] as? String)
        let deletable = dictionary["deletable"] as? Bool
        let sizeBytes = (dictionary["sizeBytes"] as? NSNumber)?.int64Value
        let mountPath = dictionary["mountPath"] as? String
        let parentMountPath = dictionary["parentMountPath"] as? String

        return RuntimeItem(
            id: identifier,
            platformIdentifier: platform,
            version: version,
            build: build,
            deletable: deletable,
            sizeBytes: sizeBytes,
            mountPath: mountPath,
            parentMountPath: parentMountPath
        )
    }

    private static func platformIdentifier(from name: String, identifier: String) -> String {
        let value = "\(name) \(identifier)"
        if value.localizedCaseInsensitiveContains("watchOS") { return "com.apple.platform.watchsimulator" }
        if value.localizedCaseInsensitiveContains("tvOS") { return "com.apple.platform.appletvsimulator" }
        if value.localizedCaseInsensitiveContains("xrOS")
            || value.localizedCaseInsensitiveContains("visionOS") {
            return "com.apple.platform.xrsimulator"
        }
        if value.localizedCaseInsensitiveContains("iOS") { return "com.apple.platform.iphonesimulator" }
        return "unknown"
    }

    private static func version(from name: String) -> String {
        let knownPrefixes = ["visionOS", "watchOS", "tvOS", "xrOS", "iOS"]
        for prefix in knownPrefixes where name.localizedCaseInsensitiveContains(prefix) {
            return name.replacingOccurrences(of: prefix, with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
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
        let runtimes = try await runner.listRuntimes()
        var byPlatform: [String: [RuntimeItem]] = [:]
        for runtime in runtimes {
            byPlatform[runtime.platformIdentifier, default: []].append(runtime)
        }

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
            var submittedRuntimes: [RuntimeItem] = []
            for rt in plan.runtimesToDelete {
                do {
                    _ = try await runner.runSimctl(["runtime", "delete", rt.deleteArgument])
                    submittedRuntimes.append(rt)
                } catch {
                    failures.append("\(rt.version): \((error as NSError).localizedDescription)")
                }
            }

            if !submittedRuntimes.isEmpty {
                do {
                    try await waitForRuntimeDeletion(submittedRuntimes)
                } catch {
                    failures.append("Runtime verification: \((error as NSError).localizedDescription)")
                }
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

    private func waitForRuntimeDeletion(_ runtimes: [RuntimeItem]) async throws {
        let identifiers = Set(runtimes.map(\.id))
        let mountPaths = Set(runtimes.flatMap { [$0.mountPath, $0.parentMountPath].compactMap { $0 } })
        let timeout = Date().addingTimeInterval(120)
        var remaining = identifiers
        var mountedPaths: Set<String> = []
        var lastListError: Error?

        while Date() < timeout {
            do {
                let installed = Set(try await runner.listRuntimes().map(\.id))
                remaining = identifiers.intersection(installed)
                let mountOutput = (try? await runner.run("/sbin/mount", [])) ?? ""
                mountedPaths = Set(mountPaths.filter { mountOutput.contains(" on \($0) (") })
                if remaining.isEmpty && mountedPaths.isEmpty { return }
                lastListError = nil
            } catch {
                lastListError = error
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if let lastListError { throw lastListError }
        throw ServiceError.commandFailed(
            command: "simctl runtime delete",
            output: "Timed out waiting for Runtime deletion. Remaining identifiers: \(remaining.sorted().joined(separator: ", ")); mounted paths: \(mountedPaths.sorted().joined(separator: ", "))"
        )
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

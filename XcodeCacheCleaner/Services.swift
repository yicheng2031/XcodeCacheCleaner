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
    
    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, output):
            return String(format: String(localized: "error.command_failed.format"), command, output)
        case let .invalidOutput(command, output):
            return String(format: String(localized: "error.invalid_output.format"), command, output)
        }
    }
}

// MARK: - ProcessRunner

final class ProcessRunner {
    func run(_ program: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            
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
                    continuation.resume(throwing: ServiceError.commandFailed(command: ([program] + arguments).joined(separator: " "), output: merged))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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

        // Runtime 可能因为系统/权限策略失败：允许失败但不影响其他结果。
        let runtimes = (try? await scanRuntimes()) ?? [:]

        var categoryErrors: [String: String] = [:]
        let categories = try await scanCategories(
            preferences.categories,
            runtimesByPlatform: runtimes,
            categoryErrors: &categoryErrors
        )

        return ScanSnapshot(
            createdAt: Date(),
            disk: disk,
            categories: categories,
            runtimesByPlatform: runtimes,
            categoryErrors: categoryErrors.isEmpty ? nil : categoryErrors
        )
    }
    
    private func scanCategories(
        _ categories: [CacheCategoryPreference],
        runtimesByPlatform: [String: [RuntimeItem]],
        categoryErrors: inout [String: String]
    ) async throws -> [CategorySize] {
        var results: [CategorySize] = []
        results.reserveCapacity(categories.count)
        
        // 控制并发：简单串行，避免 IO 抢占；后续可做 2~3 并发。
        for cat in categories {
            do {
                let bytes = try await sizeBytes(for: cat, runtimesByPlatform: runtimesByPlatform)
                results.append(.init(id: cat.id, title: cat.title, sizeBytes: bytes))
            } catch {
                categoryErrors[cat.id] = (error as NSError).localizedDescription
                results.append(.init(id: cat.id, title: cat.title, sizeBytes: 0))
            }
        }
        return results
    }
    
    private func sizeBytes(for category: CacheCategoryPreference, runtimesByPlatform: [String: [RuntimeItem]]) async throws -> Int64 {
        switch category.action {
        case let .deletePaths(paths):
            var total: Int64 = 0
            for p in paths {
                total += try await duBytes(path: try resolvePathForSandbox(p))
            }
            return total
        case .command:
            // command 类型仍然需要统计“占用”（用户要求不管开关都要扫描）。
            // 使用 scanPaths 作为统计口径；若没有 scanPaths，则返回 0。
            var total: Int64 = 0
            for p in (category.scanPaths ?? []) {
                total += try await duBytes(path: try resolvePathForSandbox(p))
            }
            return total
        case .runtimes:
            // Runtime 的体积来自 simctl runtime list -j 的 sizeBytes（如果系统提供）。
            // 若 sizeBytes 缺失则按 0 处理（不同系统版本可能不给）。
            return runtimesByPlatform.values
                .flatMap { $0 }
                .compactMap { $0.sizeBytes }
                .reduce(0, +)
        }
    }
    
    private func duBytes(path: String) async throws -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        // du 速度更快；在 Sandbox 下需要在 security-scope 生效期间执行。
        let url = URL(fileURLWithPath: path)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let output2 = try await runner.run("/usr/bin/du", ["-sk", path])
        // du -sk: "<kb>\t<path>"
        let first = output2.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
        guard let first, let kb = Int64(first) else {
            throw ServiceError.invalidOutput(command: "du -sk \(path)", output: output2)
        }
        return kb * 1024
    }
    
    private func scanRuntimes() async throws -> [String: [RuntimeItem]] {
        // 兼容性：优先 JSON
        let output = try await runner.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        
        // 可能的结构：
        // A) { "runtimes": { "<uuid>": { ... } } }
        // B) { "<uuid>": { ... }, ... }
        let map: [String: Any]
        if let root = json as? [String: Any], let runtimes = root["runtimes"] as? [String: Any] {
            map = runtimes
        } else if let root = json as? [String: Any] {
            map = root
        } else {
            return [:]
        }
        
        var byPlatform: [String: [RuntimeItem]] = [:]
        
        for (key, value) in map {
            guard let dict = value as? [String: Any] else { continue }
            let platform = (dict["platformIdentifier"] as? String) ?? "unknown"
            let version = (dict["version"] as? String) ?? "unknown"
            let build = dict["build"] as? String
            let deletable = dict["deletable"] as? Bool
            let sizeBytes = (dict["sizeBytes"] as? NSNumber)?.int64Value
            let id = (dict["identifier"] as? String) ?? key
            
            let item = RuntimeItem(
                id: id,
                platformIdentifier: platform,
                version: version,
                build: build,
                deletable: deletable,
                sizeBytes: sizeBytes
            )
            byPlatform[platform, default: []].append(item)
        }
        
        // 排序：版本降序
        for (platform, items) in byPlatform {
            byPlatform[platform] = items.sorted(by: { Version($0.version) > Version($1.version) })
        }
        
        return byPlatform
    }
}

// MARK: - CleanerService

final class CleanerService {
    private let runner = ProcessRunner()
    
    func execute(plan: CleanerPlan) async throws {
        // 1) 清理目录类
        for cat in plan.categories {
            try await executeCategory(cat)
        }
        
        // 2) Runtime
        if !plan.runtimesToDelete.isEmpty {
            for rt in plan.runtimesToDelete {
                // 你要求“简单”：直接删，不做解锁/二次确认
                _ = try await runner.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", rt.deleteArgument])
            }
            _ = try await runner.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
        }
    }
    
    private func executeCategory(_ category: CacheCategoryPreference) async throws {
        switch category.action {
        case let .deletePaths(paths):
            for p in paths {
                let path = try resolvePathForSandbox(p)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.removeItem(atPath: path)
            }
        case let .command(program, arguments):
            _ = try await runner.run(program, arguments)
        case .runtimes:
            // Runtime 删除不走“一键清理”（由主菜单里的 Runtime 勾选删除处理）。
            break
        }
    }
}

// MARK: - Helpers

func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    return (path as NSString).expandingTildeInPath
}

/// 在 Sandbox/MAS 场景下，访问 ~/Library 下的路径需要用户授权。
/// - 已授权：将路径重定向到用户选择的 Library bookmark 下
/// - 未授权：抛出错误，供 UI 引导用户授权
func resolvePathForSandbox(_ tildePath: String) throws -> String {
    let expanded = expandTilde(tildePath)
    // 只对 ~/Library/* 做处理；其余路径按原样返回
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let libraryPrefix = home.hasSuffix("/") ? "\(home)Library/" : "\(home)/Library/"
    guard expanded.hasPrefix(libraryPrefix) else { return expanded }

    // 关键：通过 security-scoped bookmark 获取访问
    let url = try FileAccessStore.shared.resolveHomeLibraryPath(tildePath)
    return url.path
}

//
//  FileAccessStore.swift
//  XcodeCacheCleaner
//
//  Mac App Store / Sandbox 访问策略：
//  - 通过 NSOpenPanel 让用户选择 ~/Library（或其子目录）一次
//  - 保存 security-scoped bookmark
//  - 扫描/清理时临时 startAccessingSecurityScopedResource()
//

import Foundation
import AppKit
import Combine

enum FileAccessError: LocalizedError {
    case libraryAccessNotGranted
    case bookmarkResolveFailed

    var errorDescription: String? {
        switch self {
        case .libraryAccessNotGranted:
            return String(localized: "error.permission.library_not_granted")
        case .bookmarkResolveFailed:
            return String(localized: "error.permission.bookmark_resolve_failed")
        }
    }
}

final class FileAccessStore: ObservableObject {
    static let shared = FileAccessStore()

    private let bookmarkKey = "bookmark.library.v1"
    private let defaults = UserDefaults.standard

    @Published private(set) var hasLibraryAccess: Bool = false

    private init() {
        self.hasLibraryAccess = defaults.data(forKey: bookmarkKey) != nil
    }

    /// 让用户选择 ~/Library（建议）。也可以选择其子目录，但功能可能受限。
    @MainActor
    func requestLibraryAccess() async {
        let panel = NSOpenPanel()
        panel.title = String(localized: "permission.panel.title")
        panel.message = String(localized: "permission.panel.message")
        panel.prompt = String(localized: "permission.panel.prompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            try saveBookmark(for: url)
            self.hasLibraryAccess = true
        } catch {
            // 失败时保持 false，具体错误由业务层在实际访问时暴露
            self.hasLibraryAccess = defaults.data(forKey: bookmarkKey) != nil
        }
    }

    private func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey)
    }

    /// 将 "~/Library/..." 路径解析到用户授权的 Library 之下（若已授权）。
    func resolveHomeLibraryPath(_ tildePath: String) throws -> URL {
        let expanded = (tildePath as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = home.hasSuffix("/") ? "\(home)Library/" : "\(home)/Library/"

        guard expanded.hasPrefix(prefix) else {
            // 非 ~/Library 下的路径，直接返回
            return URL(fileURLWithPath: expanded)
        }

        guard let data = defaults.data(forKey: bookmarkKey) else {
            throw FileAccessError.libraryAccessNotGranted
        }

        var stale = false
        guard let libraryURL = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            throw FileAccessError.bookmarkResolveFailed
        }

        // stale 时尝试重写一次（不阻塞主流程）
        if stale {
            try? saveBookmark(for: libraryURL)
        }

        let relative = String(expanded.dropFirst(prefix.count))
        return libraryURL.appendingPathComponent(relative, isDirectory: true)
    }

    /// 在 security scope 下执行。若 url 不是 security-scoped，依旧会正常执行。
    func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }
}

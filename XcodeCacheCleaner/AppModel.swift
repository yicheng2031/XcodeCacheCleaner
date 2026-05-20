//
//  AppModel.swift
//  XcodeCacheCleaner
//
//  应用核心状态与业务逻辑入口（扫描 / 清理 / 快照 / 偏好）。
//

import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: ScanSnapshot?
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var lastErrorMessage: String?

    @Published var preferences: Preferences = .defaultValue

    /// Runtime 选择：key = runtime identifier，value = 是否选择删除
    @Published var selectedRuntimes: [String: Bool] = [:]
    @Published var selectedArchives: [String: Bool] = [:]
    @Published var selectedCleanableItems: [String: Bool] = [:]
    @Published var selectedUnavailableSimulators: [String: Bool] = [:]

    // Runtime 清理失败时的兜底提示（复制到终端执行）
    @Published var runtimeDeleteMessage: String?
    @Published var runtimeFallbackCommands: [String] = []

    // 清理完成提示（显示 3 秒）
    @Published var cleanToastMessage: String?

    private let snapshotStore = SnapshotStore()
    private let preferencesStore = PreferencesStore()
    private let scanner = ScannerService()
    private let cleaner = CleanerService()

    private var timer: Timer?
    private var autoCleanTimer: Timer?

    init() {
        self.preferences = preferencesStore.load()
        self.snapshot = snapshotStore.load()

        // 启动定时扫描（30 分钟一次）
        startTimer()
        startAutoCleanTimer()

        // 冷启动：如果没有快照，启动一次后台扫描；否则先展示快照，后台再刷新。
        Task { await refresh(reason: "launch") }
    }

    deinit {
        timer?.invalidate()
        autoCleanTimer?.invalidate()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: preferences.scanIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh(reason: "timer") }
        }
    }

    func startAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        guard let interval = preferences.autoCleanSchedule.intervalSeconds else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.cleanSelectedCategories() }
        }
        timer.tolerance = min(interval * 0.1, 60)
        RunLoop.main.add(timer, forMode: .common)
        autoCleanTimer = timer
    }

    func updatePreferences(_ newValue: Preferences) {
        preferences = newValue
        preferencesStore.save(newValue)
        startTimer()
        startAutoCleanTimer()
    }

    func refresh(reason: String) async {
        guard !isScanning else { return }
        isScanning = true
        lastErrorMessage = nil
        defer { isScanning = false }

        do {
            let newSnapshot = try await scanner.scan(preferences: preferences)
            snapshot = newSnapshot
            snapshotStore.save(newSnapshot)

            // 初始化 runtime 勾选状态（默认不选“每个平台最新 1 个”）
            selectedRuntimes = Self.defaultRuntimeSelections(
                from: newSnapshot.runtimesByPlatform,
                preserving: selectedRuntimes
            )
            selectedArchives = Self.defaultArchiveSelections(
                from: newSnapshot.allArchives,
                preserving: selectedArchives
            )
            selectedCleanableItems = Self.defaultCleanableItemSelections(
                from: newSnapshot.allCleanableItems,
                preserving: selectedCleanableItems
            )
            selectedUnavailableSimulators = Self.defaultUnavailableSimulatorSelections(
                from: newSnapshot.unavailableSimulators ?? [],
                preserving: selectedUnavailableSimulators
            )
        } catch {
            lastErrorMessage = (error as NSError).localizedDescription
        }
    }

    func cleanSelectedCategories() async {
        guard !isCleaning else { return }
        isCleaning = true
        lastErrorMessage = nil
        runtimeDeleteMessage = nil
        runtimeFallbackCommands = []
        defer { isCleaning = false }

        guard let snapshot else {
            await refresh(reason: "before-clean-no-snapshot")
            return
        }

        // “一键清理”策略：
        // - 所有分类都扫描（已实现）
        // - 只有开关打开的分类参与删除
        // - Runtime / Archives：使用展开勾选的子列表作为删除目标
        let enabledCategories = preferences.categories.filter { $0.includedInOneTapClean }
        let categoriesToClean = enabledCategories.filter {
            $0.action != .runtimes
                && $0.action != .archives
                && $0.action != .itemList
                && $0.action != .unavailableSimulators
        }

        let runtimesEnabled = enabledCategories.contains(where: { $0.action == .runtimes })
        let runtimesToDelete: [RuntimeItem] = runtimesEnabled
        ? snapshot.allRuntimes.filter { (selectedRuntimes[$0.deletionKey] ?? false) == true && $0.deletable != false }
        : []

        let archivesEnabled = enabledCategories.contains(where: { $0.action == .archives })
        let archivesToDelete: [ArchiveItem] = archivesEnabled
        ? snapshot.allArchives.filter { (selectedArchives[$0.deletionKey] ?? false) == true }
        : []

        let itemListCategoryIDs = Set(
            enabledCategories
                .filter { $0.action == .itemList }
                .map(\.id)
        )
        let cleanableItemsToDelete = snapshot.allCleanableItems.filter {
            itemListCategoryIDs.contains($0.categoryID)
                && (selectedCleanableItems[$0.deletionKey] ?? false) == true
        }

        let unavailableSimulatorsEnabled = enabledCategories.contains(where: { $0.action == .unavailableSimulators })
        let simulatorDevicesToDelete: [SimulatorDeviceItem] = unavailableSimulatorsEnabled
        ? (snapshot.unavailableSimulators ?? []).filter { (selectedUnavailableSimulators[$0.deletionKey] ?? false) == true }
        : []

        // 预估本次清理可释放空间（用于提示文案；实际释放可能因为文件占用/不存在而变化）
        let estimatedBytes = estimateCleanBytes(
            snapshot: snapshot,
            categoriesToClean: categoriesToClean,
            runtimesToDelete: runtimesToDelete,
            archivesToDelete: archivesToDelete,
            cleanableItemsToDelete: cleanableItemsToDelete,
            simulatorDevicesToDelete: simulatorDevicesToDelete
        )

        do {
            let plan = CleanerPlan(
                categories: categoriesToClean,
                runtimesToDelete: runtimesToDelete,
                archivesToDelete: archivesToDelete,
                cleanableItemsToDelete: cleanableItemsToDelete,
                simulatorDevicesToDelete: simulatorDevicesToDelete
            )
            try await cleaner.execute(plan: plan)

            if estimatedBytes > 0 {
                showCleanToast(bytes: estimatedBytes)
            }
        } catch {
            // 允许“部分成功”：即便 Runtime 删除失败，也可能已经清掉了其它目录。
            if !runtimesToDelete.isEmpty {
                runtimeDeleteMessage = String(
                    format: String(localized: "runtime.delete_failed.format"),
                    (error as NSError).localizedDescription
                )
                runtimeFallbackCommands = runtimesToDelete.map { "xcrun simctl runtime delete \($0.deleteArgument)" } + ["xcrun simctl delete unavailable"]
            } else {
                lastErrorMessage = (error as NSError).localizedDescription
            }
        }

        await refresh(reason: "after-clean")
    }

    private func showCleanToast(bytes: Int64) {
        let msg = String(format: String(localized: "toast.cleaned.format"), SizeFormatting.short(bytes))
        cleanToastMessage = msg
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                // 只清掉当前这条，避免并发清理时互相覆盖
                if self?.cleanToastMessage == msg {
                    self?.cleanToastMessage = nil
                }
            }
        }
    }

    private func estimateCleanBytes(
        snapshot: ScanSnapshot,
        categoriesToClean: [CacheCategoryPreference],
        runtimesToDelete: [RuntimeItem],
        archivesToDelete: [ArchiveItem],
        cleanableItemsToDelete: [CleanableItem],
        simulatorDevicesToDelete: [SimulatorDeviceItem]
    ) -> Int64 {
        let catBytes = categoriesToClean.reduce(Int64(0)) { partial, cat in
            partial + (snapshot.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0)
        }
        let runtimeBytes = runtimesToDelete.compactMap { $0.sizeBytes }.reduce(Int64(0), +)
        let archiveBytes = archivesToDelete.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let itemBytes = cleanableItemsToDelete.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let simulatorBytes = simulatorDevicesToDelete.compactMap(\.sizeBytes).reduce(Int64(0), +)
        return catBytes + runtimeBytes + archiveBytes + itemBytes + simulatorBytes
    }

    // MARK: - Helpers

    private static func defaultRuntimeSelections(
        from map: [String: [RuntimeItem]],
        preserving existingSelections: [String: Bool]
    ) -> [String: Bool] {
        var selections: [String: Bool] = [:]
        for (_, runtimes) in map {
            let sorted = runtimes.sorted(by: { Version($0.version) > Version($1.version) })
            guard let latest = sorted.first else { continue }
            for rt in runtimes {
                // 默认“保留最新 1 个”：最新版本默认不勾选，其余默认勾选，方便一键删除旧版本。
                let defaultValue = rt.deletable != false && rt.deletionKey != latest.deletionKey
                selections[rt.deletionKey] = existingSelections[rt.deletionKey]
                    ?? defaultValue
            }
        }
        return selections
    }

    private static func defaultArchiveSelections(
        from archives: [ArchiveItem],
        preserving existingSelections: [String: Bool]
    ) -> [String: Bool] {
        var selections: [String: Bool] = [:]
        for archive in archives {
            // 归档默认不勾选，避免用户开启分类后误删所有历史包。
            selections[archive.deletionKey] = existingSelections[archive.deletionKey] ?? false
        }
        return selections
    }

    private static func defaultCleanableItemSelections(
        from items: [CleanableItem],
        preserving existingSelections: [String: Bool]
    ) -> [String: Bool] {
        var selections: [String: Bool] = [:]
        for item in items {
            selections[item.deletionKey] = existingSelections[item.deletionKey]
                ?? defaultCleanableSelection(for: item)
        }
        return selections
    }

    private static func defaultCleanableSelection(for item: CleanableItem) -> Bool {
        switch item.categoryID {
        case "derivedData", "simulatorLogsCaches", "swiftuiPreviews":
            return true
        default:
            return false
        }
    }

    private static func defaultUnavailableSimulatorSelections(
        from items: [SimulatorDeviceItem],
        preserving existingSelections: [String: Bool]
    ) -> [String: Bool] {
        var selections: [String: Bool] = [:]
        for item in items {
            selections[item.deletionKey] = existingSelections[item.deletionKey] ?? true
        }
        return selections
    }
}

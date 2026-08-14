//
//  AppModel.swift
//  XcodeCacheCleaner
//
//  应用核心状态与业务逻辑入口（扫描 / 清理 / 快照 / 偏好）。
//

import Foundation
import Combine
import AppKit

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

    // 定时清理状态：用于显示“下次执行”以及跨重启保留失败原因。
    @Published private(set) var nextAutoCleanAt: Date?
    @Published private(set) var lastAutoCleanAt: Date?
    @Published private(set) var lastAutoCleanError: String?
    @Published private(set) var autoCleanLoginItemError: String?

    private let snapshotStore = SnapshotStore()
    private let preferencesStore = PreferencesStore()
    private let autoCleanStore = AutoCleanStore()
    private let selectionStore = SelectionStore()
    private let launchAtLoginService = LaunchAtLoginService()
    private let scanner = ScannerService()
    private let cleaner = CleanerService()

    private var autoCleanState: AutoCleanState = .empty
    private var timer: Timer?
    private var autoCleanTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        self.preferences = preferencesStore.load()
        self.snapshot = snapshotStore.load()

        let selectionState = selectionStore.load()
        self.selectedRuntimes = selectionState.runtimes
        self.selectedArchives = selectionState.archives
        self.selectedCleanableItems = selectionState.cleanableItems
        self.selectedUnavailableSimulators = selectionState.unavailableSimulators

        let autoCleanState = autoCleanStore.load()
        self.autoCleanState = autoCleanState
        self.nextAutoCleanAt = autoCleanState.nextRunAt
        self.lastAutoCleanAt = autoCleanState.lastRunAt
        self.lastAutoCleanError = autoCleanState.lastErrorMessage

        // 启动定时扫描（30 分钟一次）
        startTimer()
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.runScheduledAutoClean() }
        }

        // 冷启动：如果没有快照，启动一次后台扫描；否则先展示快照，后台再刷新。
        Task { [weak self] in
            guard let self else { return }
            _ = await self.refresh(reason: "launch")
            self.startAutoCleanTimer()
        }
    }

    deinit {
        timer?.invalidate()
        autoCleanTimer?.invalidate()
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
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
        autoCleanTimer = nil

        let schedule = preferences.autoCleanSchedule
        guard let interval = schedule.intervalSeconds else {
            autoCleanState.schedule = .off
            autoCleanState.nextRunAt = nil
            persistAutoCleanState()
            syncLaunchAtLogin(enabled: false)
            return
        }

        // Changing the interval starts a new wall-clock period. Otherwise a
        // restart keeps the previous due date and can catch up an overdue run.
        if autoCleanState.schedule != schedule || autoCleanState.nextRunAt == nil {
            autoCleanState.schedule = schedule
            autoCleanState.nextRunAt = Date().addingTimeInterval(interval)
            autoCleanState.lastErrorMessage = nil
            persistAutoCleanState()
        } else {
            publishAutoCleanState()
        }

        syncLaunchAtLogin(enabled: true)
        scheduleNextAutoCleanTimer()
    }

    func updatePreferences(_ newValue: Preferences) {
        preferences = newValue
        preferencesStore.save(newValue)
        startTimer()
        startAutoCleanTimer()
    }

    private func scheduleNextAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        autoCleanTimer = nil

        guard let nextRunAt = autoCleanState.nextRunAt,
              preferences.autoCleanSchedule.intervalSeconds != nil else { return }

        let delay = max(0.1, nextRunAt.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { await self.runScheduledAutoClean() }
        }
        timer.tolerance = min(max(delay * 0.1, 1), 60)
        RunLoop.main.add(timer, forMode: .common)
        autoCleanTimer = timer
    }

    private func runScheduledAutoClean() async {
        guard preferences.autoCleanSchedule.intervalSeconds != nil else {
            startAutoCleanTimer()
            return
        }

        let now = Date()
        if let nextRunAt = autoCleanState.nextRunAt, nextRunAt > now {
            scheduleNextAutoCleanTimer()
            return
        }

        // Never clean a stale snapshot and never overlap a manual scan/clean.
        // Retry shortly instead of silently skipping this scheduled run.
        guard !isScanning, !isCleaning else {
            autoCleanState.nextRunAt = now.addingTimeInterval(60)
            persistAutoCleanState()
            scheduleNextAutoCleanTimer()
            return
        }

        let didRefresh = await refresh(reason: "auto-clean")
        guard didRefresh else {
            finishScheduledRun(
                success: false,
                errorMessage: lastErrorMessage ?? String(localized: "auto_clean.error.scan_failed")
            )
            return
        }

        let success = await performClean(automaticOnly: true)
        finishScheduledRun(
            success: success,
            errorMessage: success ? nil : lastErrorMessage ?? String(localized: "auto_clean.error.clean_failed")
        )
    }

    private func finishScheduledRun(success: Bool, errorMessage: String?) {
        guard let interval = preferences.autoCleanSchedule.intervalSeconds else {
            startAutoCleanTimer()
            return
        }

        autoCleanState.schedule = preferences.autoCleanSchedule
        autoCleanState.lastRunAt = Date()
        autoCleanState.lastErrorMessage = success ? nil : errorMessage
        autoCleanState.nextRunAt = Date().addingTimeInterval(interval)
        persistAutoCleanState()
        scheduleNextAutoCleanTimer()
    }

    private func persistAutoCleanState() {
        autoCleanStore.save(autoCleanState)
        publishAutoCleanState()
    }

    private func publishAutoCleanState() {
        nextAutoCleanAt = autoCleanState.nextRunAt
        lastAutoCleanAt = autoCleanState.lastRunAt
        lastAutoCleanError = autoCleanState.lastErrorMessage
    }

    private func syncLaunchAtLogin(enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            autoCleanLoginItemError = nil
        } catch {
            autoCleanLoginItemError = (error as NSError).localizedDescription
        }
    }

    func setRuntimeSelection(_ key: String, selected: Bool) {
        selectedRuntimes[key] = selected
        persistSelections()
    }

    func setArchiveSelection(_ key: String, selected: Bool) {
        selectedArchives[key] = selected
        persistSelections()
    }

    func setCleanableItemSelection(_ key: String, selected: Bool) {
        selectedCleanableItems[key] = selected
        persistSelections()
    }

    func setUnavailableSimulatorSelection(_ key: String, selected: Bool) {
        selectedUnavailableSimulators[key] = selected
        persistSelections()
    }

    private func persistSelections() {
        selectionStore.save(
            SelectionState(
                runtimes: selectedRuntimes,
                archives: selectedArchives,
                cleanableItems: selectedCleanableItems,
                unavailableSimulators: selectedUnavailableSimulators
            )
        )
    }

    @discardableResult
    func refresh(reason: String) async -> Bool {
        // Opening a menu bar popover can recreate the view repeatedly. Avoid
        // launching a full `du`/simctl scan for every open when the snapshot
        // is still recent.
        if reason == "menu-open",
           let snapshot,
           Date().timeIntervalSince(snapshot.createdAt) < 30 {
            return true
        }

        // The post-clean refresh is intentionally allowed below while the
        // cleaner owns the operation; unrelated scans must wait instead.
        if isCleaning, reason != "after-clean" {
            return false
        }
        guard !isScanning else { return false }
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
            persistSelections()
            return true
        } catch {
            lastErrorMessage = (error as NSError).localizedDescription
            return false
        }
    }

    func cleanSelectedCategories() async {
        guard !isCleaning, !isScanning else { return }

        // A manual clean from a cold start must use the newly scanned data in
        // the same invocation instead of returning after refresh.
        if snapshot == nil {
            guard await refresh(reason: "before-clean-no-snapshot") else { return }
        }

        _ = await performClean(automaticOnly: false)
    }

    @discardableResult
    private func performClean(automaticOnly: Bool) async -> Bool {
        guard !isCleaning else { return false }
        isCleaning = true
        lastErrorMessage = nil
        runtimeDeleteMessage = nil
        runtimeFallbackCommands = []
        defer { isCleaning = false }

        guard let snapshot else { return false }

        // “一键清理”策略：
        // - 所有分类都扫描（已实现）
        // - 只有开关打开的分类参与删除
        // - Runtime / Archives：使用展开勾选的子列表作为删除目标
        let enabledCategories = preferences.categories.filter {
            $0.includedInOneTapClean && (!automaticOnly || $0.allowsAutomaticClean)
        }
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

        var cleanErrorMessage: String?
        var visibleCleanupErrorMessage: String?
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
            cleanErrorMessage = (error as NSError).localizedDescription
            let failures: [CleanupFailure]
            if case let ServiceError.multipleFailures(records) = error {
                failures = records
            } else {
                failures = []
            }

            let runtimeFailures = failures.filter { $0.stage.isRuntimeFailure }
            let otherFailures = failures.filter { !$0.stage.isRuntimeFailure }

            // 允许“部分成功”：Runtime 与其它分类分别展示，避免把
            // simulatorDevices 的 simctl 失败误报成 Runtime 删除失败。
            if !runtimeFailures.isEmpty {
                let runtimeMessage = runtimeFailures
                    .map(\.displayMessage)
                    .joined(separator: "\n")
                runtimeDeleteMessage = String(
                    format: String(localized: "runtime.delete_failed.format"),
                    runtimeMessage
                )
                runtimeFallbackCommands = [
                    "SIMCTL=\"$(xcrun --find simctl 2>/dev/null || printf '%s' '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl')\""
                ] + runtimesToDelete.map { "\"$SIMCTL\" runtime delete \($0.deleteArgument)" } + [
                    "\"$SIMCTL\" runtime list",
                    "mount | grep CoreSimulator || true",
                    "diskutil list | grep -i -C 2 simulator || true"
                ]
            }

            if !otherFailures.isEmpty {
                visibleCleanupErrorMessage = otherFailures
                    .map(\.displayMessage)
                    .joined(separator: "\n")
            } else if runtimeFailures.isEmpty {
                visibleCleanupErrorMessage = cleanErrorMessage
            }
        }

        await refresh(reason: "after-clean")
        // refresh() clears the transient error at the beginning. Restore the
        // cleanup error so a failed scheduled run remains visible.
        if let visibleCleanupErrorMessage {
            lastErrorMessage = visibleCleanupErrorMessage
        }
        return cleanErrorMessage == nil
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

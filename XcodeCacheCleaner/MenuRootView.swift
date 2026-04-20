//
//  MenuRootView.swift
//  XcodeCacheCleaner
//
//  Created by SOLO on 2026/4/17.
//

import SwiftUI
import AppKit

struct MenuRootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var fileAccess = FileAccessStore.shared
    @StateObject private var donationStore = DonationStore.shared
    @State private var isRuntimesExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            Divider()
            categories
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .task {
            // 打开菜单时：立即展示快照（已在 model 里做了），然后触发一次后台刷新
            await model.refresh(reason: "menu-open")
            await donationStore.loadProductsIfNeeded()
        }
    }
    
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            let xcodeSize = model.snapshot.map { formatSize($0.xcodeTotalBytes) } ?? "—"
            let xcodePercentOfDisk = model.snapshot.map {
                $0.disk.totalBytes == 0 ? "—" : String(format: "%.1f", (Double($0.xcodeTotalBytes) / Double($0.disk.totalBytes)) * 100.0)
            } ?? "—"
            let diskAvail = model.snapshot.map { formatSize($0.disk.availableBytes) } ?? "—"
            let diskPercent = model.snapshot.map { String(format: "%.0f", $0.disk.usedPercent) } ?? "—"
            
            // 顶部信息（你最新要求）
            HStack {
                Text(String(format: String(localized: "summary.xcode_cache.format"), xcodeSize, xcodePercentOfDisk))
                Spacer()
                Text(String(format: String(localized: "summary.disk.format"), diskAvail, diskPercent))
            }
            .font(.system(size: 12))
            
            // 状态行：检测/清理 loading 与“清理完成”提示共用同一位置，左右居中
            statusLine
            
            if let err = model.lastErrorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            
            if let errors = model.snapshot?.categoryErrors, !errors.isEmpty {
                Text("summary.partial_scan_failed")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if !fileAccess.hasLibraryAccess {
                HStack(spacing: 10) {
                    Text("permission.summary.hint")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("permission.action.grant") {
                        Task { await fileAccess.requestLibraryAccess() }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }

    private var statusLine: some View {
        Group {
            if model.isCleaning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("status.cleaning")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("status.scanning")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let toast = model.cleanToastMessage {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
    
    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("categories.header")
                .font(.system(size: 12, weight: .semibold))
            
            ForEach(Array(model.preferences.categories.enumerated()), id: \.element.id) { idx, cat in
                if cat.id == "runtimes" {
                    runtimesCategoryRow(prefIndex: idx, cat: cat)
                } else {
                    standardCategoryRow(prefIndex: idx, cat: cat)
                }
            }
            
            // 你要求：上次扫描放在 Divider 上方，居中显示
            Text({
                let value = model.snapshot?.createdAt.formatted(date: .abbreviated, time: .shortened)
                    ?? String(localized: "last_scan.never")
                return String(format: String(localized: "last_scan.format"), value)
            }())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)
            
            Divider()
            
            bottomActions
        }
    }

    // 你要求：底部保持可直接点击的蓝色按钮“立即清理”，右侧小箭头展开定时清理选项
    private var bottomActions: some View {
        HStack(spacing: 10) {
            Button("action.rescan") {
                Task { await model.refresh(reason: "manual") }
            }
            .keyboardShortcut("r", modifiers: [.command])
            
            Spacer()
            
            HStack(spacing: 0) {
                Button("action.clean_now") {
                    Task { await model.cleanSelectedCategories() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCleaning)
                
                Menu {
                    scheduleMenuItems
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.borderedProminent)
                .disabled(model.isCleaning)
            }
        }
    }

    @ViewBuilder
    private var scheduleMenuItems: some View {
        scheduleItem(AutoCleanSchedule.off.title, selected: model.preferences.autoCleanSchedule == .off) { setSchedule(.off) }
        Divider()
        scheduleItem(AutoCleanSchedule.every1h.title, selected: model.preferences.autoCleanSchedule == .every1h) { setSchedule(.every1h) }
        scheduleItem(AutoCleanSchedule.every4h.title, selected: model.preferences.autoCleanSchedule == .every4h) { setSchedule(.every4h) }
        scheduleItem(AutoCleanSchedule.every12h.title, selected: model.preferences.autoCleanSchedule == .every12h) { setSchedule(.every12h) }
        scheduleItem(AutoCleanSchedule.every24h.title, selected: model.preferences.autoCleanSchedule == .every24h) { setSchedule(.every24h) }
    }

    private func scheduleItem(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if selected {
                    Image(systemName: "checkmark")
                        .frame(width: 14, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: 14, height: 14)
                }
                Text(title)
            }
        }
    }

    private func setSchedule(_ schedule: AutoCleanSchedule) {
        var p = model.preferences
        p.autoCleanSchedule = schedule
        model.updatePreferences(p)
    }
    
    private var runtimesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.snapshot?.runtimesByPlatform.keys.sorted() ?? [], id: \.self) { platform in
                VStack(alignment: .leading, spacing: 4) {
                    Text(platformLabel(platform))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    ForEach(model.snapshot?.runtimesByPlatform[platform] ?? []) { rt in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { model.selectedRuntimes[rt.deletionKey] ?? false },
                                set: { model.selectedRuntimes[rt.deletionKey] = $0 }
                            )) {
                                Text(rt.version)
                            }
                            .font(.system(size: 12))
                            
                            Spacer()
                            
                            if let size = rt.sizeBytes {
                                Text(formatSize(size))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }
    
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 按你的要求：名称居中 + 前面加新图标（同一行）
            VStack(spacing: 6) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 136, height: 136)
                Text("app.name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            
            HStack(spacing: 12) {
                Menu("menu.donate") {
                    DonationMenuItemsView()
                        .environmentObject(donationStore)
                }
                Menu("menu.about") {
                    Button("about.open_github") { AppLinks.openGitHub() }
                    Button("about.privacy") { AppLinks.openPrivacy() }
                    Divider()
                    Button {
                        Task { await fileAccess.requestLibraryAccess() }
                    } label: {
                        Text(LocalizedStringKey(fileAccess.hasLibraryAccess ? "permission.status.granted" : "permission.status.not_granted"))
                    }
                }
                Spacer()
                Button("action.quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .font(.system(size: 12))
    }
}

#Preview {
    MenuRootView()
        .environmentObject(AppModel())
}

private func formatSize(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 MB" }
    if bytes < 1_000_000 { return "<1 MB" }
    if bytes >= 1_000_000_000 {
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
    }
    return String(format: "%.0f MB", Double(bytes) / 1_000_000.0)
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private extension MenuRootView {
    @ViewBuilder
    func standardCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.preferences.categories[idx].includedInOneTapClean },
                set: { newValue in
                    var p = model.preferences
                    p.categories[idx].includedInOneTapClean = newValue
                    model.updatePreferences(p)
                }
            )) { EmptyView() }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            
            let err = model.snapshot?.categoryErrors?[cat.id]
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(cat.title))
                    .font(.system(size: 12))
                Text(LocalizedStringKey(cat.description))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(err == nil ? L(cat.description) : String(format: L("category.scan_failed_help.format"), err!, L(cat.description)))
            }
            
            Spacer()
            
            let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
            Text(formatSize(bytes))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    func runtimesCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.preferences.categories[idx].includedInOneTapClean },
                set: { newValue in
                    var p = model.preferences
                    p.categories[idx].includedInOneTapClean = newValue
                    model.updatePreferences(p)
                }
            )) { EmptyView() }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(cat.title))
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .layoutPriority(2)
                        Text(LocalizedStringKey(cat.description))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(L(cat.description))
                    }
                    
                    Spacer()
                    
                    // 你要求：展开箭头放在容量前面，并且标题左侧对齐
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            isRuntimesExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isRuntimesExpanded ? 90 : 0))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    
                    let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
                    Text(formatSize(bytes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                if isRuntimesExpanded {
                    if model.snapshot?.runtimesByPlatform.isEmpty ?? true {
                        Text("runtime.empty")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        runtimesList
                    }
                    
                    if let msg = model.runtimeDeleteMessage {
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(4)
                        
                        if !model.runtimeFallbackCommands.isEmpty {
                            Button("runtime.copy_fallback") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.runtimeFallbackCommands.joined(separator: "\n"), forType: .string)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }
}

private func platformLabel(_ platform: String) -> String {
    switch platform {
    case "com.apple.platform.iphonesimulator": return "iOS Simulator"
    case "com.apple.platform.watchsimulator": return "watchOS Simulator"
    case "com.apple.platform.appletvsimulator": return "tvOS Simulator"
    case "com.apple.platform.xrsimulator": return "visionOS Simulator"
    default: return platform
    }
}

// Runtime 不提供单独清理按钮（统一由“一键清理”触发）

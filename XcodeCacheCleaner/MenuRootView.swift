//
//  MenuRootView.swift
//  XcodeCacheCleaner
//
//  Created by SOLO on 2026/4/17.
//

import SwiftUI
import AppKit

private let menuWidth: CGFloat = 390
private let categoryListHeight: CGFloat = 535
private let categoryChevronColumnWidth: CGFloat = 12
private let categorySizeColumnMinWidth: CGFloat = 34
private let categoryHeaderTrailingSpacing: CGFloat = 2
private let categoryHorizontalPadding: CGFloat = 12
private let categoryRowSpacing: CGFloat = 8

struct MenuRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRuntimesExpanded: Bool = false
    @State private var isArchivesExpanded: Bool = false
    @State private var expandedItemListCategories: Set<String> = []
    @State private var isUnavailableSimulatorsExpanded: Bool = false
    @State private var isScanErrorDetailsPresented: Bool = false

    private var categorySizeColumnWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widths = model.preferences.categories.map { cat in
            let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
            return (SizeFormatting.short(bytes) as NSString).size(withAttributes: attributes).width
        }
        return ceil(max(categorySizeColumnMinWidth, widths.max() ?? 0))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            Divider()
            categories
            Divider()
            footer
        }
        .padding(12)
        .frame(width: menuWidth)
        .task {
            // 打开菜单时：立即展示快照（已在 model 里做了），然后触发一次后台刷新
            await model.refresh(reason: "menu-open")
        }
    }
    
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            let xcodeSize = model.snapshot.map { SizeFormatting.short($0.xcodeTotalBytes) } ?? "—"
            let xcodePercentOfDisk = model.snapshot.map {
                $0.disk.totalBytes == 0 ? "—" : String(format: "%.1f", (Double($0.xcodeTotalBytes) / Double($0.disk.totalBytes)) * 100.0)
            } ?? "—"
            let diskAvail = model.snapshot.map { SizeFormatting.short($0.disk.availableBytes) } ?? "—"
            let diskPercent = model.snapshot.map { String(format: "%.0f", $0.disk.usedPercent) } ?? "—"
            
            // 顶部信息（你最新要求）
            HStack {
                Text(String(format: String(localized: "summary.xcode_cache.format"), xcodeSize, xcodePercentOfDisk))
                Spacer()
                Text(String(format: String(localized: "summary.disk.format"), diskAvail, diskPercent))
            }
            .font(.system(size: 12))
            
            if let err = model.lastErrorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            
            if let errors = model.snapshot?.categoryErrors, !errors.isEmpty {
                let details: String = {
                    // 在提示中列出失败分类与原因，便于用户定位（尤其是 Sandbox 下的 simctl/runtime 问题）
                    let lines: [String] = errors
                        .sorted(by: { $0.key < $1.key })
                        .map { (id, msg) in
                            let titleKey = model.preferences.categories.first(where: { $0.id == id })?.title ?? id
                            return "\(L(titleKey)): \(msg)"
                        }
                    return lines.joined(separator: "\n")
                }()
                
                // 仅靠 hover 的 tooltip 在 MenuBarExtra 下有时不明显（系统延迟不可控），这里同时支持“点击查看详情”。
                Button {
                    isScanErrorDetailsPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("summary.partial_scan_failed")
                            .lineLimit(2)
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .help(details)
                .popover(isPresented: $isScanErrorDetailsPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("summary.partial_scan_failed")
                            .font(.system(size: 12, weight: .semibold))
                        ScrollView {
                            Text(details)
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(width: 340, height: 160)
                    }
                    .padding(12)
                }
            }

            // 纯 GitHub 开源版本：不走 MAS 沙盒授权流程
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
            } else if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("status.scanning")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            } else if let toast = model.cleanToastMessage {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Text(lastScanText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .center)
    }

    private var lastScanText: String {
        let value = model.snapshot?.createdAt.formatted(date: .abbreviated, time: .shortened)
            ?? String(localized: "last_scan.never")
        let scanText = String(format: String(localized: "last_scan.format"), value)
        guard let scheduleText = autoCleanStatusText else { return scanText }
        return String(format: String(localized: "auto_clean.status.format"), scanText, scheduleText)
    }

    private var autoCleanStatusText: String? {
        switch model.preferences.autoCleanSchedule {
        case .off:
            return nil
        case .every1h:
            return String(localized: "auto_clean.status.every1h")
        case .every4h:
            return String(localized: "auto_clean.status.every4h")
        case .every12h:
            return String(localized: "auto_clean.status.every12h")
        case .every24h:
            return String(localized: "auto_clean.status.every24h")
        }
    }
    
    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("categories.header")
                .font(.system(size: 12, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    categoryRows
                }
                .padding(.horizontal, categoryHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: categoryListHeight)

            // 状态行固定在操作区上方，避免扫描/清理状态切换时菜单整体跳动。
            statusLine
                .padding(.top, 10)
            
            Divider()
            
            bottomActions
        }
    }

    @ViewBuilder
    private var categoryRows: some View {
        ForEach(Array(model.preferences.categories.enumerated()), id: \.element.id) { idx, cat in
            if cat.id == "runtimes" {
                runtimesCategoryRow(prefIndex: idx, cat: cat)
            } else if cat.id == "archives" {
                archivesCategoryRow(prefIndex: idx, cat: cat)
            } else if cat.action == .itemList {
                itemListCategoryRow(prefIndex: idx, cat: cat)
            } else if cat.action == .unavailableSimulators {
                unavailableSimulatorsCategoryRow(prefIndex: idx, cat: cat)
            } else {
                standardCategoryRow(prefIndex: idx, cat: cat)
            }
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
        Picker(
            "schedule.picker.title",
            selection: Binding(
                get: { model.preferences.autoCleanSchedule },
                set: { setSchedule($0) }
            )
        ) {
            ForEach(AutoCleanSchedule.allCases) { schedule in
                Text(schedule.title)
                    .tag(schedule)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
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
                            .disabled(rt.deletable == false)
                            
                            Spacer()
                            
                            if let size = rt.sizeBytes {
                                Text(SizeFormatting.short(size))
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
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("app.name")
                    .font(.system(size: 12, weight: .semibold))
                Text("footer.opensource")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu("menu.about") {
                Button("about.open_github") { AppLinks.openGitHub() }
                Button("about.privacy") { AppLinks.openPrivacy() }
                Divider()
                Button("about.support") { AppLinks.openSupport() }
            }

            Button("action.quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.system(size: 12))
    }
}

#Preview {
    MenuRootView()
        .environmentObject(AppModel())
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func formatArchiveDate(_ date: Date?) -> String {
    guard let date else { return "" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

private func formatOptionalDate(_ date: Date?) -> String {
    guard let date else { return "" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

private extension MenuRootView {
    @ViewBuilder
    func standardCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .center, spacing: categoryRowSpacing) {
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(L(cat.title))
                Text(LocalizedStringKey(cat.description))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(err == nil ? L(cat.description) : String(format: L("category.scan_failed_help.format"), err!, L(cat.description)))
            }
            
            Spacer()

            Color.clear
                .frame(width: categoryChevronColumnWidth, height: 18)
            
            let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
            Text(SizeFormatting.short(bytes))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: categorySizeColumnWidth, alignment: .trailing)
        }
    }
    
    @ViewBuilder
    func runtimesCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .top, spacing: categoryRowSpacing) {
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
                HStack(alignment: .center, spacing: categoryHeaderTrailingSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(cat.title))
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .layoutPriority(2)
                            .help(L(cat.title))
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
                    }
                    .buttonStyle(.plain)
                    .frame(width: categoryChevronColumnWidth, height: 18)
                    
                    let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
                    Text(SizeFormatting.short(bytes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: categorySizeColumnWidth, alignment: .trailing)
                }
                
                if isRuntimesExpanded {
                    if model.snapshot?.runtimesByPlatform.isEmpty ?? true {
                        Text("runtime.empty")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        
                        // 如果 runtimes 扫描失败，把原因直接展示出来（不要依赖 hover）
                        if let err = model.snapshot?.categoryErrors?["runtimes"] {
                            Text(String(format: String(localized: "runtime.scan_failed.inline.format"), err))
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func archivesCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .top, spacing: categoryRowSpacing) {
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
                HStack(alignment: .center, spacing: categoryHeaderTrailingSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(cat.title))
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .layoutPriority(2)
                            .help(L(cat.title))
                        Text(LocalizedStringKey(cat.description))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(L(cat.description))
                    }

                    Spacer()

                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            isArchivesExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isArchivesExpanded ? 90 : 0))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: categoryChevronColumnWidth, height: 18)

                    let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
                    Text(SizeFormatting.short(bytes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: categorySizeColumnWidth, alignment: .trailing)
                }

                if isArchivesExpanded {
                    archivesList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var archivesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            let archives = model.snapshot?.allArchives ?? []
            if archives.isEmpty {
                Text("archive.empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let err = model.snapshot?.categoryErrors?["archives"] {
                    Text(String(format: String(localized: "archive.scan_failed.inline.format"), err))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            } else {
                ForEach(archives) { archive in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { model.selectedArchives[archive.deletionKey] ?? false },
                            set: { model.selectedArchives[archive.deletionKey] = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(archive.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                let dateText = formatArchiveDate(archive.createdAt)
                                if !dateText.isEmpty {
                                    Text(dateText)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .help(archive.path)

                        Spacer()

                        Text(SizeFormatting.short(archive.sizeBytes))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    func itemListCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .top, spacing: categoryRowSpacing) {
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
                expandableHeader(
                    cat: cat,
                    expanded: expandedItemListCategories.contains(cat.id),
                    toggle: {
                        withAnimation(.snappy(duration: 0.18)) {
                            if expandedItemListCategories.contains(cat.id) {
                                expandedItemListCategories.remove(cat.id)
                            } else {
                                expandedItemListCategories.insert(cat.id)
                            }
                        }
                    }
                )

                if expandedItemListCategories.contains(cat.id) {
                    cleanableItemsList(categoryID: cat.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func unavailableSimulatorsCategoryRow(prefIndex idx: Int, cat: CacheCategoryPreference) -> some View {
        HStack(alignment: .top, spacing: categoryRowSpacing) {
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
                expandableHeader(
                    cat: cat,
                    expanded: isUnavailableSimulatorsExpanded,
                    toggle: {
                        withAnimation(.snappy(duration: 0.18)) {
                            isUnavailableSimulatorsExpanded.toggle()
                        }
                    }
                )

                if isUnavailableSimulatorsExpanded {
                    unavailableSimulatorsList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func expandableHeader(cat: CacheCategoryPreference, expanded: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: categoryHeaderTrailingSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(cat.title))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .layoutPriority(2)
                    .help(L(cat.title))
                Text(LocalizedStringKey(cat.description))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(L(cat.description))
            }

            Spacer()

            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: categoryChevronColumnWidth, height: 18)

            let bytes = model.snapshot?.categories.first(where: { $0.id == cat.id })?.sizeBytes ?? 0
            Text(SizeFormatting.short(bytes))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: categorySizeColumnWidth, alignment: .trailing)
        }
    }

    private func cleanableItemsList(categoryID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let items = model.snapshot?.cleanableItems(for: categoryID) ?? []
            if items.isEmpty {
                Text("item.empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { model.selectedCleanableItems[item.deletionKey] ?? false },
                            set: { model.selectedCleanableItems[item.deletionKey] = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                let secondary = item.detail ?? formatOptionalDate(item.createdAt)
                                if !secondary.isEmpty {
                                    Text(secondary)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .help(item.path)

                        Spacer()

                        Text(SizeFormatting.short(item.sizeBytes))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var unavailableSimulatorsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            let devices = model.snapshot?.unavailableSimulators ?? []
            if devices.isEmpty {
                Text("simulator.unavailable.empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { model.selectedUnavailableSimulators[device.deletionKey] ?? false },
                            set: { model.selectedUnavailableSimulators[device.deletionKey] = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(device.availabilityError ?? device.runtimeIdentifier)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .help(device.id)

                        Spacer()

                        Text(device.sizeBytes.map(SizeFormatting.short) ?? "—")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 6)
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

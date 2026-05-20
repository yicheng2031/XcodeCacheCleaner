//
//  StatusLabelView.swift
//  XcodeCacheCleaner
//
//  Created by SOLO on 2026/4/17.
//

import SwiftUI
import AppKit

struct StatusLabelView: View {
    @EnvironmentObject private var model: AppModel
    
    var body: some View {
        let cacheGB = model.snapshot.map { SizeFormatting.gigabytes($0.xcodeTotalBytes) } ?? "—"
        let diskPercent = model.snapshot.map { String(format: "%.0f", $0.disk.usedPercent) } ?? "—"
        let icon = makeStatusIcon(size: 16)
        let label = String(format: String(localized: "statusbar.label.format"), cacheGB, diskPercent)
        
        HStack(spacing: 4) {
            if let icon {
                Image(nsImage: icon)
                    .renderingMode(.original)
                    .frame(width: 16, height: 16)
            }
            Text(label)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

#Preview {
    StatusLabelView()
        .environmentObject(AppModel())
        .padding()
}

//（菜单栏展示使用 GB + 百分比）

private func makeStatusIcon(size: CGFloat) -> NSImage? {
    guard let base = NSImage(named: "Logo") else { return nil }
    let targetSize = NSSize(width: size, height: size)
    
    // 将图标重新绘制到固定尺寸，避免菜单栏 label 被原图尺寸影响导致“很宽”。
    let img = NSImage(size: targetSize)
    img.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: targetSize))
    img.unlockFocus()
    return img
}

//
//  XcodeCacheCleanerApp.swift
//  XcodeCacheCleaner
//
//  Created by YC on 2026/4/17.
//

import SwiftUI
import AppKit

@main
struct XcodeCacheCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    
    var body: some Scene {
        MenuBarExtra {
            MenuRootView()
                .environmentObject(model)
        } label: {
            StatusLabelView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用：不显示 Dock 图标与主窗口。
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

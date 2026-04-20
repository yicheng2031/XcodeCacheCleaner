//
//  AppLinks.swift
//  XcodeCacheCleaner
//

import Foundation
import AppKit

enum AppLinks {
    static let githubURL = URL(string: "https://github.com/yicheng2031/XcodeCacheCleaner")!

    /// GitHub Pages（建议）：https://yicheng2031.github.io/XcodeCacheCleaner/privacy.html
    /// 说明：如果你不打算公开仓库，GitHub Pages 可能无法启用（取决于账号套餐），这时请改用可公开的 Pages 仓库或自有站点。
    static let privacyURL = URL(string: "https://yicheng2031.github.io/XcodeCacheCleaner/privacy.html")!

    /// GitHub Pages（建议）：https://yicheng2031.github.io/XcodeCacheCleaner/support.html
    static let supportURL = URL(string: "https://yicheng2031.github.io/XcodeCacheCleaner/support.html")!

    static func openGitHub() {
        NSWorkspace.shared.open(githubURL)
    }

    static func openPrivacy() {
        NSWorkspace.shared.open(privacyURL)
    }

    static func openSupport() {
        NSWorkspace.shared.open(supportURL)
    }
}

//
//  AppLinks.swift
//  XcodeCacheCleaner
//

import Foundation
import AppKit

enum AppLinks {
    static let githubURL = URL(string: "https://github.com/yicheng2031/XcodeCacheCleaner")!
    static let githubSponsorsURL = URL(string: "https://github.com/sponsors/yicheng2031")!
    static let feishuDonateURL = URL(string: "https://yicheng2031.feishu.cn/wiki/UzdPwtONbi9q55kIvEXctCGFnQd?from=from_copylink")!

    /// GitHub Pages（建议）：https://yicheng2031.github.io/XcodeCacheCleaner/privacy.html
    /// 说明：如果你不打算公开仓库，GitHub Pages 可能无法启用（取决于账号套餐），这时请改用可公开的 Pages 仓库或自有站点。
    static let privacyURL = URL(string: "https://yicheng2031.github.io/XcodeCacheCleaner/privacy.html")!

    /// 支持与反馈：优先 GitHub Issues（开源分发）
    static let supportURL = URL(string: "https://github.com/yicheng2031/XcodeCacheCleaner/issues")!

    static func openGitHub() {
        NSWorkspace.shared.open(githubURL)
    }

    static func openGitHubSponsors() {
        NSWorkspace.shared.open(githubSponsorsURL)
    }
    
    static func openFeishuDonate() {
        NSWorkspace.shared.open(feishuDonateURL)
    }

    static func openPrivacy() {
        NSWorkspace.shared.open(privacyURL)
    }

    static func openSupport() {
        NSWorkspace.shared.open(supportURL)
    }
}

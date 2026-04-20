# Xcode Cache Cleaner

菜单栏小工具，用于扫描并清理常见的 Xcode / Simulator 缓存目录。  
A menu bar utility to scan and clean common Xcode / Simulator caches.

---

> **本项目的文档、开发、构建全部由 TRAE SOLO（MTC 模式）完成。感谢 AI。**  
> **All documentation, development, and builds for this project were completed by TRAE SOLO (MTC mode). Thanks to AI.**

---

## 功能 / Features

- 一键清理：按分类选择参与清理的项目  
  One-tap clean: choose which categories are included
- 定时自动清理：可选每 1/4/12/24 小时执行  
  Scheduled auto-clean: every 1/4/12/24 hours
- Runtime 管理：查看并删除旧的 Simulator Runtimes（可重新下载）  
  Runtime management: view & delete old Simulator runtimes (re-download anytime)
- 兼容 Mac App Store 沙盒：通过用户授权目录访问实现扫描与清理  
  Sandbox-friendly: requests user-granted folder access when distributed on the Mac App Store
- 可选“捐赠入口”（应用内购买 Tip Jar，不会解锁任何额外功能）  
  Optional “Tip Jar” donation (In-App Purchase, no extra features unlocked)

## 支持作者 / Support

Mac App Store 版本：请在应用内使用“Donate / Tip Jar”（IAP）支持作者（不会解锁任何额外功能）。  
Mac App Store build: please use the in-app “Donate / Tip Jar” (IAP) to support development (no extra features unlocked).

GitHub 版本：可通过飞书页面（国内）或 GitHub Sponsors（海外）支持作者。  
GitHub build: you can support the project via Feishu (CN) or GitHub Sponsors (global).

- 飞书（国内支持入口）：https://yicheng2031.feishu.cn/wiki/UzdPwtONbi9q55kIvEXctCGFnQd?from=from_copylink  
  Feishu (CN support page): https://yicheng2031.feishu.cn/wiki/UzdPwtONbi9q55kIvEXctCGFnQd?from=from_copylink
- GitHub Sponsors（审核中）：https://github.com/sponsors/yicheng2031  
  GitHub Sponsors (pending review): https://github.com/sponsors/yicheng2031

## Mac App Store（沙盒）说明 / Mac App Store (Sandbox) Notes

由于沙盒限制，应用无法直接访问 `~/Library/...` 下的缓存目录，需要通过用户授权（security-scoped bookmark）获得访问权限。  
Due to sandbox restrictions, the app needs user-granted folder access (security-scoped bookmark) to scan/clean `~/Library/...`.

打开应用菜单 → **关于** → **授权访问…**，建议选择你的 `~/Library` 文件夹。  
Open the app menu → **About** → **Grant Access…** and select your `~/Library` folder (recommended).

## 开发 / Development

- Xcode 15+ / macOS 13+  
  Xcode 15+ / macOS 13+
- SwiftUI 菜单栏应用（`MenuBarExtra`）  
  SwiftUI menu bar app (`MenuBarExtra`)

## 捐赠（IAP Tip Jar）/ Tip Jar (IAP)

项目内已包含 StoreKit 2 的 consumable “Tip Jar” 代码。  
This project includes StoreKit 2 code for a consumable “Tip Jar”.


## 开源协议 / License

MIT License，详见 [LICENSE](./LICENSE)。  
MIT License. See [LICENSE](./LICENSE).

## 隐私 / Privacy

详见 [PRIVACY.md](./PRIVACY.md)。  
See [PRIVACY.md](./PRIVACY.md).

# Xcode Cache Cleaner

Free, open-source macOS menu bar utility for scanning and cleaning Xcode, Simulator, SwiftPM, archive, and device-support cache files.

Xcode Cache Cleaner 是一个免费开源的 macOS 菜单栏工具，用于扫描和清理 Xcode、Simulator、SwiftPM、归档以及真机调试相关缓存。

[Download DMG](https://github.com/yicheng2031/XcodeCacheCleaner/releases/latest) · [Website](https://yicheng2031.github.io/XcodeCacheCleaner/) · [Privacy](./PRIVACY.md) · [Issues](https://github.com/yicheng2031/XcodeCacheCleaner/issues)

## English

### Highlights

- Menu bar first: scan, review, and clean without opening Xcode.
- Selective cleanup: clean entire categories or expand a category and select individual items.
- Runtime cleanup that uses stable Simulator Runtime identifiers.
- Archives, Runtimes, DerivedData, SwiftPM caches, unavailable simulators, and logs can be reviewed before deletion.
- Scheduled cleanup every 1, 4, 12, or 24 hours.
- Local only: no account, no analytics, no cloud sync, and no tracking.

### Cleanup Categories

- DerivedData
- Xcode caches
- Simulator logs and caches
- SwiftUI preview data
- Simulator device data
- iOS DeviceSupport files
- Xcode archives
- Xcode activity logs
- SwiftPM dependency caches
- Simulator Runtimes for iOS, watchOS, tvOS, and visionOS
- Unavailable simulator devices
- Device logs and crash reports
- Xcode product caches

### Compatibility

- macOS 13 or later
- Intel and Apple Silicon Macs
- Universal 2 release build: `x86_64` + `arm64`

The GitHub Release package is a DMG. If macOS blocks the app after download, open **System Settings > Privacy & Security** and allow it there.

### Development

Requirements:

- macOS 13+
- Xcode 15+

Build and launch locally:

```bash
./script/build_and_run.sh
```

Build, launch, and verify the process:

```bash
./script/build_and_run.sh --verify
```

Create a Universal 2 DMG:

```bash
./script/package_release.sh
```

The release artifact is written to `dist/`.

## 简体中文

### 主要特性

- 菜单栏优先：无需打开 Xcode，即可扫描、查看和清理缓存。
- 精确清理：既可以按分类清理，也可以展开分类后勾选具体项目。
- Runtime 清理使用稳定的 Simulator Runtime 标识符，降低删除失败概率。
- 归档、Runtime、DerivedData、SwiftPM 缓存、不可用模拟器和日志都可以在删除前查看。
- 支持每 1、4、12、24 小时定时自动清理。
- 完全本地运行：不需要账号，不做统计分析，不上传数据，不追踪用户。

### 可清理内容

- DerivedData
- Xcode 缓存
- 模拟器日志和缓存
- SwiftUI 预览数据
- 模拟器设备数据
- iOS DeviceSupport 真机符号文件
- Xcode 归档
- Xcode 活动日志
- SwiftPM 依赖缓存
- iOS、watchOS、tvOS、visionOS 的模拟器 Runtime
- 不可用模拟器设备
- 真机诊断日志和崩溃记录
- Xcode 产品缓存

### 兼容性

- macOS 13 或更高版本
- 支持 Intel 与 Apple Silicon Mac
- Release 包为 Universal 2：`x86_64` + `arm64`

GitHub Release 提供 DMG 安装包。如果 macOS 下载后拦截打开，请到 **系统设置 > 隐私与安全性** 中允许打开。

### 开发

环境要求：

- macOS 13+
- Xcode 15+

本地构建并启动：

```bash
./script/build_and_run.sh
```

构建、启动并验证进程：

```bash
./script/build_and_run.sh --verify
```

创建 Universal 2 DMG：

```bash
./script/package_release.sh
```

生成的发布文件位于 `dist/`。

## Privacy / 隐私

See [PRIVACY.md](./PRIVACY.md). The app works locally and does not collect or upload user data.

请查看 [PRIVACY.md](./PRIVACY.md)。应用只在本机工作，不收集或上传用户数据。

## License / 许可证

MIT License. See [LICENSE](./LICENSE).

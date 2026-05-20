# Xcode Cache Cleaner

Xcode Cache Cleaner is a free and open-source macOS menu bar utility for scanning and cleaning common Xcode, Simulator, SwiftPM, and archive cache locations.

Xcode Cache Cleaner 是一个免费开源的 macOS 菜单栏工具，用于扫描和清理常见的 Xcode、Simulator、SwiftPM 与归档缓存目录。

## Features

- Scan Xcode-related cache usage from the menu bar.
- Clean selected categories instead of deleting everything blindly.
- Expand and select individual Simulator Runtimes, Archives, DerivedData folders, SwiftPM caches, device logs, and unavailable simulators.
- Schedule automatic cleanup every 1/4/12/24 hours.
- Keep everything local. The app does not collect or upload user data.

## Cleanup Categories

- DerivedData
- Xcode Caches
- Simulator Logs/Caches
- SwiftUI Previews
- Simulator Devices data
- iOS DeviceSupport
- Archives
- Xcode Logs
- SwiftPM Caches
- Simulator Runtimes
- Unavailable Simulators
- Device Logs
- Xcode Products

## Download

Download the latest build from [GitHub Releases](https://github.com/yicheng2031/XcodeCacheCleaner/releases).

If macOS warns that the app cannot be opened because it was downloaded from the internet, open **System Settings > Privacy & Security** and allow it there. Release signing/notarization depends on the published release package.

## Development

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

Create a release zip:

```bash
./script/package_release.sh
```

The release artifact is written to `dist/`.

## Privacy

See [PRIVACY.md](./PRIVACY.md). The app works locally and does not collect analytics or upload user data.

## Support

Please open an issue on GitHub:

https://github.com/yicheng2031/XcodeCacheCleaner/issues

## License

MIT License. See [LICENSE](./LICENSE).

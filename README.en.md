# OpenDock

A native macOS Dock manager built with SwiftUI and AppKit. Save and switch layouts, or use a separate Dock with apps, files, and widgets. Requires macOS 13+ and Swift 5.9+. No third-party Swift packages.

[中文](README.md) · [Feature comparison](docs/FEATURES.md) · [Usage](docs/USAGE.md) · [Contributing](CONTRIBUTING.md)

This is an independent implementation inspired by Dockset's publicly documented functionality. OpenDock uses its own code, name, and artwork, and is not affiliated with Dockset or its developer. No Dockset source, binaries, licensing implementation, or artwork is included. References: [product](https://dockset.app), [changelog](https://dockset.app/changelog), [manual](https://dockset.app/manual).

## Scope

- Custom and native macOS Dock profiles, with an editor for apps, files, folders, URLs, spacers, and app groups.
- A separate native Dock panel with edge placement, size, material, auto-hide, running apps, and widgets.
- Menu bar and global keyboard switching, JSON import/export, and backups before native Dock changes.
- Sixteen widgets for time, productivity, system information, weather, Shortcuts, music, and AirDrop.

This initial development version does not provide full Dockset 0.2.6 parity. Commercial integrations, AI provider usage, cached window previews, and native Focus Filters are not implemented. See the [feature matrix](docs/FEATURES.md) for status and verification limits.

## Build

Install Xcode Command Line Tools (`xcode-select --install`) if needed, then:

```sh
swift build
swift test
./scripts/build-app.sh
open build/OpenDock.app
```

Use the application bundle for permission-dependent features, login items, and URL handling. `swift run OpenDock` is useful for basic UI development, but a terminal process has a different permission identity.

The script creates `build/OpenDock.app`, an original icon, and a local ad hoc signature. The locally validated Beta is Apple Silicon (arm64). Scripts build for the current toolchain architecture; CI artifacts follow the runner architecture. These are not Universal Binaries. To package a DMG:

```sh
./scripts/package-dmg.sh
```

This Beta is not notarized or App Store certified. Gatekeeper approval may be required on other Macs, and ad hoc signatures do not provide a stable identity for permission prompts across updates. An optional `OPENDOCK_SIGN_IDENTITY` explicitly selects your own signing certificate; notarization is a separate process.

GitHub Actions builds and tests on `macos-15`, then preserves the bundled app in a ZIP artifact. CI cannot validate real-device permission prompts, every Dock interaction, or notarization.

## Privacy and native Dock changes

Profiles and local widget settings stay on this Mac. OpenDock has no account, telemetry, or sync service. Exported JSON may contain private paths, notes, and widget configuration. Weather requests go to an external service, and Calendar, Reminders, and music automation request system permissions as needed. See [privacy](docs/PRIVACY.md).

First launch creates custom OpenDock profiles and attempts to read and save the current Apple Dock's pinned layout. This does not change Apple's Dock. Before applying a native profile, save your current layout. Applying a native layout restarts the Dock and may briefly interrupt its display. See the [backup and recovery guide](docs/USAGE.md#原生-dock-备份与恢复).

## License

[MIT](LICENSE), copyright 2026 OpenDock contributors, applies to this project's code and original icon. Weather data and API access follow [Open-Meteo's terms](https://open-meteo.com/en/terms). Contributions are welcome; please do not submit private profiles, credentials, or third-party product assets.

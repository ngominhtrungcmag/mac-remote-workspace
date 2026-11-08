# Mac Remote Workspace

A native, local-first macOS workspace for SSH, SFTP and remote desktops.

## Features

- SSH terminal tabs powered by SwiftTerm, strict host-key verification and Keychain credentials
- SFTP browsing and transfers, ProxyJump and local SSH tunnels
- Embedded RDP using FreeRDP, serial console and command snippets
- Host inventory with metadata import/export; English and Vietnamese interfaces

Requires macOS 14 or later on Apple Silicon or Intel.

## Install and update

Download the app from [GitHub Releases](../../releases). To update, download and install the new release manually; version 1.0 has no automatic updater.

## Build from source

Install Xcode and its command line tools, then run:

```sh
./scripts/build-freerdp-macos.sh
cd apps/macos
swift build
swift test
./bundle-app.sh
```

The app is produced in `apps/macos/.build/NativeApp/`. The FreeRDP build defaults to both architectures; set `ARCHS=arm64` or `ARCHS=x86_64` for a single architecture.

## Security

Host keys must be explicitly trusted before authentication; mismatches block the connection. Credentials are stored in macOS Keychain and exports exclude secrets. macOS may ask you to allow Keychain access. See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Screenshots

TODO: add current screenshots in `apps/macos/evidence/`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and [LICENSE](LICENSE) for the MIT license.

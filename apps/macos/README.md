# Native macOS app

Mac Remote Workspace is a local-first SSH, SFTP, RDP and serial workspace for macOS 14 or later. It uses SwiftTerm for terminal emulation and FreeRDP for embedded remote desktops.

## Build and run

From the repository root, build the FreeRDP dependency first, then build and test the app:

```sh
./scripts/build-freerdp-macos.sh
swift build --package-path apps/macos
swift test --package-path apps/macos
apps/macos/build-native.sh
apps/macos/bundle-app.sh
```

The bundle is written to `.build/NativeApp/` under this directory. `./bundle-app.sh --install` installs it in `/Applications`, backing up an existing app.

## Security and features

SSH and SFTP verify host keys before authentication. Unknown keys require explicit approval and mismatches block authentication. Credentials are stored in Keychain, with app-mediated one-shot secret delivery to ssh and no secret on disk. ProxyJump verifies each hop independently. Local tunnels bind only to loopback.

SFTP transfers use staging files and require confirmation before overwriting. Downloads report progress; transfers can be cancelled. Metadata exports exclude secrets and host-trust decisions. Embedded RDP uses a separate helper and supports keyboard, pointer and clipboard sharing.

Run `./run-ssh-fixture.sh` and `./run-proxyjump-fixture.sh` for disposable local SSH integration tests.

## Limitations

- ProxyJump supports one hop and authenticates through the active SSH agent only; Keychain/password credentials are rejected for jump hosts. SFTP and host metrics do not support ProxyJump hosts yet and say so instead of connecting directly.
- SFTP listings are parsed from OpenSSH batch `ls -l` output; a server that deliberately crafts file names containing newlines can display misleading rows.
- Folder upload and dragging files from the SFTP browser to Finder are not supported yet; uploads have no idle timeout (cancel manually), downloads time out after 5 minutes without progress.
- Credentials for the SSH password prompt are delivered through a one-shot FIFO that waits up to 30 seconds for `ssh` to ask.
- RDP credential delivery for CA-validated certificates is deferred until after 1.0.
- SSH tabs are not restored between launches. Embedded RDP interoperability, clipboard behavior and keyboard layouts should be verified against the intended Windows server.
- Updates are installed manually from GitHub Releases.

# Contributing

Install Xcode and its command line tools on macOS 14 or later. Build the FreeRDP dependency and the native app from the repository root:

```sh
./scripts/build-freerdp-macos.sh
swift build --package-path apps/macos
swift test --package-path apps/macos
apps/macos/build-native.sh
apps/macos/bundle-app.sh
```

Use `ARCHS=arm64` or `ARCHS=x86_64` for a single-architecture FreeRDP build. For SSH trust or session changes, run `apps/macos/run-ssh-fixture.sh` against its disposable local server. Do not test against production servers without explicit authorization.

Open a pull request describing the change, tests and limitations. Include negative and security tests when relevant and screenshots for UI changes. Product code belongs in `apps/macos/`; use typed service boundaries, preserve strict host-key verification, keep secrets out of logs and persistent metadata, and never construct shell commands from remote paths or user text. See [AGENTS.md](AGENTS.md) for the full project rules.

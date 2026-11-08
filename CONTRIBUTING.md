# Contributing

Install Xcode 27 or later (Swift 6.4) and its command line tools. The app runs on macOS 14 or later. Build the FreeRDP dependency and the native app from the repository root:

```sh
./scripts/build-freerdp-macos.sh
swift build
swift test
./build-native.sh  # debug build only
./bundle-app.sh
```

For a single architecture, set `ARCHS` for the FreeRDP build and the same value in `MRW_ARCHS` for the bundle, e.g. `ARCHS=arm64 ./scripts/build-freerdp-macos.sh && MRW_ARCHS=arm64 ./bundle-app.sh`. For SSH trust or session changes, run `./run-ssh-fixture.sh` against its disposable local server. Do not test against production servers without explicit authorization.

Open a pull request describing the change, tests and limitations. Include negative and security tests when relevant and screenshots for UI changes. Product code belongs in `Sources/**` and `Tests/**`; use typed service boundaries, preserve strict host-key verification, keep secrets out of logs and persistent metadata, and never construct shell commands from remote paths or user text. See [AGENTS.md](AGENTS.md) for the full project rules.

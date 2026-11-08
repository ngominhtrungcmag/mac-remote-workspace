# ADR-011: Native Embedded RDP Transport and Rendering Engine

**Status:** Accepted (implementation in progress; helper process isolation implemented, IOSurface frame sharing and real-host verification pending)  
**Date:** 2026-10-30  
**Scope:** Architecture and implementation strategy for Native Remote Windows (Embedded RDP)

## Context

In V1 (P1), Mac Remote Workspace delegated Windows remote desktop access to the external Microsoft Windows App (`com.microsoft.rdc.macos`) using the `rdp://` URI scheme ([ADR-005](file://<home>/sources/github/mac-remote-workspace/docs/13-adr-risks.md#L11), [`RdpLauncher.swift`](file://<home>/sources/github/mac-remote-workspace/apps/macos/Sources/AppCore/RdpLauncher.swift)). While safe and credential-free, this approach forces users to install a third-party application, disrupts multi-session context switching, and breaks the native workspace vision.

To deliver an integrated, local-first remote workspace experience, the application requires an **Embedded Native RDP Session** (FR-021, US-021, SP-04) that renders directly within an AppKit/SwiftUI workspace tab on macOS without external application dependencies.

## Options Considered

1. **Pure Swift RDP Engine from scratch:**
   - *Pros:* 100% memory-safe Swift, seamless SPM integration.
   - *Cons:* RDP consists of over 50 complex ITU-T / Microsoft specifications (MS-RDPBCGR, MS-CSSP, MS-RDPEFS, MS-RDPEGFX, MS-RDPEDISP, etc.). Developing and maintaining this in pure Swift is infeasible for the product scope.
2. **Web / Guacamole Framebuffer via WKWebView:**
   - *Pros:* Rapid prototype using web technologies.
   - *Cons:* Strictly violates core project invariants (*"Do not place raw framebuffers in a WebView"*, local-first, zero server agents). Severe latency and lack of native Retina/HiDPI integration.
3. **IronRDP (Rust Core):**
   - *Pros:* Modern, memory-safe.
   - *Cons:* Codec support (H.264 / VideoToolbox acceleration), dynamic resolution negotiation (`MS-RDPEDISP`), and macOS display pipelines are experimental and not yet production-ready for interactive desktop remoting.
4. **FreeRDP v3 C-Core with Metal Acceleration (Selected):**
   - *Pros:* Mature, industry-standard RDP engine (proven by Royal TSX and Remmina). Comprehensive support for NLA/CredSSP v5/v6, TLS 1.3, RDPGFX (AVC444/H.264), dynamic resolution (`RDPEDISP`), audio, and clipboard (`cliprdr`).
   - *Cons:* C codebase carries memory-safety risks and bundle size overhead (~15 MB).

## Decision

Adopt **FreeRDP v3** as the native protocol engine, integrated into `apps/macos/` with the following architectural constraints:

1. **Rendering Pipeline:** Decoded framebuffers are rendered via **`CAMetalLayer`** (`MTKView` / Metal) to ensure 60 FPS performance and hardware-accelerated H.264 decoding via `VideoToolbox`. No raw framebuffers in WebViews.
2. **Process Isolation:** The FreeRDP protocol loop and codec routines execute in an out-of-process helper (`RdpSessionHelper` / XPC Service). Framebuffers are shared zero-copy with the main application via **`IOSurface`**. A crash or hang in the C engine will never terminate the main macOS application.
3. **Keychain-Backed NLA Authentication:** NLA (CredSSP) credentials (username, domain, password) are resolved directly from Apple Keychain (`KeychainService`) and injected in-memory into the FreeRDP context. Secrets are never exposed to argv, SQLite, disk files, or URLs.
4. **Strict Host Trust (TOFU):** Windows Server TLS certificates are inspected before authentication. The certificate's SHA-256 fingerprint is presented to the user for explicit trust confirmation on first use. Any certificate mismatch blocks connection immediately.
5. **Dynamic Resolution & Retina:** The `RDPEDISP` virtual channel is enabled to negotiate real-time desktop resolution changes upon window resize, with `DesktopScaleFactor: 200` negotiated for Retina displays.
6. **Graceful Fallback:** The existing external `RdpLauncher` is retained as an optional secondary launch action during the Beta period.

## Consequences

- An XCFramework build script (`scripts/build-freerdp-macos.sh`) will be added to cross-compile FreeRDP v3 (universal `arm64` and `x86_64`) with non-essential modules stripped.
- SPM `Package.swift` will link the resulting binary target into `AppCore`.
- Code signing and entitlements must include `com.apple.security.network.client` for outbound TCP 3389 connections.
- Verification requires disposable Windows Server or container fixtures (similar to `run-ssh-fixture.sh`) testing certificate verification, NLA auth, and resize events.

## Validation & Feasibility Gate (SP-04)

Phase 0 (Spike SP-04) must prove headless NLA connection and basic Metal frame blitting before interactive UI features are integrated.

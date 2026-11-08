# D07 — SSH, SFTP, RDP, Tunnels & Session Lifecycle

## 1. SSH design

**Selected native transport:** the macOS OpenSSH client launched by `NativeSSHTransport` with a fixed executable path and typed arguments. `NativeSSHHostTrustService` performs a separate `ssh-keyscan` probe and applies the app's explicit trust decision before starting the authenticated PTY process. Do not add a Rust SSH implementation to the native target.

### Handshake và trust

1. Validate host profile (`address`, `port`, `username`, auth kind).
2. DNS resolve + TCP connect với timeout/cancel.
3. SSH key exchange, lấy public host key/algorithm và tính SHA256 fingerprint.
4. Kiểm tra known-hosts theo hostname+port; matched cho phép auth, unknown phải được người dùng chấp nhận, mismatch block hard.
5. Auth via password or key/ssh-agent; SSH agent identities phải được người dùng chọn nếu có nhiều lựa chọn.
6. Open shell + request PTY (rows/cols, terminal type) và stream output.
7. Shutdown/timeout/cancel close channel/socket; state event nhất quán.

**Do not:** auto-accept unknown host, fallback sang thuật toán yếu không cảnh báo, log auth material, đặt password vào command-line args, retry failed authentication vô hạn.

### Terminal

The native UI owns terminal presentation while `NativeSSHTransport` owns the OpenSSH process and PTY. Input Unicode/IME, large paste, OSC sequences, terminal hyperlinks and clipboard behavior need tests, including OSC 52, URL opening and escape injection. Render remote output as text, never as executable markup. Resize the local PTY so the OpenSSH client sends the size change to the remote terminal.

### Authentication priority

- Private key file path qua user selection; secret passphrase ở Keychain nếu user chọn save.
- SSH Agent identity path tránh sao chép key secret; cần xác nhận identity nào được dùng.
- Password authentication sử dụng Keychain; interactive keyboard-interactive auth chỉ hỗ trợ khi spike/test đảm bảo.
- Keychain locked/prompt rejected => `CREDENTIAL_UNAVAILABLE` hoặc `CREDENTIAL_ACCESS_DENIED`, không ngầm retry.

## 2. SFTP design

**Supported P0:** list, stat, mkdir, rename, delete single selection with confirm, upload/download, conflict policy, progress, cancel. Batch multi-file transfer chỉ ở P0 nếu queue/state đã ổn định; otherwise milestone sau.

**Path policy:** OS filesystem file path và remote POSIX-style path là hai kiểu khác nhau; không nối bằng string không kiểm tra. Remote names có thể chứa newline/control codes; sanitize khi display/alert, giữ nguyên byte semantics trong protocol. Symlink traversal phải bảo vệ thao tác destructive. Không cố giả định mọi server đều hỗ trợ symlink, posix-rename, checksum, fsync.

### Transfer algorithm

- `TRANSFER_CREATED` -> `VALIDATING` -> `RUNNING` -> `VERIFYING` -> `COMPLETED` / `FAILED` / `CANCELLED`.
- Upload: nếu có thể, sử dụng temp path bất ngờ trong cùng directory, ghi chunks, close, kiểm tra bytes, rename vào đích với conflict policy; nếu server không đảm bảo atomic rename thì cảnh báo và không cam kết rollback.
- Download: ghi vào `.part` dưới user-selected local folder, flush/sync đủ mức, kiểm tra size, rename sau khi complete. Nếu disk full, giữ metadata FAILED và cleanup file .part có kiểm soát.
- Retry không mặc định overwrite target. Resume optional không thuộc P0 vì SFTP server behavior khác nhau.
- Concurrency 2 default, không giới hạn memory theo số file; streaming chunks và bounded queue.

## 3. SSH tunneling (P1)

Chỉ **local port forward** lúc đầu: bind `127.0.0.1`, forward TCP tới remote host/port qua SSH. Người dùng chọn local port, kiểm tra đã bị dùng, allow cancel/close, hiện endpoint rõ. `0.0.0.0` không cho default; nếu support sau này phải có elevated warning, không lộ tunnel ngoài máy ngoài ý muốn. Dynamic/remote forwarding sang P2 có threat review riêng.

## 4. RDP external launcher (P1)

**Goal:** cho phép người dùng từ host profile mở Windows desktop trong client RDP đã cài, không embed RDP vào native app. RDP protocol được delegated cho external client nên app không đảm bảo kết nối thành công, clipboard, audio, multi-monitor hay session persistence.

- Capability detection: tìm approved RDP clients/URL schemes đã xác minh trên macOS matrix.
- User chọn client ở Settings; app hướng dẫn mở nếu chưa cài.
- Avoid passing password via command-line arguments, URL hoặc generated config. Username/domain chỉ đi nếu backend/client support an toàn; fallback copy endpoint không secrets.
- RDP profile files (.rdp) chỉ được generate với các trường non-secret và có vòng đời temp file/cleanup + permission restrictive.
- Chỉ hiển thị `Launched`, không hiển thị `Connected` nếu không có reliable protocol callback.

### RDP embedded (P2 feasibility gate)

FreeRDP remains a feasibility candidate only. A spike must validate AppKit window/surface embedding, NLA/CredSSP, TLS/certificate policy, HiDPI, keyboard mapping, clipboard, audio/USB policy, reconnect, multi-monitor, performance, sandboxing, signing and notarization. Do not place raw framebuffers in a WebView. If the spike fails, keep the external launcher.

## 5. Session registry

Session ID là UUID, không persist process or file-descriptor handles. A Swift session registry owns `{profileID, state, process/PTY owner, openedAt, lastHeartbeat}`. Một host được mở nhiều session; ngắt kết nối một session không tự đóng các session khác trừ khi có dependency tunnel explicit.

`connect()` returns the session identifier and observable initial state. Typed Swift state updates reflect handshake/auth. `disconnect()` is idempotent; missing sessions return a typed error. SwiftUI observation must be released when a sheet closes, and the session owner must terminate/reap its process and close PTY descriptors.

## 6. Security-relevant failure scenarios

| Failure | Handling |
|---|---|
| DNS fails | `DNS_RESOLUTION_FAILED`, show resolver/diagnostic suggestion |
| Host key changed | Hard stop, show old/new fingerprints và out-of-band instructions |
| Auth rejects | Stop auth retry, distinguish password/key agent |
| Keychain deny | Do not fallback insecure storage; ask reauthorize |
| Network drops during upload | Mark transfer INTERRUPTED, no fake completed result |
| RDP client unavailable | Show install/select client, copy endpoint fallback |
| App quit with file transfer | Confirm cancellation and perform best-effort cleanup |

## 7. Compatibility matrix (planned)

| Server/Test Environment | SSH | SFTP | RDP |
|---|---|---|---|
| Ubuntu 22.04/24.04 OpenSSH | P0 | P0 | — |
| Debian current stable OpenSSH | P0 | P0 | — |
| Windows OpenSSH Server | P1 candidate | P1 candidate | — |
| Windows Server 2019/2022/2025 | — | — | P1 external / P2 embedded |
| macOS OpenSSH test host | P0 CI where feasible | P0 CI | — |

Những dòng là **test targets**, không phải cam kết đã kiểm thử. Cần cập nhật OS/server version theo support lifecycle tại thời điểm phát hành.



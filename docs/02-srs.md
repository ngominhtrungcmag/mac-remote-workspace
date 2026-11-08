# D02 — Software Requirements Specification (SRS)

## 1. Quy ước

MUST = P0, SHOULD = P1, COULD = P2.  Nhóm module: HOST (H), AUTH (A), SSH (S), SFTP (F), SESSION (E), RDP (R), DATA (D), UX (U), NETWORK (N).

## 2. Functional requirements

| ID | Ưu tiên | Yêu cầu cụ thể | Acceptance criteria (định lượng/xác định) |
|---|---|---|---|
| FR-001 | MUST | Tạo host với tên, address, port, protocol, environment, credential reference | Validate port 1–65535, hostname, required fields; không cho host trống |
| FR-002 | MUST | CRUD host/group/tag với delete confirmation | Xóa host xóa liên kết metadata, không tự xóa secrets được dùng bởi host khác |
| FR-003 | MUST | Search/filter host theo tên, tag, env, protocol | Search không phân biệt chữ hoa thường; debounce; không truy vấn secrets |
| FR-004 | MUST | Vault lưu và tham chiếu password/passphrase trong Keychain | SQLite chỉ lưu UUID `credential_ref`, không chứa giá trị secret |
| FR-005 | MUST | SSH auth password, key file, ssh-agent | Lỗi auth được phân biệt với network/host-key lỗi |
| FR-006 | MUST | SSH host key verification trước auth | Unknown => fingerprint+approval; mismatch => block, không auto trust |
| FR-007 | MUST | Terminal tab, resize PTY, copy/paste, UTF-8 | Resize truyền SSH window change; >=2 tabs cùng lúc |
| FR-008 | MUST | SSH connect/disconnect/retry có state rõ | Retry chỉ tái kết nối session; không chạy lại command đã gửi |
| FR-009 | MUST | SFTP duyệt cây, breadcrumb, file metadata | Có xử lý thư mục rỗng, quyền truy cập, symbolic link |
| FR-010 | MUST | SFTP upload/download với queue, cancel và status | File partial không hiển thị như đã hoàn tất; cancel không phá file đích mặc định |
| FR-011 | MUST | Delete/overwrite/rename trên SFTP với confirm có target path | Production có cảnh báo nâng cao; không cho xóa ngoài lựa chọn |
| FR-012 | MUST | Workspace nhóm host, khôi phục layout/tab metadata | App restart không tự login lại khi chưa consent hoặc secrets locked |
| FR-013 | MUST | Audit event metadata local, redacted | Ghi outcome/error code, không ghi terminal IO hay file contents |
| FR-014 | MUST | Export/import cấu hình không secrets theo versioned schema | Export loại password, private key bytes, fingerprint ngoại lệ; import dry-run và xử lý trùng |
| FR-015 | MUST | Giao diện keyboard-first, light/dark, accessibility | Focus visible, VoiceOver labels, shortcut collision tests |
| FR-016 | SHOULD | Mở RDP từ host profile bằng external client | Không đặt password trong process arguments/URL; hướng dẫn login trong client |
| FR-017 | SHOULD | SSH local port forwarding có quản lý lifecycle | Binding local mặc định `127.0.0.1`; đóng session thì close tunnel |
| FR-018 | SHOULD | Connection diagnostics: DNS, TCP, SSH handshake timing | Kết quả cho biết lớp lỗi; không lưu endpoint credentials vào report |
| FR-019 | SHOULD | Snippet theo host/group, chỉ chạy sau user confirmation | Preview text/target, cấm auto-execute lúc connect |
| FR-020 | SHOULD | Quick switch workspace/command palette | `Cmd+K` hoặc shortcut đã kiểm tra xung đột |
| FR-021 | COULD | RDP embedded view qua FreeRDP native adapter | NLA/TLS, keyboard/clipboard/HiDPI kiểm thử theo matrix trước GA |
| FR-022 | SHOULD | SSH jump host / ProxyJump (P1) | Chain host key validation riêng, không lộ secret downstream |
| FR-023 | COULD | Dashboard server metrics qua safe readonly commands | Có opt-in; xác định distro compatibility |
| FR-024 | COULD | Plugin API cho protocol adapters | Signed manifest/capability model; không chạy untrusted native code ngầm |
| FR-025 | MUST | Credential unlink và orphan cleanup có confirmation | Xóa host không xóa shared credential đang dùng; hiện ảnh hưởng trước action |
| FR-026 | MUST | External link/file path open có kiểm tra | URL schemes allowlist, không shell interpolate input người dùng |
| FR-027 | MUST | Reconnect storm prevention | Exponential backoff, jitter, cap, user cancel; không retry credentials invalid vô hạn |
| FR-028 | MUST | Session close và app quit xử lý active transfer | Nhắc cancel/finish; teardown socket/subprocess không để child sống sót |

## 3. Business rules

- **BR-01:** Host name có thể trùng; host_id UUID là định danh duy nhất. Duplicates có warning dựa trên endpoint nhưng không cấm tuyệt đối (nhiều account).
- **BR-02:** `environment=production` làm thay đổi giao diện cảnh báo và confirmation, không thay quyền truy cập OS.
- **BR-03:** Một credential có thể gắn cho nhiều host qua reference; xóa credential phải hiển thị danh sách liên quan.
- **BR-04:** Session ngắn hạn; đóng app thì in-memory secrets/SSH handles phải bị hủy; chỉ persistence metadata của tab/layout.
- **BR-05:** RDP external launcher không hứa embed, clipboard isolation hoặc seamless credential handoff.
- **BR-06:** Symlink SFTP có thể trỏ ra ngoài folder; mọi thao tác destructive phải hiện canonical/remote path nếu có thể giải được, và thực hiện trên đối tượng người dùng chọn.
- **BR-07:** Không lưu terminal transcript mặc định, không gửi telemetry mặc định; crash report chỉ opt-in.
- **BR-08:** Import không mặc định ghi đè known_hosts; trust decisions phải xác nhận tại máy mới.

## 4. Nonfunctional requirements

| ID | Mục tiêu thiết kế và phương pháp đo |
|---|---|
| NFR-001 Performance | Cold start target p90 <= 3s trên Mac Apple Silicon tiêu chuẩn định nghĩa sau; đo 30 lần, tách startup app và network |
| NFR-002 Responsiveness | Input terminal render mục tiêu không lag dễ nhận thấy với 10 SSH sessions; đo trên LAN/WAN giả lập và payload throughput giới hạn |
| NFR-003 Stability | 8h soak 10 sessions + transfer queue, không memory leak xu hướng tăng vô hạn, không orphan subprocess |
| NFR-004 Security | Không có secrets trong SQLite, logs, exports, crash reports; fuzz validation host/path/events; signed+notarized release |
| NFR-005 Recoverability | Transfer interruption được đánh dấu FAILED/CANCELLED; retry có explicit action; không ghi đè đích khi chưa complete |
| NFR-006 Offline | Host inventory/workspace sử dụng được không mạng; connect fail giải thích rõ |
| NFR-007 Accessibility | WCAG 2.2 AA làm mục tiêu UX; keyboard-only, VoiceOver và reduced motion phải kiểm thử thực tế |
| NFR-008 Compatibility | Baseline target macOS 14+, arm64/x86_64; Xcode/macOS CI matrix có smoke tests; điều chỉnh sau native feasibility review |
| NFR-009 Observability | Structured redacted local logs, log retention 7d mặc định, max size/cap theo cấu hình |
| NFR-010 Data integrity | Migrations transactional, rollback khi lỗi; backup metadata trước schema upgrade |
| NFR-011 Packaging | Developer ID signing, hardened runtime, notarization/stapling; SBOM và dependency review |
| NFR-012 Privacy | No-account/no-tracking mặc định; update check tùy chọn, công bố network calls |
| NFR-013 Scalability | Inventory 1,000 hosts vẫn search/filter không lag đáng kể; thử dataset fixture với 10k |
| NFR-014 Maintainability | Core service tách theo domain; protocol engine sau interface; required ADR cho đổi phụ thuộc lớn |

## 5. Constraints / compatibility

- Apple sandbox/security scoped bookmarks cần kiểm tra nếu chọn phân phối qua Mac App Store; kế hoạch đầu tiên Developer ID notarized direct download.
- SSH transport must use the native macOS implementation selected by ADR-010; signing and system OpenSSH compatibility remain release checks.
- FreeRDP native embedding remains **spike-gated** and must target an AppKit surface; the previous WebView design is superseded.
- Host trust phải theo hostname+port và key fingerprint, không đơn thuần dựa trên địa chỉ IP.

## 6. Requirement change control

Mỗi thay đổi requirement phải cập nhật mã FR, ưu tiên, acceptance tests, UX và ADR liên quan. Không thể đóng issue nếu acceptance criteria chưa có bằng chứng test/screenshot/log redacted.



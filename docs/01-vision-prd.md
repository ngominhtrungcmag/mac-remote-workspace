# D01 — Product Requirements Document (PRD)

## 1. Vấn đề và cơ hội

Developer/IT support phải quản lý cùng lúc máy Linux và Windows của nhiều khách hàng. Họ chuyển qua lại giữa Terminal, ứng dụng RDP, FileZilla/Cyberduck, spreadsheet chứa địa chỉ máy chủ và ghi chú. Việc chuyển ngữ cảnh gây mất thời gian và có nguy cơ nhập lệnh/đẩy file nhầm vào production. Nhiều sản phẩm cạnh tranh đã bao quát SSH, RDP, SFTP (ví dụ Termix); cơ hội không phải “all-in-one đầu tiên”, mà là **workspace macOS-native, local-first, ưu tiên độ rõ ràng của ngữ cảnh và an toàn khi vận hành**.

## 2. Product statement

**Mac Remote Workspace (MRW)** giúp một kỹ thuật viên mở đúng máy chủ, đúng môi trường và đúng giao thức từ một cửa sổ, đồng thời quản lý kết nối, thông tin đăng nhập, phiên làm việc và truyền file theo cách có thể kiểm tra, có thể giải thích, có kiểm soát.

### Giá trị khác biệt cần kiểm chứng

- **Context-first:** máy chủ được nhóm theo khách hàng/dự án/môi trường và hiển thị cảnh báo PROD cố định.
- **Native credential safety:** bí mật không cần cloud account; tích hợp Keychain, SSH Agent.
- **Workflow continuity:** terminal và SFTP có thể dùng chung host profile, mỗi session có lịch sử trạng thái nhưng không ghi nội dung terminal theo mặc định.
- **Reliable transport:** kết nối bị gián đoạn thông báo rõ nguyên nhân, không âm thầm chạy lại lệnh có thể gây tác động.
- **Cross-platform growth:** core adapters có thể tái sử dụng nhưng thiết kế UX ưu tiên macOS trước.

## 3. Personas

| Persona | Bối cảnh | Jobs-to-be-done | Pain point | Ưu tiên |
|---|---|---|---|---|
| P-A Developer fullstack | 5–20 server, Linux/.NET/React | SSH debug, SFTP upload, kiểm tra log | Chuyển app, nhầm host | P0 |
| P-B IT Support | 10–100 host/khách hàng | Mở Windows RDP, hỗ trợ người dùng | Danh bạ rời rạc, credentials khó tìm | P1 |
| P-C SysAdmin | Nhiều environment | SSH tunnel, server file inspect | Cấu hình nguy hiểm khi thiếu context | P0/P1 |
| P-D Agency/Consultant | Nhiều khách hàng | Nhóm workspace, chuyển công việc nhanh | Dễ thao tác trên tenant sai | P0 |

## 4. Top user outcomes

1. Người dùng thêm host Linux và kết nối SSH có xác minh identity trong dưới 2 phút ở happy path (target UX, không phải benchmark).
2. Mở terminal và SFTP của cùng host từ một profile, không nhập lại endpoint.
3. Nhìn thấy rõ môi trường PROD/STAGING/DEV trước mọi thao tác ghi file.
4. Mở RDP của Windows host qua client ngoài, không lộ password ở command-line.
5. Chuyển nhóm khách hàng/workspace, giữ session đang chạy khi đổi tab nếu hệ thống còn khả dụng.

## 5. In-scope / out-of-scope

| Giai đoạn | In scope | Ngoài phạm vi |
|---|---|---|
| P0 MVP | host CRUD; groups/tags; secrets references; SSH terminal; SFTP browser/upload/download; session state; keyboard shortcuts; import/export public metadata; audit metadata | RDP embedded; cloud sync; multiuser; auto script execution; VNC/Telnet; AI agents |
| P1 1.0 | RDP launcher (external), SSH local port forwarding, profiles search, diagnostics; configurable snippets với confirmation | Remote port forwarding mặc định; team credentials; recorded terminal |
| P2 2.0 | Embedded RDP feasibility+shipping, multi-monitor, SSH jump hosts (nếu spike), stats, plugin APIs | Full-blown PaaS; password sharing cloud |

## 6. Success measures — đề xuất sau 60 ngày beta

- Activation: >=60% testers thêm được một host và mở SSH thành công (trên môi trường có network access).
- Task completion: >=90% người thử chuyển từ Host List sang terminal/SFTP không cần hỗ trợ.
- Stability: >=99% app sessions kết thúc không crash trên tập máy beta được theo dõi opt-in hoặc thông qua bug reports.
- Security: 0 secrets trong logs/SQLite/export; 100% mismatch host key bị chặn trong integration tests.
- UX: 90th-percentile mở host profile từ launcher dưới 2 giây trên máy thử định nghĩa; SSH handshake phụ thuộc mạng đo riêng.
- Maintainability: >=80% unit test cho core state machine/validation, không dùng chỉ số này để thay thế end-to-end.

**Lưu ý:** KPI là mục tiêu. Cỡ mẫu beta, thiết bị, loại mạng và cách đo cần đăng ký trước khi công bố.

## 7. Competitor baseline

- Termix: quản lý SSH, RDP, VNC, SFTP, Docker, tunnel và desktop standalone; đây là baseline cạnh tranh, không phải “khoảng trống chưa ai làm”.
- 1Remote: thiên về Windows, hỗ trợ nhiều protocol và launcher.
- FreeRDP: thư viện/protocol engine chứ không phải thiết kế UX.
- Ứng dụng chuyên SSH/SFTP: lợi thế ở độ sâu từng giao thức; MRW không nên cố sao chép đầy đủ ngay.

## 8. Monetization và open-source

Mặc định phần desktop core miễn phí, không yêu cầu tài khoản. Nếu về sau có dịch vụ có phí, chỉ nên là tính năng tùy chọn ngoài core (ví dụ quản lý nhóm với E2EE được thiết kế riêng), và phải công khai mô hình giấy phép. Không được tuyên bố “free forever” nếu chưa có quyết định quản trị dự án.

## 9. Launch narrative

- **Early testers:** developer dùng macOS + Linux VPS; nhỏ gọn, kiểm thử SSH/SFTP và Keychain trước.
- **Public beta:** thêm RDP external launcher, signed+notarized artifact, tài liệu khắc phục lỗi.
- **Post-launch:** tập trung reliability, khảo sát RDP nhúng thay vì cam kết ngày ra mắt.

## 10. Rủi ro định vị

- Quá nhiều tính năng tạo bản clone kém chất lượng; cần ưu tiên workflow có thể đo.
- “Native macOS” means the product UI and app lifecycle use SwiftUI/AppKit, with application services implemented in Swift. The legacy WebView/Tauri prototype is not the target.
- Apple notarization/code signing và sandbox có thể ảnh hưởng hỗ trợ file access/sidecar; phải kiểm thử sớm.



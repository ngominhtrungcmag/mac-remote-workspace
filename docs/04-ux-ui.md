# D04 — UX/UI Design System & Wireframes

> **Active implementation target:** Native SwiftUI/AppKit in the repository root (ADR-010); no WebView. The shell and wireframes below are design guidance reconciled to the native app: a system sidebar with Workspace (All Hosts, Transfers), Workspaces with nested Groups, and Security destinations, a host detail inspector, and the standard macOS Settings scene (`⌘,`). Tabs, command palette, SFTP dual-pane, and terminal UIs are planned requirements, not implemented native behavior; see `README.md` for the shipped baseline.

## 1. UX principles

1. **Context always visible:** breadcrumb nhóm/host/environment, PROD caution trên mọi terminal/SFTP tab.
2. **One primary action:** New host, Connect, Open SFTP không bị nhấn chìm trong settings.
3. **No ambiguous trust:** host fingerprint và certificate warning không dùng màu “success” hoặc auto-accept.
4. **Keyboard-first:** command palette, navigation tab, accessible focus, shortcut discoverability.
5. **Progress is truthful:** trạng thái “Connecting” ≠ “Connected”; transfer progress dựa trên bytes confirmed.
6. **Reversible by design:** ghi đè/xóa cần xác nhận mục tiêu rõ, không nút destructive đặt sát nút primary.

## 2. Information architecture

```text
Application
├── Home
│   ├── Recents / Favorites
│   ├── Workspace picker
│   └── Search / Command palette
├── Workspaces
│   ├── Groups / Hosts
│   └── Tabs
│       ├── SSH Terminal
│       ├── SFTP File Manager
│       └── RDP External Launcher (P1)
├── Transfers
│   ├── In progress
│   └── Completed/Failed
├── Credentials
│   └── Credential references (never reveal raw secret by default)
├── Known Hosts
│   └── Fingerprint details / review changes
└── Settings
    ├── Appearance & Accessibility
    ├── SSH/SFTP Defaults
    ├── Privacy & Diagnostics
    └── About, Licenses, Updates
```

## 3. Desktop shell wireframe (1440×900 reference)

```text
┌───────────────────────────────────────────────────────────────────────────┐
│ MRW    [Production / Client A ▼]           ⌕ Search hosts      ⚙      │
├─────────────────┬─────────────────────────────────────────────────────────┤
│ Workspaces      │  SSH: ubuntu-prod ●      SFTP: ubuntu-prod             │
│  ▾ Client A     ├─────────────────────────────────────────────────────────┤
│    ● Ubuntu A   │  [PRODUCTION] ubuntu@ubuntu-a.example:22   ● Trusted   │
│    ● Ubuntu B   │                                                         │
│    ◇ Windows DB │  $ systemctl status nginx                                │
│  ▸ Client B     │  ● active (running)                                     │
│                 │  $ _                                                    │
│ Favorites       │                                                         │
│ Recents         │                                                         │
├─────────────────┤                                                         │
│ [+ Add host]    │                                                         │
├─────────────────┴─────────────────────────────────────────────────────────┤
│ Transfers: 1 pending       SSH encrypted · Last network check: 20:21     │
└───────────────────────────────────────────────────────────────────────────┘
```

## 4. SFTP dual-pane wireframe

```text
┌───────────────────────── Local ───────────────────┬──────── Remote ───────┐
│ ~/Projects/build/         ↑                       │ /var/www/site/       ↑│
│ Name                  Size Modified               │ Name              Size│
│ index.html            2KB  Today                  │ index.html         2KB│
│ assets/                —   Today                  │ assets/             — │
│ runtime-config.json  0.3KB Today                  │ runtime-config.json ...│
├───────────────────────────────────────────────────┴───────────────────────┤
│ Transfer queue: uploading assets/app.js 2.1/4.2 MB        [Cancel]       │
└───────────────────────────────────────────────────────────────────────────┘
```

## 5. Design tokens — baseline (không ràng buộc UI library)

| Token | Light | Dark | Ý nghĩa |
|---|---|---|---|
| `bg.base` | `#F7F9FC` | `#10151D` | app background |
| `bg.surface` | `#FFFFFF` | `#18212D` | panels |
| `text.primary` | `#1D2939` | `#F2F4F7` | body |
| `text.secondary` | `#667085` | `#98A2B3` | metadata |
| `accent.primary` | `#246BCE` | `#77ACFF` | main actions |
| `status.success` | `#067647` | `#47C58A` | connected (kèm icon/text) |
| `status.warning` | `#B54708` | `#F3B25B` | trust/production warnings |
| `status.danger` | `#B42318` | `#F97066` | destructive/errors |
| `radius.md` | 8px | 8px | controls |
| `space.unit` | 4px | 4px | 4/8/12/16/24/32 |

Typography: system sans (SF Pro hệ thống, fallback), terminal monospace hệ thống; không bundle font thương mại. Default body 13–14px, content min touch/click target 32×32 desktop, không chỉ dựa vào màu để nhận trạng thái.

## 6. Component inventory

- `AppShell`, `WorkspaceSwitcher`, `HostTree`, `HostCard`, `HostEditor`, `EnvironmentBadge`, `SessionTabs`, `SessionHeader`.
- `SshTerminal`, `TerminalToolbar`, `ReconnectBanner`, `SftpDualPane`, `RemoteBreadcrumb`, `FileRow`, `TransferQueue`, `OverwriteDialog`.
- `CredentialPicker`, `FingerprintDialog`, `KnownHostReviewDialog`, `RdpLaunchPanel`, `Toast`, `ErrorDetails`, `CommandPalette`.

## 7. Responsive and window policy

- Minimum usable window target `1100×700` for dual-pane; below that SFTP panes switch to stacked view; sidebar collapsible.
- Narrow sizes require no horizontal clipping on dialogs, keyboard shortcuts accessible.
- Native macOS windows: MVP uses one main window and native sheets/dialogs. Embedded RDP (P2) requires a separate AppKit surface/window lifecycle.

## 8. Accessibility checklist

- Interactive elements have semantic role/label/description; terminal accessible instructions; contrast target WCAG AA.
- VoiceOver navigation order: sidebar → tabs → current content → status/transfer tray.
- Keyboard interaction: tab cycle, Esc dismiss non-critical dialogs, no focus trap except modal, no shortcut stealing terminal characters.
- `prefers-reduced-motion`, dynamic type zoom, clear icon+text statuses, announcements on connection state changes.

## 9. UX acceptance examples

- UXT-01: User recognizes active environment before transferring file.
- UXT-02: Unknown host key shown with actionable fingerprint comparison, reject path is obvious.
- UXT-03: Keyboard-only user can create profile, connect, open SFTP and disconnect.
- UXT-04: Failed transfer shows destination path, reason, and safe retry action.
- UXT-05: Cancel dialog preserves previous host edit values.



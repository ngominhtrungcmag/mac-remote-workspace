---
title: Mac Remote Workspace
author: Open Source Software Design
date: 26/10/2026
subtitle: Bộ tài liệu thiết kế hệ thống đầy đủ · Version 1.0
lang: vi-VN
---

# Thông tin tài liệu

**Trạng thái:** Product baseline with an accepted native implementation decision. **Phạm vi:** macOS-first, local-first, open source.
**Core stack:** SwiftUI/AppKit, Swift `AppCore`, SQLite, Apple Keychain, macOS system SSH services.
**Lộ trình:** P0 SSH + SFTP + host/workspaces; P1 external RDP + tunnels; P2 embedded RDP qua feasibility gate.  
**Mục đích:** dùng để trao đổi yêu cầu, lập task triển khai, kiểm thử và phê duyệt kiến trúc.  
**Implementation target:** `repository root` is the sole product target. React/Tauri/Rust files are a superseded prototype. **Giới hạn:** mục tiêu hiệu năng và mức hỗ trợ nền tảng chỉ được coi là đã xác minh khi có bằng chứng kiểm thử native.

# Hướng dẫn đọc

D01–D04: sản phẩm, yêu cầu, UX. D05–D09: kiến trúc, dữ liệu, giao thức, service contracts, bảo mật. D10–D16: kiểm thử, phát hành, roadmap, quyết định, cộng đồng và triển khai. ADR-010 supersedes obsolete Tauri/React/Rust implementation choices in these extracts; see `docs/README.md` for document precedence.


Historical evidence such as [TRACEABILITY.md](implementation/TRACEABILITY.md) retains the former `apps/macos/` paths and conclusions from its review date. The current Swift package is at the repository root; see [README](../README.md) for current commands.

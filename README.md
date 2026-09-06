# Pura Pi

Pura Pi 是面向 macOS 的原生 Pi Agent 图形客户端，使用 SwiftUI/AppKit 构建，并通过本地 `pi --mode rpc` Runtime 工作。

## 构建要求

- macOS 14 或更高版本
- Xcode（支持 Swift tools version 5.10）
- Swift Package Manager

## 使用 Xcode 构建

1. Clone 本仓库。
2. 在 Xcode 中打开根目录的 `Package.swift`。
3. 选择 `WorkPi` scheme 和本机 macOS 目标运行。

## 使用命令行构建

```bash
swift build
swift run WorkPi
swift test
```

## 生成未签名 App 预览包

```bash
./scripts/package-pura-pi-app.sh
open "dist/Pura Pi.app"
```

该脚本只生成本地未签名开发预览，不代表正式发行包。

## Runtime

应用会优先使用用户已有的 `pi`；找不到兼容版本时，可在应用内按确认流程安装用户级 Runtime。普通项目对话使用 Pi 的 JSONL RPC 接口，认证由 Pi 官方认证存储负责。

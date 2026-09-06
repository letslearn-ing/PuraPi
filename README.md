# PuraPi

面向普通 macOS 用户的 Pi Agent 原生图形客户端（开发基线；核心闭环已实现，但当前尚不可发布）。产品名称、SwiftPM package/target/module、内部类型、资源路径和用户界面已统一为 `PuraPi`。旧版 `WorkPi` 标识仅在用户数据迁移和旧版协议兼容读取中保留；详见 [`docs/BRANDING.md`](docs/BRANDING.md)。

## 0.1 定义

PuraPi 不是重新实现 Pi，也不是把 Pi TUI 嵌入窗口。它使用 SwiftUI/AppKit 构建三栏原生界面，并通过 Runtime 供应器启动本地 Pi Runtime：优先复用用户已有安装，缺失时可在用户级目录安装已验证的 Node.js/Pi 版本：

```text
Swift 原生 GUI
    ↓ JSONL stdin/stdout
pi --mode rpc
    ↓
现有 Pi Agent Runtime
```

界面采用项目标签页：每个标签页对应一个文件夹、一个独立 Pi Runtime 和一个默认三栏工作区；右侧 Inspector 可按需挂到独立窗口。

- 顶部：由 AppKit `NSToolbar` 承载的 macOS 系统项目标签栏；原生全高 Sidebar 自动移动 Toolbar 的前导内容边界，标签只用一个系统 `.space` 保持固定间距，因此拖动 Sidebar 时会连续同步移动；
- 左侧：当前项目目录树；Sidebar 可通过 `⌘\\` 整体隐藏或恢复，目录节点可独立展开/收起；根目录只读取直接子项，嵌套目录在展开时按需读取，适合包含数千文件的大型项目；
- 中间：Agent 对话、流式输出和工具活动；AppKit viewport 管理真实滚动文档和底部跟随，每条消息由独立 SwiftUI row 绘制；增量 Markdown block renderer 按稳定块更新，完成后的 Markdown 按标题、段落、列表、引用和代码块分层显示；Composer 输入框下方始终显示与输入框同宽的 Runtime HUD，HUD 下方显示 SubAgent 任务面板；面板中的每条任务对应一个独立持久 Pi Session，点击后打开只读实时会话查看器，不打断主 Agent；没有选中文件时使用较大的输入态，打开右侧文件检查器后两者一起收缩；主动停止显示“已停止”，不显示为回答失败；
- 右侧：仅在点击文件后创建文件检查器，显示 Markdown、文本、图片或二进制文件提示；Markdown 支持块编辑、行内格式、表格/列表、撤销重做、冲突差异、查找替换、跨块复制、图片拖入和标题大纲；Inspector 可从标题菜单挂到独立 macOS `NSWindow`，主窗口与浮动窗口复用同一 Session/编辑器状态，关闭浮动窗口会挂回主栏；明确区分加载中、读取成功和读取失败，失败时可重新读取；
- Extension UI：Pi 扩展的 `select`、`confirm`、`input`、`editor` 请求显示为原生 macOS 对话框；`notify`、`setStatus` 和字符串 `setWidget` 显示在 Composer 上方；TUI 专属 `custom()` 安全取消并保留可见错误。
- 项目授权：检测项目本地 `.pi` 资源和项目级 `.agents/skills` 后，先显示原生授权面板；“仅本次允许”或“始终允许”才会以 `--approve` 启动 Runtime，拒绝时不加载项目扩展，也不修改 Pi 的全局 `trust.json`。
- 命令选择器：Composer 输入第一个 `/` 即显示 slash command picker（斜杠命令选择器），支持实时过滤、上下键、Return、Tab 和 Escape；PuraPi 内置命令提供中文/English 说明，Pi RPC `get_commands` 返回的 Extension、Prompt Template 和 Skill 命令会合并显示。
- 空工作区入口：“新建项目文件夹”和“打开项目文件夹”是完整的原生玻璃卡片按钮，整框可点击并提供 hover（悬停）与 pressed（按下）反馈；macOS 26 使用 `glassEffect` + `GlassEffectContainer`，旧系统使用语义材质降级。
- 主题：内置主题与用户 `.purapitheme` 包共用声明式 `PuraPiThemeDefinition`；`PuraPiThemeStore` 会校验 schema、路径、资源大小、权限和可选 SHA-256 校验和，主题包不能执行代码或访问 Runtime/工作区；
- 账号与认证：设置窗口的“账号”页通过受控 Node sidecar 调用 Pi 官方 `ModelRuntime`/`AuthStorage`，支持 OpenAI Codex、Anthropic 订阅 OAuth 和 API Key，展示认证状态与可用模型；status 使用官方只读存储，命令型 `models.json` 配置被拒绝，API Key 使用安全输入框，凭据不进入 PuraPi Session、项目文件或日志。

上下文 HUD 在 `message_end` 收到 Pi 的有效 usage 后立即更新；`agent_settled` 后的统计请求只用于最终校正。Runtime 断开时，Composer 上方会显示可关闭的错误/提示，并提供显式“重新连接”入口；重连使用最近持久化会话，不静默丢弃本地队列或附件。

### SubAgent 工作流

全局 `pi` 扩展位于 `~/.pi/agent/extensions/subagent/`，角色定义位于 `~/.pi/agent/agents/`。主 Agent 通过自然语言自主决定是否调用 `subagent`；每个委派任务创建独立持久 Session，首选 `openai-codex/gpt-5.6-terra`，失败时在同一 Session 中回退到 `openai-codex/gpt-5.6-sol`。PuraPi 在 Runtime HUD 下方显示任务状态，点击任务打开只读实时子会话查看器；关闭查看器不会切换主 Runtime。

macOS 26 使用系统 `NSToolbar` 窗口 chrome；原生全高 Sidebar 自动决定 Toolbar 的前导内容边界，单个系统 `.space` 只提供固定呼吸间距，不能再按 Sidebar 宽度累加占位。项目标签完全使用自定义 `NSToolbarItem` 的系统胶囊，避免再叠加第二层 SwiftUI 玻璃。当前标签使用局部紫色选中态，便于区分多个项目。Sidebar 使用原生全高 `NSSplitViewItem` 外层表面，文件树在同一内容边界内使用对齐的局部紫色表面并保留内容安全区；项目根目录是文件树真实 `ScrollView` 的第一行，和子目录、文件一起滚动，不存在固定标题遮挡；右边缘支持原生拖拽调整宽度，并使用水平调整光标。Sidebar 的局部强调色取自产品参考图的紫色 `#AB83E4`，不改变全局系统 accent。其余局部区域使用编译期可用的 SwiftUI `glassEffect`、`GlassEffectContainer` 和系统玻璃按钮。macOS 26 的中心工作区由原生 `NSSplitViewController` 管理，不安装可见的顶部状态条；真实 `NSScrollView` 使用 edge-to-edge 内容和系统 scroll-edge effect（滚动边缘效果），让滚动中的文本在 Toolbar 下方连续采样、渐隐和失焦。macOS 14–25 保留 SwiftUI `HSplitView` 与语义化 `NSVisualEffectView` fallback。窗口标题栏透明但窗口底色仍由 AppKit 管理，中央工作区不绘制整块玻璃卡片。Inspector 独立窗口是展示层，不复制文档或 Runtime；Markdown 的 `pendingCollaborationSnapshot` 会跨过自动保存边界保留，用户可审阅并确认 schema v1 Markdown diff 后附加到下一条 Prompt；HTML/图片标注仍未接入。

## 发布状态与前置能力

当前版本是开发基线，不是发布候选版本。正式发布前必须完成：

1. 优先发现并使用用户电脑已有的 Pi Runtime；找不到时提供安全、可恢复的 Pi/Node 安装流程；
2. 账号页已通过受控 Pi 官方 SDK sidecar 接入 OpenAI/Codex、Anthropic OAuth 和 API Key 登录/退出；正式发布前必须完成真实账号、过期刷新和失败恢复验收；
3. 账号页已读取已认证 Provider 的可用模型，并由项目 Pi Runtime 调用；凭据只能进入 Pi 官方安全存储，不得写入 Session JSONL、普通日志或项目目录。

详见 `docs/PRODUCT.md`、[`docs/AUTH.md`](docs/AUTH.md) 和 `docs/agent/FEATURE_BACKLOG.md`。

## 本地验证

必须在本目录执行：

```bash
cd /Users/limiao/work/PC/NewPiAgentUI/PuraPi
swift build
swift run PuraPi
```

需要看到完整的 `PuraPi` 菜单栏名称和 App Icon，可生成未签名的开发预览 App：

```bash
./scripts/package-pura-pi-app.sh
open "dist/PuraPi.app"
```

`swift run PuraPi` 会启动一个明确创建的 macOS `NSWindow`。打开窗口后，点击标签栏的 `+` 选择项目文件夹。应用会在该目录中启动：

```bash
pi --mode rpc
```

如果找不到 `pi`，空工作区和设置页会显示 Runtime 供应入口；用户确认后，PuraPi 会优先使用兼容的 Node.js/npm，并在 `~/Library/Application Support/PuraPi/Runtime` 的 staging 目录安装固定版本。没有兼容 Node.js 时，会从 Node.js 官方 HTTPS 地址下载并校验 SHA-256 后安装私有副本。设置页也支持手动选择不在常见 PATH 中的 `pi`。流程不调用 Shell/sudo、不修改 PATH、不覆盖用户已有 Pi。全局 `pi` 需要加载 `~/.pi/agent/extensions/subagent/` 中的 SubAgent 扩展。扩展会让主 Agent 自主选择是否委派，并为每个任务创建独立 Session；首选 `openai-codex/gpt-5.6-terra`，失败时回退到 `openai-codex/gpt-5.6-sol`。设置窗口的“账号”页已通过 Pi 官方 SDK sidecar 接入登录、退出、API Key、认证检查和可用模型目录；发布版本仍必须完成真实 OAuth/API Key 登录、令牌刷新、模型调用、正式签名/打包、升级/卸载/恢复验收。应用菜单中的“设置…”提供“跟随系统”“浅色模式”“深色模式”，选择会持久化到 PuraPi 本地偏好；颜色方案只通过窗口级 `NSWindow.appearance` 传播，避免 SwiftUI 与 AppKit 重复触发外观重建。

选择文件后，Inspector 顶部的独立窗口按钮、标题栏“更多”菜单或“文件 → 独立/挂回检查器”可将右侧面板挂到独立窗口；点击按钮会先显示边缘抬升反馈，浮动窗口首次从原 Inspector 的位置和尺寸出现，之后保留用户调整后的位置/尺寸，可移动到另一块显示器；关闭窗口只会挂回主栏，不会关闭文件。Markdown 已保存但尚未同步给 Agent 时，关闭文件会要求审阅或显式放弃同步。

默认测试不调用模型：

```bash
swift test
```

显式运行真实 Pi `0.84.4` 工具闭环（会产生一次模型调用，只操作临时目录并使用 `--no-session`）：

```bash
PURAPI_REAL_RPC_TEST=1 swift test --filter PuraPiRealRPCTests/testRealPiRPC01ToolAndFileLoop
```

运行真实 Pi `0.84.4` Extension UI 协议闭环（使用临时扩展和 `PI_OFFLINE=1`，不调用模型）：

```bash
PURAPI_REAL_RPC_TEST=1 swift test --filter PuraPiExtensionUITests/testRealPiRPC02ExtensionUIProtocol
```

运行真实 Runtime 供应安装测试（访问 npm/Node.js 官方站点，只写临时目录，不调用模型）：

```bash
PURAPI_RUNTIME_INSTALL_TEST=1 swift test --filter PuraPiRuntimeProvisioningIntegrationTests/testOptInManagedRuntimeInstallIsAtomicAndRunnable
```

若还要覆盖“没有可用 Node.js”分支，再加 `PURAPI_RUNTIME_PRIVATE_NODE_TEST=1`；该分支会下载并校验官方 Node.js 归档。默认 `swift test` 不联网、不安装 Runtime。真实认证 sidecar 测试使用临时认证文件：

```bash
PURAPI_AUTH_BRIDGE_TEST=1 swift test --filter PuraPiAuthTests/testDefaultBridgeCanReadAndStoreAPIKeyInOptInIntegration
```

该测试不会触碰用户的 `~/.pi/agent/auth.json`；真实 OAuth 登录必须由用户在账号页主动发起。

## 模块

- `PiDomain`：与 UI 无关的领域模型；
- `PiRPC`：Pi Runtime 的 JSONL 进程协议；
- `WorkspaceKit`：目录树、文件预览和变更监视；
- `PuraPi`：SwiftUI/AppKit 客户端；其中 `PuraPiThemeStore` 管理安全的声明式用户主题包。

详细边界见 [`docs/PRODUCT.md`](docs/PRODUCT.md)、[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 和 [`docs/INVARIANTS.md`](docs/INVARIANTS.md)。

# SOLIDWORKS 中文输入状态下的空格快捷键

调查日期：2026-09-25。适用范围：MacSW 所打包的 Wine 11.16 与已验证的
SOLIDWORKS Premium 2025 SP5.0。修复由
[`0006-winemac-preserve-solidworks-view-space.patch`](../patches/wine-crossover/0006-winemac-preserve-solidworks-view-space.patch)
提供；这是 SOLIDWORKS 图形视图的定向兼容补丁，**不是** Wine 的通用输入法修复。

## 现象与复现

在已有模型的图形视图中，原生 Windows 上按下空格会打开“方向”浮动面板。
修补前，macOS 中文拼音输入状态下按空格无可见反应；切到英文输入源后恢复。
方向键等其他模型快捷键仍可响应。在同一个 Wine 会话中，点击视图工具栏上的
“方向”按钮可以打开面板，因此面板创建和绘制并非本故障的主要阻塞点。

复查时应先点击模型画布空白处，使图形视图获得焦点，再分别试中文空闲状态、
正在输入拼音、英文输入源及 SOLIDWORKS 文字输入框；不要把未获得焦点造成的
无响应误判为输入法问题。

## 按键链路与证据

Wine 11.16 在 `winemac.drv` 的 `macdrv_ImeToAsciiEx` 中，先把按键交给 macOS
`NSTextInputContext`。输入法消费事件时，`win32u` 的消息处理会将相应的
`WM_KEYDOWN` 虚拟键改为 `VK_PROCESSKEY`。SOLIDWORKS 的“方向”快捷键需要
按下阶段的原始 `VK_SPACE`，不能仅靠后续空格字符触发。

修补前对 SOLIDWORKS GUI 线程安装临时 `WH_GETMESSAGE` 探针，记录到：

- 焦点为 MFC 图形子窗口，类名包含 `:2b:`，父链中有 `swMdiClient`；
- 中文空闲状态按空格时，`WM_KEYDOWN` 的键值为 `0xE5`（`VK_PROCESSKEY`），
  随后有 `WM_IME_STARTCOMPOSITION`、`WM_IME_COMPOSITION`、
  `WM_IME_ENDCOMPOSITION` 以及空格字符消息，而不是原始 `VK_SPACE` 按下；
- 此时组合字符串长度为零；输入拼音后，组合字符串长度可变为非零。

这说明“没有组合文字”并不等于“输入法没有消费空格”。同样处于无组合文字
状态的文字输入框仍可能需要由输入法处理空格，因此不能在所有 Wine 窗口中
一律绕过输入法。探针源文件和原始日志是本机一次性产物，未收入仓库；上面
列出的是用于以后重建探针的消息与状态判据，不应把原始日志视为仓库附件。

## 本地修复边界

`0006` 只在以下条件同时成立时，让空格走 Wine 的普通 Windows 按键路径：

1. 当前为无 Shift、Ctrl、Alt、Win 修饰的 `VK_SPACE` 按下；
2. 焦点窗口类名含 `:2b:`，且祖先窗口类名为 `swMdiClient`；
3. 对应 Cocoa 内容视图没有正在输入的组合文字。

其他窗口、修饰键组合，以及已有组合文字的按键仍交给原有输入法路径。
判断失败时保留旧行为，避免影响未知窗口。补丁内容进入 `build_winemac.sh`
的构建缓存键；打包清单记录 `WineMacSpacePatchSHA256`，`verify_app.sh`
核对补丁和打包模块。

## 验证与剩余风险

2026-09-25 在当前主容器上执行 `make winemac`、`make app` 和 `make test`：
Wine 模块编译、App 签名及包清单校验通过；133 项 Swift 测试和 137 项
Python 测试通过。覆盖重启主工作区的 MacSW 后，用户实际确认：

- 中文输入状态下，模型视图按空格可打开“方向”面板；
- SOLIDWORKS 文字输入框中，空格仍用于中文候选词上屏，没有额外输入空格。

这两项是当前 MacSW/SOLIDWORKS 环境的运行时回归，不代表所有 macOS 输入法、
Wine 应用或 SOLIDWORKS 版本均已验证。图形视图识别依赖观察到的 MFC 类名
片段和 `swMdiClient` 父链；新版 SOLIDWORKS 若改变窗口层级，补丁可能不再
命中，此时应重新抓取焦点与按键消息，而不是放宽为全局空格透传。其他应用
若遇到类似问题，也应先区分图形快捷键与文字输入语义，再考虑通用 Wine 修复。

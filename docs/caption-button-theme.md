# SOLIDWORKS 文档窗口标题按钮风格不一致

## 现象与结论

创建 Part 并把文档子窗口从最大化切换为普通窗口后，标题栏会出现五个按钮。左侧两个按钮
带蓝色 Aero 皮肤，右侧最小化、最大化和关闭按钮则是白色经典风格。它们属于同一个文档
窗口，混合风格明显，但不影响按钮命令本身。

最终处理不修改 Wine 绘制代码。App 在新 bottle 的安装环境准备阶段写入：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager
ThemeActive = "0"
```

关闭 Wine ThemeManager 的活动主题后，五个按钮都使用同一套平面经典风格。该设置与
`WINE_NOCAPTURERESEND` 合并为一次注册表导入，只在安装时执行；项目目前没有 bottle schema
迁移框架，因此不为旧容器增加每次启动补写逻辑。

## 根因定位

历史补丁 `0001-defwnd-aero-caption-buttons.patch` 修改了 `user32!DrawFrameControl`，但实测切换
补丁版与原版 `user32.dll` 不会改变 SOLIDWORKS 中这五个按钮。进一步检查发现 SOLIDWORKS
加载的 `ToolkitProVC141x64U.dll`（Codejock/XTP）hook 了 `DrawFrameControl`：它会先尝试内部
皮肤绘制，只有失败时才回落到 user32。因此仅修改 Wine 的 DefWindowProc 绘制层无法统一
两组按钮。

在同一 bottle、同一 Part 和同一窗口状态下进行 A/B：`ThemeActive=1` 时复现混合风格；
`ThemeActive=0` 时五个按钮统一。随后分别加载补丁版和原版 user32 做像素比较，结果 AE 与
RMSE 都为 0，证明这一历史补丁对实际界面没有作用。该补丁已从仓库删除，也未进入正式
补丁链；现行补丁清单以 [`scripts/build_winemac.sh`](../scripts/build_winemac.sh) 为准。

## 兼容边界

这是 bottle 级 Wine 主题选择，会让 Wine 内由主题管理器接管的控件回落到经典外观；目标是
一致性，而不是复刻 Windows Aero。新安装由 App 自动配置，已有测试 bottle 只需手工写入一次。

## 文档标题文字低对比度：调查状态（2026-10-10）

实验性的 Wine 深色配色开关已从源码撤回；控件探针仍保留。实验只影响部分标准菜单，
不能使 SOLIDWORKS 的自绘界面获得一致深色外观。需要区分 Wine 系统配色与 SW 自己的
背景亮度：用户后续截图确认，SW 内部切到浅色后，文档子窗口标题文字变黑并恢复可读；
此前仅切换 Wine 系统配色未解决标题低对比度。不能将记事本或标准 MDI 探针的效果作为
SW 标题问题已修复的证据。

本次只读检查了安装目录中的 `SWGrey.cjstyles` 和 `ToolkitProVC141x64U.dll`：

- 皮肤是 PE 资源库，含 `NORMALSWGREY_INI`、`LARGEFONTSSWGREY_INI` 和
  `EXTRALARGESWGREY_INI` 三套配置；三套 `[SysMetrics]` 均定义了独立的
  `CaptionText = 10 20 60` 与 `InactiveCaptionText = 135 150 170`。
- `[Window.Caption]` 与 `[Window.SmallCaption]` 引用皮肤内部标题背景位图，
  不是单纯依赖 Wine 的 `ActiveTitle` / `InactiveTitle` 颜色。
- ToolkitPro 导出 `CXTPSkinManagerApiHook::OnHookGetSysColor`、
  `OnHookGetThemeSysColor` 及 `CXTPSkinObjectFrame::DrawFrame`。

Codejock 的[官方 SkinBuilder 说明](https://codejock.com/support/help/view-article.asp?id=100)
确认：SkinFramework 可从皮肤读取已定义的系统颜色，而不是直接使用 Windows 的值。
因此该皮肤路径是标题取色的调查重点，但静态资源与导出表还不能证明当前 SW 文档标题
正在采用其中哪一个值。也尚未证明激活状态判断、取色缓存或 SW 自绘代码是否参与问题。

不继续扩展全局深色方案，不改字体或模型背景。目前没有部署标题修复，也没有改写运行中
的容器、广播颜色变更或重启 Wine/SOLIDWORKS。后续若增加手动兼容选项，需先证明它对
SW 自己的深色外观有效，而不能直接恢复此前的全局色板实验。

## 状态栏背景：自绘与控件重绘的调查（2026-10-10）

用户对照截图显示：Windows 上 SW 内部切到浅色后，状态栏背景和文字都变浅色/黑色；
Wine 上文字变黑，但背景仍是蓝灰色。Windows 上深色状态栏还会随主窗口失焦改变背景。
这些截图证明差异存在，但不足以直接归因于 Wine 的系统颜色或 `SWGrey.cjstyles`。

对本机 SW 2025 SP5.0 的 DLL 做离线检查，定位到更直接的绘制路径：

- `sldappu.dll` 的 `uiStatusBar_c` MFC 消息表将 `WM_ERASEBKGND` 映射到 RVA
  `0x56e5a0`，即 SW 有自己的状态栏背景处理函数。
- 该函数检查 `CDPIHelper_c` 的 `getUseSW2016Icons` 所使用的字段。现代绘制分支调用
  `WinUtils::IsMainWindowActive`，再通过 RVA `0x5825c0` 创建并缓存活动/失焦背景位图。
  背景颜色来自 `SLDMFCU.dll!swCM_getColor` 的编号 `0x33` / `0x34`，不是直接读取
  Wine 的 `ActiveTitle` / `InactiveTitle`。
- 另一分支根据 `xpThemeUI_c` 状态选择 `BMP_STATUS_MID` 资源或直接填充
  `COLORREF 0x00bfb5ab`（RGB 171、181、191）。该固定蓝灰色接近截图颜色，说明 SW
  自身也有这种背景的来源；静态分析尚不能证明运行中的 SW 实际选中了这一分支。
- Wine 11.16 的 `dlls/comctl32/status.c` 在 `STATUSBAR_Refresh` 中再次调用
  `STATUSBAR_DrawBackground`。经典路径会使用显式 `SB_SETBKCOLOR` 或
  `GetSysColorBrush(COLOR_3DFACE)` 填充整个客户区；主题路径则调用 `DrawThemeBackground`。
  此路径可能覆盖应用在 `WM_ERASEBKGND` 中已经画好的背景。

在单独的新 prefix 中运行隐藏、全透明、不激活窗口的最小 Win32 探针，模拟 SW 在
`WM_ERASEBKGND` 中填充深灰色并返回 `TRUE`。取同一个客户区像素：

| 操作 | 默认状态栏背景 | 显式设置状态栏背景 |
| --- | --- | --- |
| 应用处理 `WM_ERASEBKGND` 后 | RGB 37、37、37 | RGB 37、37、37 |
| 控件处理 `WM_PRINTCLIENT` 后 | RGB 245、245、245 | RGB 11、22、33 |
| 完整 `WM_PRINT`（含擦除背景）后 | RGB 245、245、245 | RGB 11、22、33 |

两次探针均正常退出，确认 Wine 的经典状态栏打印路径可以覆盖应用的背景处理结果。
本轮随后完成了原生 Windows 对照（见下节），不应仅凭此行为判断 Wine 存在缺陷。
尚未跟踪真实 SW 的运行时分支，因此不能确定补丁。Codejock 的
[API hook 官方说明](https://codejock.com/support/help/view-article.asp?id=48)也提示，绘制接口
拦截不完整会导致部分皮肤失效，但不能据此直接认定本次属于该原因。

探针源码、可执行文件和独立 prefix 留在本机临时目录
`/private/tmp/macsw-statusbar.W2iXhs/`，未打包进产品；主 bottle 未写入、未重启。

### 真实 WM_PAINT 与原生 Windows 对照

同一份 x64 探针在 Windows 11 ARM 的交互会话（Session 1）和隔离 Wine prefix 中运行，
分别使用无 v6 manifest 的公共控件与带 v6 manifest 的公共控件。窗口保持全透明、
不激活；通过 `RedrawWindow(RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW)` 触发真实
`WM_PAINT`，不是向 `WM_PAINT` 注入离屏 HDC。子类在默认绘制返回后用窗口 DC 读取像素。
四组对照均记录到一次 `WM_PAINT`，其间嵌套一次应用 `WM_ERASEBKGND`，像素有效。

确保控件自身主题关闭后，结果如下（v5/v6 两组结果相同）：

| 配置 | Wine 绘制后的背景 | 原生 Windows 绘制后的背景 |
| --- | --- | --- |
| 默认背景 | RGB 245、245、245（当地系统色） | RGB 240、240、240（当地系统色） |
| `SB_SETBKCOLOR = RGB(11,22,33)` | RGB 11、22、33 | RGB 11、22、33 |

两边都覆盖了应用此前在 `WM_ERASEBKGND` 中画出的 RGB 37、37、37，
`WM_PRINTCLIENT` / `WM_PRINT` 结果也一致。因此排除“经典状态栏重新填充背景这个行为本身
就是 Wine 与 Windows 差异”的假设；不能据此删除 Wine 的背景绘制或宣称 SW 已修复。

对照中另发现一项独立的 API 差异：`SetWindowTheme(hwnd, L"", L"")` 在原生 Windows
返回 `S_OK` 并关闭控件主题，在本机打包的 Wine 返回 `0x8007007b`，v6 控件的主题仍存在。
此时即使调用 `SB_SETBKCOLOR`，探针背景仍由主题绘制。改用
`SetWindowTheme(hwnd, NULL, L"MacSWProbeNoSuchThemeClass")` 后，Wine 返回 `S_OK`，
主题句柄清空，显式背景色正常生效。此方法仅改探针窗口属性，不写系统设置或注册表。
[Microsoft 的 API 文档](https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-setwindowtheme)
明确允许用空字符串阻止指定窗口应用视觉样式。Wine 11.16 的
`UXTHEME_SetWindowProperty` 则直接对非 NULL 字符串调用 `AddAtomW`，可解释上述失败。

这是一项已复现的 API 兼容差异，但不是已证实的 SW 状态栏根因：MacSW 安装流程本来就会
写入 `ThemeActive=0`；还需确认 SW 实际状态栏的公共控件版本、有效主题、取色分支以及
Codejock 绘制拦截。继续调查这些路径，不恢复全局深色色板，也不修改正在运行的 SW。

离线反汇编还确认 `SLDMFCU.dll` 在 RVA `0x1b319a` 调用 `SetWindowTheme`，两个字符串参数
均指向 RVA `0x3f0778` 的空 UTF-16 字符串。调用受全局状态分支控制，窗口句柄取自对象
字段 `+0x40`；尚未证明此调用会用于实际状态栏。因此该差异与 SW 有静态调用关联，
但仍不能把关联当成根因或补丁有效性的证据。

最终探针源码、两种 EXE、manifest 资源对象、运行脚本和对照日志仍在
`/private/tmp/macsw-statusbar.W2iXhs/`；Windows 上仅新增诊断目录
`C:\Workspace\macsw-statusbar-W2iXhs`（两个 EXE）。主 MacSW/SW 的 PID 和启动时间未变，
该实验阶段未改产品代码、未重新打包。

## 换主题与五个按钮：隔离实验（2026-10-10）

在主 bottle 的 APFS 写时复制副本中比较主题，实验目录为
`/private/tmp/macsw-theme-ab.XbV44C/`。这不是全新安装；保留了安装内容及设置。
实验只操作该副本，未将主题部署到主 bottle；以下结果不涉及字体方框问题。

| 配置 | 验证方式 | 实际效果 |
| --- | --- | --- |
| 关闭活动主题 | 隔离 SW 启动并创建空 Part | 五个按钮均为平面经典风格 |
| 内置 Aero | 已启动 SW 中切换主题 | 有截图，但不能排除启动时缓存；不作为完整启动对照 |
| Royale，NormalColor / NormalSize | 主题加载成功后重新启动隔离 SW，创建空 Part | 标题背景为浅蓝色；左二按钮有皮肤，右三仍为经典按钮 |
| Lunainspaqua，NormalColor / NormalSize | 主题加载成功后重新启动隔离 SW，创建空 Part | 标题背景改为深浅蓝色渐变，文字为白色；左二有皮肤、右三仍为经典按钮 |
| Aero11 Seven Clear 候选文件 | 尝试读取主题 | 返回 `0x8007000b`，未加载成功；不能作为有效外观对照 |

Lunainspaqua 来自固定版本的
[Wine 主题集合](https://github.com/listumps/wine_themes/blob/02f1c3f768676db5f5e28bee1ce39e9c4b3613dd/lunainspaqua/lunainspaqua.msstyles)，
文件 SHA-256 为
`ef002a3ab9997655efcfc7b045ff1cdd20ddb1c97947002e8c6ca3a15ca689ed`。
加载返回 `S_OK`，`IsThemeActive` 为真。它虽然被列为 Aqua 风格候选，实际 SW 效果仍偏旧式
Windows 蓝色皮肤，不能描述为原生 macOS 控件或已经实现了 macOS 风格。

这些实验说明：换主题能改变实际文档子窗口的标题背景和部分控件，但这两个已成功加载的
主题都没有统一五个标题按钮。不能由此推断所有主题均无效，也不能推断标题栏完全不吃
主题。原生 Windows 11 的用户截图中五个按钮能呈现一致的蓝色皮肤及红色关闭按钮；
这不等于将 Windows 11 的系统主题导入 Wine 就能复现该效果。

前文的历史 A/B 排除了当时那份 `user32!DrawFrameControl` 补丁的效果；Codejock 导出和
离线反汇编提示存在皮肤拦截路径，但目前还未记录真实 SW 绘制这些按钮时的完整调用链。
后续重点是区分标题背景、左二按钮与右三按钮各自的绘制入口，以及右三回退到经典绘制的
条件，而不是继续盲换主题或直接修改 Wine 绘制层。

源码、主题文件、加载日志、结果 JSON 和实际窗口截图留在上述临时目录，未打包进产品。
临时路径仅便于本机复核，不作为长期可获取的仓库附件。

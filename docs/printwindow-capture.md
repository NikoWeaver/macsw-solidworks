# 底部假滚动条与窗口捕获

`0011-win32u-printwindow-surface.patch` 为 SOLIDWORKS 单独启用窗口表面捕获，
修复模型／运动算例标签行右端出现上下箭头的问题。它与 0010 的 TreeView
间距修复是两个独立补丁，不修改 SOLIDWORKS DLL，也不强制隐藏滚动条。

## 根因证据

2026-10-10 在独立 bottle 中，对照 Wine 与正在运行的原生 Windows：

- 滚动条属于 `slduiu.dll` 的 `uiModelSheets`，继承链包含 `uiBaseView_c` 和
  MFC `CScrollView`；不是左侧特征树，也不是整个文档的垂直滚动条。
- Wine 新建文档时，该窗口高 24px，style 为 `0x50000000`，没有垂直滚动条。
  软件捕获窗口后，style 变成 `0x50200000`，滚动范围是 0–99、page=24。
  原生 Windows 对应窗格保持 `0x50000000`。
- 反汇编与消息／API 跟踪互相印证：`sldappu.dll` 的捕获函数调用
  `PrintWindow(..., 0)`；Wine 递归发送 `WM_PRINT`／`WM_PRINTCLIENT`，
  MFC `OnPrintClient` 进入 SW 的 `uiBaseView_c::OnPrepareDC`。
  该函数在 map mode 未初始化时调用 `SetScrollSizes(MM_TEXT, {100,100})`；
  MFC `UpdateBars` 随后调用 `ShowScrollBar(SB_VERT, TRUE)` 和 `SetScrollInfo`。
- 在原生 Windows 上，同一诊断窗口的 `PrintWindow` 能捕获已绘制内容，
  而不进入应用的打印消息处理函数。直接发送 `WM_PRINT` 时，两端都会进入。

因此箭头并不是“高度不足，需要滚动”的正常布局结果，而是窗口捕获触发了
应用打印 DC 初始化的副作用。修复前发送滚动消息和强制重绘，截图像素没有变化；
这证实了本例是假滚动范围，不能据此宣称所有曾观察到的滚动后空白都已修复。

## 修复边界

新增 AppCompat 标志 `WINE_PRINTWINDOW_SURFACE`。启用时，
`NtUserPrintWindow` 获取目标窗口的 DC，将其已绘制内容 `BitBlt` 到调用方 DC，
不重新进入应用打印处理函数。`PW_CLIENTONLY` 使用客户区，其余使用窗口区域。
获取源 DC 失败或复制失败时返回失败，并释放已取得的 DC。

只给 `sldworks.exe` 设置该标志。其他进程仍保留 Wine 原有消息式捕获路径；
显式发送 `WM_PRINT`／`WM_PRINTCLIENT` 的行为也不变。默认路径仍符合
[Microsoft 对 PrintWindow 的传统说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow)。
不能把当前 Windows 的探针结果概括成所有 Windows 版本都不发送打印消息。

这里复制的是现有表面，不实现强制重绘的 `PW_RENDERFULLCONTENT` 完整语义，
也不承诺未绘制内容、最小化窗口、复杂分层窗口或 OpenGL 全场景捕获。
诊断中的隐藏窗口结果为黑色，原生对照也是如此。
NULL 目标 DC 在原生 Windows 上可能返回成功；这是无效捕获请求，本补丁不模拟
这一返回值。此次不改变软件配色、DPI、字体、滚动范围或其他布局。

## 验证与构建

`make printwindow-probe` 构建可选 `build/native/wine_printwindow_probe.exe`，
不打进 App。探针只创建、销毁自己的窗口，不附加到 SOLIDWORKS。
在原生 Windows，以及给该探针进程设置标志的修补版 Wine 中运行：

```text
wine_printwindow_probe.exe
wine_printwindow_probe.exe --unaware
```

每种 DPI 模式检查 110 个断言：flags=0/1/2，已显示、移出屏幕、被另一个窗口
遮挡和隐藏；父子窗口颜色、没有打印消息重入、没有假滚动条、无效 HWND 以及
显式打印消息仍有效。新窗口先完成绘制／合成，再检查缓存捕获，避免把尚未提交的
帧误判为空白。2026-10-10 两端均为 0 失败，逐行像素／消息结果一致。

移除探针的标志后，用 `--legacy` 检查默认 Wine 行为，74 个断言为 0 失败；
它仍发送打印消息并复现假滚动条副作用。此模式是默认行为保护测试，不是原生对照。
真实 SOLIDWORKS 测试新建文档后，将主窗口高度改为 560、780、900；底部窗格
均保持 `0x50000000`，截图没有上下箭头，模型标签仍然可见。

构建按序应用 0011，缓存键包含补丁 SHA，仍编译既有 `win32u.so`。
打包记录 `WinePrintWindowPatchSHA256`，验证补丁 SHA 及模块
`WineInputModuleSHA256`。离线单元测试检查这些接线，不能替代上述运行时证据。

## 已有容器与回退

新安装的兼容配置为 `WINE_NOCAPTURERESEND WINE_PRINTWINDOW_SURFACE`。
已有容器不会在每天启动时重新套用安装期配置；升级 App 后，需关闭 SW 并一次性
给以下 REG_SZ 的现有值追加 `WINE_PRINTWINDOW_SURFACE`，保留原有标志：

```text
HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers
值名：sldworks.exe
```

先备份注册表值，再写入；进程启动时才读取，修改后必须重启 SW。
不要为此重新安装或清空容器，也不要重新套用全部主题／字体设置。
回退时关闭 SW，仅移除新增标志，再启动即可恢复原有捕获行为；旧 App 也可从
升级前的完整备份恢复。该标志没有改写模型文件或 SOLIDWORKS 官方程序。

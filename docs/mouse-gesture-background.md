# 鼠标手势轮盘背景

## 原因

SOLIDWORKS 2025 SP5.0 的 `swGestureTarget` 并不是分层透明窗口。实测扩展样式为
`0x88`（topmost/toolwindow），没有 `WS_EX_LAYERED`，也没有显式窗口区域。

对 `slduiu.dll` 的调用路径分析表明，创建轮盘时会先通过 `GetDC(NULL)` 获取屏幕 DC，
再用 `CreateCompatibleBitmap` 和 `BitBlt(..., SRCCOPY)` 保存窗口所在矩形的背景。
绘制时先复制这张背景，再绘制圆环和图标。因此视觉上的“透明”实际是背景快照，
不是黑色色键或 DWM alpha 合成。

未修复的 Mac 驱动没有 `pGetImage` 屏幕读取实现。独立采样得到：

- `BitBlt` 返回 0，预填充的目标像素未改变；
- `GetPixel` 返回 `CLR_INVALID`；
- SW 继续绘制轮盘，未成功填充的背景位图呈黑色。

## 修复

[`0013-winemac-screen-readback.patch`](../patches/wine-crossover/0013-winemac-screen-readback.patch)
补充桌面 DC 的 `pGetImage`，从 macOS 的合成画面读取实际可见背景。

- 仅处理 `GetDC(NULL)` 关联的桌面 DC；其他 DC 仍向下一层驱动委派，DIB/普通窗口路径不变。
- 原生取图在 Cocoa 主线程和 autorelease pool 内执行。直接从 Windows 线程调用的早期原型
  虽已修复 SW 轮盘，但反复 `GetPixel` 的小程序曾停滞，因此不采用该版本。
- 使用现有 Retina 坐标转换，输出 sRGB、32 位 BGR 的 top-down DIB。
- 对 Retina 单像素对应的半点边界，先取整宿主矩形再按 backing pixels 裁剪，
  避免原生接口处理不足一个点的矩形时返回空图像。
- 对可见源矩形进行取图，并将源坐标调整到返回图像内部，覆盖非零位置及子区域复制。
- 动态解析原生接口，沿用已有 Dock 快照的方式。接口不可用或取图返回 NULL 时报告失败，
  不伪造背景；不自动请求或绕过 macOS 屏幕录制权限。

此实现依赖宿主仍提供 `CGWindowListCreateImage`。本轮宿主 macOS 15.8 可用；
该接口在新 SDK 中已标记 obsolete，不能把本轮结果扩展为未来 macOS 的保证。
若宿主移除此接口，需单独接入 ScreenCaptureKit，不以强制黑色透明替代屏幕读取。

## 验证

隔离克隆容器中的 SOLIDWORKS 已由用户实际触发轮盘并确认正常。圆环外侧、中心，
以及跨出 SW 窗口的背景均恢复，不修改 SOLIDWORKS DLL。

可重复的原生回归程序：

```sh
make screen-readback-probe
# 在指定的临时 WINEPREFIX/运行时内执行：
wine build/native/wine_screen_readback_probe.exe
wine build/native/wine_screen_readback_probe.exe --unaware
```

程序检查普通窗口复制、屏幕复制、`GetPixel` 和非零目标位置的子区域复制，共 16 项。
屏幕像素容许每通道 3 级以内的合成色彩管理舍入；普通窗口像素要求完全一致。
探针不随 App 打包，不由启动器自动运行。

2026-10-10 最终原型回归：Retina 开/关 × 96/120 DPI × aware/unaware 的 8 种组合，
共 128 项检查无失败。Windows 交互桌面 120 DPI 上同一探针的 aware/unaware 两种模式
共 32 项检查无失败。测试对 DPI-unaware 的窗口坐标先显式转换成物理屏幕坐标，
不把窗口坐标虚拟化误当作屏幕读取行为。Parallels `exec` 默认的 Session 0 没有可用
交互桌面，不能用其屏幕读取失败当作 Windows 参考；有效参考在已登录用户的桌面执行。

构建缓存包含补丁 SHA，打包记录 `WineScreenReadbackPatchSHA256`，验证同时核对补丁
及 `WineMacModuleSHA256`。真实运行时验证不由离线脚本断言替代。

正式 App 已于 2026-10-10 构建、验证并替换主运行时，旧 App 完整保留为
`build/app/MacSW.before-screen-readback-20261010.app`。主 SOLIDWORKS 已退出并重启，
主容器的屏幕读取探针返回成功且取得实际背景像素；部署模块与最终矩阵测试模块的
SHA-256 一致。离线测试共运行 134 项，无失败，跳过 1 项。

用户随后提供的轮盘截图也已没有中心及外围黑底。不过独立截图采样时的
`swGestureTarget` 属于仍在运行的隔离实例 PID 80420，而非重启后的主实例
PID 77415；因此不能仅凭该次采样声称主实例轮盘的 PID 级视觉复核已完成。

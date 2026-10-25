# Wine macOS OpenGL 子窗口首次呈现时的裁剪失效

调查日期：2026-09-25。对象：Wine 11.16 的 `winemac.drv` 和 MacSW
[`0002-winemac-metal-layer-clipping.patch`](../patches/wine-crossover/0002-winemac-metal-layer-clipping.patch)。
这与[前缓冲误交换](opengl-front-buffer.md)是不同问题：此处 3D 内容本身可见，
错误在于它遮盖本应位于其上的 Win32 同级子窗口。

## 现象与可复现条件

SOLIDWORKS 硬件加速视口曾覆盖 FeatureManager、顶部命令栏和右侧任务窗格。
原始 `0002` 把 `SYSRGN` 转换为 Core Animation 图层遮罩后，窗口布局变化时的避让
大体正确，但独立最小程序在**冷启动首次 OpenGL 呈现**后仍会让画布覆盖顶栏和
左右 GDI 面板；调整窗口尺寸或拖到屏幕边缘触发重绘后，三块面板重新出现。
用户观察到启动时面板短暂可见，然后被首个 OpenGL 画面覆盖，与此相符。

完整、可独立编译的复现源码在
[`scripts/diagnostics/winemac_opengl_child_clipping.c`](../scripts/diagnostics/winemac_opengl_child_clipping.c)。
它创建一个铺满客户区的 OpenGL `WS_CHILD | WS_CLIPSIBLINGS` 窗口，并在其上方
布置顶栏、左栏和右栏三个 GDI 同级子窗口；定时调用 `SwapBuffers`。
`R` / `H` 切换右栏 / 顶栏，`P` 打印视口 HDC 的 `SYSRGN`。
在 Windows 原生运行时，首次显示就应同时看见三块面板，OpenGL 三角形只在中间
蓝色区域绘制。先前在 Parallels Windows 上使用同一二进制确认了该预期。

可用 MinGW-w64 编译（仓库不提交构建出的 `.exe`）：

```sh
x86_64-w64-mingw32-gcc -O2 -o /tmp/winemac_opengl_child_clipping.exe \
  scripts/diagnostics/winemac_opengl_child_clipping.c -lopengl32 -lgdi32
```

运行时应使用**独立 Wine prefix 与隔离驱动**，不要在正式 SOLIDWORKS bottle 中替换
`winemac.so`。对比未修补驱动、原始 `0002` 和本文所述修订版；分别记录冷启动首帧、
切换面板、改变尺寸后的画面。上游 [Wine MR !8504](https://gitlab.winehq.org/wine/wine/-/merge_requests/8504)
所附 MDI 示例也是补充用例；其 `tile1.tga` 使用相对路径，必须从资源所在目录启动，
否则 `Image file was not found` 是工作目录错误，不是裁剪故障。

## 排查过程与证据

1. 未修补 Wine 11.16：最小程序的 OpenGL 覆盖三个 GDI 同级窗口；MDI 示例也有
   子窗口相互覆盖。
2. 原始 `0002`：冷启动仍覆盖，但窗口尺寸变化后恢复正确。诊断日志显示
   `NtGdiGetRandomRgn(SYSRGN | NTGDI_RGN_MONITOR_DPI)` 从空区域变为
   `(220,64)-(732,646)`（视口客户区 `952×646`）；`get_region_data` 得到一个矩形。
   对应的 Cocoa view、layer、mask 和 frame 在首次 `SwapBuffers` **之前**已经存在，
   mask 大小也为 `952×646`。因此不能简单归因于区域坐标或尺寸计算错误。
3. 分别测试四种首次呈现处理：

   | 候选 | 首次呈现时的操作 | 冷启动结果 |
   | --- | --- | --- |
   | A | 重新查询并应用 `SYSRGN` | 正确 |
   | B | 仅 `setNeedsDisplay` / `displayIfNeeded` | 仍覆盖 |
   | C | 只重放**已缓存**的裁剪区域 | 正确，两次冷启动均通过 |
   | D | 仅再次设置 view 为可见 | 仍覆盖 |

4. 选择 C，避免首次交换时再次采样可能尚未稳定的 `SYSRGN`。无诊断日志的构建在
   隔离 Wine prefix 中通过冷启动、右栏收放、顶栏收放和窗口尺寸变化；同一思路的
   隔离构建还通过了 MR !8504 的 MDI 重叠示例。用户的正式 SOLIDWORKS 容器、
   Wine 安装和 FlexNet 服务均未用于这轮 A/B 测试。

这里的“原因”应按证据边界表述：**初始裁剪区域及图层遮罩已正确建立，但第一次
OpenGL 呈现后没有立即按它合成；重新应用相同的缓存区域可以让裁剪生效。**
这支持首次呈现阶段的遮罩激活／合成时序问题，不足以断言 macOS 内部究竟是哪次
CALayer transaction、NSOpenGL drawable 更新或 compositor 提交丢失了遮罩。
仅重新请求绘制或重复设置 view 可见性均未修好，更不能把这两种操作当作根因。

## 修订、验证范围与残余风险

本地提交 `8513982` 扩展了 `0002`：`macdrv_client_surface_present` 在首次带 HDC
的呈现时，从 `surface->clip_region` 取已缓存矩形，再调用一次
`macdrv_set_view_clip`；每个 surface 仅重放一次。后续布局变化仍走现有的
`macdrv_client_surface_update_clip`，不会在每帧查询区域。

补丁已在独立 Wine 11.16 源码中通过反向卸载、原始源码应用检查和重新应用；
隔离 `winemac.so` 构建及上述实际窗口测试通过。**尚未**在正式 MacSW bottle 中
安装此修订版，也未完成 Wine 上游 CI、广泛应用兼容测试或 PR 审查。
对 view 重建／重新挂接、空裁剪区域、多个 GL surface、不同 macOS 版本与
Retina／多显示器坐标变化仍需独立回归；这些场景不能凭当前两个示例宣称已解决。
提交上游前尤其需要确认“一次重放”的生命周期边界和额外的 CALayer 更新开销。

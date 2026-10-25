# Wine macOS OpenGL 子窗口裁剪：原始调查与修复记录

本文回溯 2026-09-12 在 SOLIDWORKS 2025 SP5、Wine 11.16 和 macOS 上进行的第一轮调查。历史截止点是提交 `361ade8`；下文的“最终实现”和“验证”均指**当时**的状态，不代表当前补丁的完整行为。对应提交依次为 `8ffb53c`、`84eee93`、`aa1fe13`、`361ade8`。后续发现的冷启动首帧问题另见[首次呈现调查](winemac-opengl-child-clipping.md)。

## 现象与判断

在 SOLIDWORKS 中新建 Part 后，硬件加速的 3D 画布会盖住 FeatureManager、顶部 CommandManager 或右侧 Task Pane。画布本身可以绘制；出错的是画布与 Win32 同级子窗口的可见区域和叠放关系。早期用常驻守护程序移动、缩放视口来避开停靠面板，但窗口拖动、MDI 重排和顶部菜单展开/收回会改变实际布局，固定几何避让随之失效。

当时的关键观察：

| 操作或版本 | 观察 | 对调查的意义 |
| --- | --- | --- |
| 原版 Wine 驱动，新建 Part | OpenGL 画布覆盖 GDI 面板及部分命令栏 | 需要让原生图形表面遵守 Win32 可见区域 |
| 最初加入图层遮罩后，移动或重排子窗口 | 局部避让出现，但位置漂移，某次出现黑屏 | 仅创建遮罩不够；图层归属、尺寸和区域都要同步 |
| `84eee93` 后展开/收回顶部菜单 | 顶部留白过大、折叠按钮向下错位，有时仍覆盖菜单 | 坐标系换算存在重复处理 |
| `aa1fe13` 后展开右侧 Task Pane | 布局已改变，但画布遮罩要等旋转视图后才正确 | 区域更新被错误地绑在下一次 OpenGL present 上 |
| `361ade8` 后重复展开右侧面板 | 用户观察到立即刷新；顶部菜单收放和左侧面板也正常 | 原始这轮问题在所测交互中得到解决 |

上述应用截图和实时反馈来自本轮对话；截至 `361ade8`，仓库尚无独立的最小复现程序。因此“解决”指当时所测 SOLIDWORKS 路径，不等于所有 OpenGL 子窗口或所有首次呈现时序均已证明正确。

## 原因定位

Wine 的 Win32 窗口系统知道子窗口的可见区域。对视口 HDC 调用 `NtGdiGetRandomRgn(hdc, region, SYSRGN | NTGDI_RGN_MONITOR_DPI)` 可以取得当前系统裁剪区，其中已经反映同级窗口对视口的遮挡。macOS 一侧的 `WineContentView` 承载 OpenGL 内容，但原版 `winemac.drv` 在所测情形下没有把这组矩形约束应用到承载视口的 Core Animation 图层。原生图层因此继续在 GDI 控件上方合成。

这也是守护程序改写视口几何难以稳定的原因：SOLIDWORKS 自己可以随时调整 MDI 子窗口、停靠栏和 CommandManager。真正需要同步的是视口**当前可见的区域**，而不是替应用决定视口应该有多大。

调查中还纠正了两个具体错误：

1. `SYSRGN` 返回的矩形在这条 HDC 查询路径上已经是客户区局部坐标。初版再次用 `NtUserMapWindowPoints` 求屏幕原点并调用 `NtGdiOffsetRgn` 相减，使遮罩偏离视口。临时区域日志与顶部留白、菜单覆盖的画面一致。
2. 目标 `WineContentView` 的坐标变换已经处理了纵向方向。`84eee93` 曾按图层高度手工执行 `height - CGRectGetMaxY(rect)`；这又翻转了一次 Y。`aa1fe13` 删除了手工翻转及上述原点相减，直接用 `cgrect_mac_from_win` 转换每个区域矩形，随后在应用里验证顶部收放和侧栏位置。

最后一个问题是**更新时机**。`84eee93` / `aa1fe13` 在 `macdrv_client_surface_present` 中读取 `SYSRGN`；右侧 Task Pane 展开后，SOLIDWORKS 不一定立即提交新的 3D 帧，因此遮罩保持旧形状。旋转视图会触发 present，画面才恢复。由这个可重复观察，裁剪采样被移到 Wine 已有的 client surface 几何更新路径中，而不是等待绘图帧。

## 历史实现

截至 `361ade8`，[`0002-winemac-metal-layer-clipping.patch` 的固定历史版本](https://github.com/YJBeetle/MacSW/blob/361ade85ee0ee98d898a13bed4a644111e9044dc/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch) 涉及 `dlls/winemac.drv/cocoa_window.m`、`macdrv.h`、`macdrv_cocoa.h` 和 `window.c`；也可在本地用下文的 `git show 361ade8:...` 查看：

1. 每个 `macdrv_client_surface` 保存上次的 `HRGN`、对应的 `monitor_rect` 和有效标志。区域或 frame 未变化时跳过重复设置；surface 销毁时释放区域对象。
2. `macdrv_client_surface_update_clip` 从视口 HDC 读取 `SYSRGN`，用 `get_region_data` 得到矩形，将其传给 Cocoa 侧的 `macdrv_set_view_clip`。查询不到区域时撤去已缓存遮罩；有效的空矩形集则让 view 隐藏。
3. `macdrv_set_view_clip` 在主线程把矩形组成 `CGPath`，设置为 `WineContentView` 图层上的 `CAShapeLayer` mask。事务禁用隐式动画，同时更新 mask frame；这样布局变化时不会看到遮罩过渡动画。矩形沿用 Wine 现有的 `cgrect_mac_from_win` 转换，不再额外平移或翻转。
4. `macdrv_client_surface_update` 使用 client surface 已锁定的 `toplevel` 关联 Cocoa 窗口，更新 view 的 frame、superview 和 `offscreen` 状态。对离屏子窗口临时用 `NtUserGetDCEx(hwnd, 0, DCX_CACHE | DCX_USESTYLE)` 取 DC，立刻更新裁剪，随后释放 DC。`macdrv_client_surface_present` 不再每帧采样区域。

同时，`8ffb53c` 把原 C# UI 守护程序换成可构建的原生 x64 Win32 辅助程序，并移除了它对视口及停靠面板几何的改写。守护程序当时仍处理登录管理器、字体、浮动窗口和部分主题兼容性；图形避让交给 `winemac.drv`。这项职责转移和驱动修复一同验证，不能把所有 UI 效果单独归功于图层遮罩。

## 构建与实测边界

当时使用 Wine 11.16 官方源码应用仓库补丁，运行 `scripts/build_winemac.sh` 重建 `winemac.so`，并用 `scripts/make_app.sh` 装入固定的 Wine 11.16 MacSW 包。构建脚本校验源码哈希，先检查补丁可应用，再编译驱动；正式包中的驱动经过签名验证。这证明补丁能在指定源码上构建、打包，不单独证明运行行为。

运行验证由正式 SOLIDWORKS 容器中的空白 Part 完成。当时确认 FeatureManager 未被画布覆盖、CommandManager 展开/收回正常、Part 子窗口移动/恢复/最大化后没有再次出现所见黑屏；最后用户确认右侧 Task Pane 展开时裁剪“瞬间渲染刷新了”。这些是人工交互观察，未留下像素级自动断言。提交 `361ade8` 之后还从干净 Wine 源码重新构建并打包正式 App；打包和签名通过，但该正式重打包版本没有再次完成一轮单独的 Task Pane GUI 复测，不能把前一次交互测试写成那次重打包的独立验证。

便于历史核对，可在仓库运行：

```sh
git show 8ffb53c:patches/wine-crossover/0002-winemac-metal-layer-clipping.patch
git show 361ade8:patches/wine-crossover/0002-winemac-metal-layer-clipping.patch
git show --stat 8ffb53c 84eee93 aa1fe13 361ade8
```

## 上游化前仍需补齐的证据

这份记录只覆盖原始调查。截至 `361ade8`，独立的 Win32/OpenGL 子窗口最小复现仍是上游化前待补的证据；后续已补齐[复现源码](../scripts/diagnostics/winemac_opengl_child_clipping.c)并另行调查[冷启动首帧问题](winemac-opengl-child-clipping.md)。提交 Wine 上游前，仍需按当前补丁状态核对同级窗口显隐、MDI 移动、resize、Retina 与多显示器，以及 `SYSRGN` 不可用、空区域、view 重挂载和多个 surface 的生命周期。`361ade8` 当时没有证明首次呈现始终正确，不能把后续结果倒写成这轮的结论。

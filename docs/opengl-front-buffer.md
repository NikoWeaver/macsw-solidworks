# SOLIDWORKS 前缓冲刷新导致模型消失

## 现象

SOLIDWORKS 2025 SP5.0 的硬件加速视口完成一次完整重绘后，会在以下操作后只剩背景：

- 清除选择后再次点击空白画布；
- 点击 SOLIDWORKS 窗口外，使 Wine 窗口失去焦点。

模型数据和命中测试仍然存在。中键旋转会重新绘制完整模型；鼠标经过几何边线触发预选时，
模型也会随局部重绘重新出现。Windows 上持续到鼠标移开的橙色预选轮廓，在 Wine 上只闪一帧
或完全不可见。这些现象说明问题位于绘制结果的呈现，而不是模型可见性、窗口裁剪或输入命中。

## 根因

SOLIDWORKS 使用前缓冲绘制选择、预选和部分局部状态。Wine 11.16 的调用链中，`win32u` 已先
调用应用所要求的 `glFlush()` 或 `glFinish()`，随后 `winemac.drv` 的
`macdrv_surface_flush(..., GL_FLUSH_PRESENT)` 又调用 `macdrv_flush_opengl_context()`。

macOS 端该函数最终执行 `[NSOpenGLContext flushBuffer]`。对于双缓冲上下文，这不是普通刷新，
而是缓冲交换。SOLIDWORKS 当前像素格式 29 同时声明 `PFD_DOUBLEBUFFER` 与 `PFD_SWAP_COPY`；
额外交换会把未包含完整场景或局部覆盖层的缓冲呈现出来，因而产生模型消失和预选闪烁。

同版本 CrossOver 源码只在真正的 surface swap 路径交换缓冲，前缓冲 flush 路径不会调用
`flushBuffer`，也印证了这两种操作应当分离。

## 修复

[`0004-winemac-preserve-front-buffer-flush.patch`](../patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch)
从 `GL_FLUSH_PRESENT` 分支移除 `macdrv_flush_opengl_context()`，保留
`client_surface_present()`。真正的双缓冲交换仍由 `macdrv_surface_swap()` 负责。

Builder 将补丁内容纳入 `winemac.so` 构建缓存键；打包时把补丁校验值写入
`BuildManifest.plist` 的 `WineMacOpenGLPatchSHA256`，`verify_app.sh` 会同时验证补丁与模块。

## 2026-09-14 回归

在同一 bottle、同一 `TestModel.SLDPRT` 和补丁版 Wine 11.16 上完成：

- 中键旋转建立完整重绘后，在空白画布连续点击两次，模型保持可见；
- 使用 macOS 应用激活机制把 MacSW 控制窗口真正切到前台，模型保持可见；
- 鼠标停在模型边线上数秒后截图，完整橙色预选轮廓仍然存在；
- 中键旋转继续正常工作。

鼠标手势轮盘的黑色背景属于独立的屏幕背景读取问题，原因与修复见
[调查记录](mouse-gesture-background.md)。

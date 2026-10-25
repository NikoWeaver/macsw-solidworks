# TreeView 布局兼容性

`0010-comctl32-treeview-image-spacing.patch` 修正 Wine 11.16 的 TreeView
图标间距及默认缩进。App 仅替换 x86-64 的 `comctl32_v6.dll`，不替换
v5 `comctl32.dll` 或 32 位模块，不修改 SOLIDWORKS DLL、窗口位置或注册表。

## 原因与原生对照

在 SOLIDWORKS 特征树及部分任务窗格中，图标或展开三角紧贴左边界并被裁切。
2026-10-09/10 用带 Common-Controls v6 manifest 的 Win32 探针对照原生 Windows
和 Wine；两端使用相同的图像列表，分别测试 DPI 感知 120 DPI 和非感知 96 DPI。
这排除了仅由 DPI 或 SOLIDWORKS 图标素材差异造成布局偏移的解释。

原生 v6 保留 3px 左侧留白；有普通图像列表时，图标与文字另有 3px 间距，
默认缩进包含这 3px。Wine 原实现缺少这些间距。以 20px 图标、无根级展开缩进为例：

| 参数 | Wine 原实现 | 原生 Windows / 补丁后 |
| --- | ---: | ---: |
| 默认缩进 | 20px | 23px |
| 根项图标起点 | 0px | 3px |
| 根项文字起点 | 20px | 26px |
| 子项文字起点 | 40px | 49px |

真实 SOLIDWORKS 特征树也测得补丁后 `indent=23`、根项标签 x=26、子项 x=49，
并由用户截图确认图标及展开三角恢复完整。间距修复位于
`TREEVIEW_ComputeItemInternalMetrics` 和 `TREEVIEW_SetImageList`，所以位置查询、
绘制及鼠标命中共享同一套坐标，而不是对 SOLIDWORKS 截图或窗口做平移补偿。

先前未嵌入 manifest 的探针实际测试的是 v5，不能作为 v6 几何结果的参考。
无普通图像列表时不添加图标到文字的间距，但 v6 的左侧留白仍然存在。

## 可重复验证

`make treeview-probe` 构建独立的 `build/native/wine_treeview_probe.exe`。
此诊断工具不打进 App，也不会操作或附加到现有 SOLIDWORKS 实例。
分别在原生 Windows 和包含补丁的 Wine 运行时执行：

```text
wine_treeview_probe.exe
wine_treeview_probe.exe --unaware
```

每次执行检查 24 组配置，共 564 个断言：无图标、16/20/32px 图标；
普通树、特征树样式 `0x89`、根级展开按钮；左右布局模式；根项和子项坐标；
图标和文字鼠标命中；显式 80px 缩进、重新附加同一图像列表、移除图像列表。
两种 DPI 模式下，原生 Windows 与正式构建的 Wine 模块均为 0 失败。

离线单元测试 `scripts/tests/test_wine_treeview_layout.py` 检查补丁、模块编译、
构建缓存、打包路径、manifest SHA 与模块 SHA 的接线。它不证明真实 UI 绘制；
运行探针和 SOLIDWORKS 对照才提供运行时证据。

## 构建与加载

`scripts/build_winemac.sh` 按序应用 0010 并构建
`dlls/comctl32_v6/x86_64-windows/comctl32_v6.dll`。缓存键包含补丁 SHA，
缓存命中还要求该 DLL 存在。打包将它放到运行时
`lib/wine/x86_64-windows/comctl32_v6.dll`，验证阶段检查架构、模块一致性和两个 SHA。

只替换 bottle 中 WinSxS 的 DLL 不足以验证补丁：Wine 会优先加载运行时目录中的
builtin 模块。不要为了测试全局设置 `comctl32=n,b`；使用独立运行时，并以探针
实际返回的布局确认补丁生效。SOLIDWORKS 测试应复用 `WineService.environment`
的 VC++ native DLL overrides 和 Mono 配置；漏掉 `concrt140=n,b` 会触发内置
`GetProcessorCount` 未实现的启动崩溃，与本补丁无关。

为了不替换运行中的 App，可设置 `MACSW_APP_OUTPUT` 构建独立包；
打包和验证均遵循这个输出路径。

## Royale 与软件配色交叉对照

2026-10-10 在 120 DPI 下，以两个独立测试 bottle 同时对照
`ThemeActive=0` 和 `ThemeActive=1` + Royale。两者使用同一个专用运行时，
并通过实际加载文件确认使用未包含 0010 的旧 `comctl32_v6.dll`，避免共享主运行时
造成“无补丁”对照失效。这里的“无补丁”仅指不包含 0010，其他 Wine 修正仍然保留。

- 两端特征树仍有裁切，均为 `indent=20`、根项标签 x=20、子项 x=40。
  Royale 将观察到的特征树 DC 左侧 clip 从 x=1 改为 x=0，但不足以消除图标裁切。
- 在软件浅色界面下，两端右侧图标都可以完整显示；用户将 SOLIDWORKS 内部配色
  切到深色后，右侧裁切重新出现。因此右侧此前的改善不能归因于 Royale 或 0010。
  已读取的右树 clip x=0 及布局指标没有随之改变；调整宽度的竖向分隔条是否遮挡
  内容、或深色绘制路径是否使用不同裁剪区，尚未完成因果验证。
- 用户提供的原生 Windows 对照也有深浅色展开符差异。展开符外观变化本身
  不是裁切证据，也不能证明存在独立的 `.msstyles` 文件。

在 Wine 和原生 Windows 的 SOLIDWORKS 安装目录及共享目录中，未找到独立
`.msstyles` 文件。软件包含 `rwuxthemesu14.dll` 和 `swStyle*` 模块，前者导出
`RWOpenThemeData`、`RWDrawThemeBackground` 等主题包装接口；这只是内部主题
绘制路径的线索，不证明主题资源以何种格式保存，也不排除嵌入资源。

## 未覆盖及独立问题

- 这次不改变父窗口 DC 的裁剪区；特征树原有 clip x=1 仍需单独判断。
- Wine 原有的极小显式缩进及复选框状态图布局不完全等同原生；不声称本补丁
  实现了全部 TreeView 兼容性，也不把这些差异扩大进此次修改。
- 右侧 File Explorer 曾测得公有窗口 style 与原生内部 style 不一致；不强行
  添加展开按钮标志，该路径仍需继续验证。
- 底部假滚动条由独立的 [PrintWindow 捕获补丁](printwindow-capture.md) 修复；
  0010 不负责它，也不证明所有滚动后不渲染都已解决。字体方框是另一问题。

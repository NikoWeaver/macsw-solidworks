# Wine 主题控件探针

独立、只读的原生 Win32 预览程序，用于修改 Wine 配色后比较控件效果。
源码保留在 `native/wine_theme_probe.c`，不依赖 Wine-Mono，不自动启动，不随正式 App 打包。
它不写注册表、不调用 SetSysColors、不广播配色变更、不访问 SOLIDWORKS，也不结束 wineserver。

## 构建与启动

需要 MinGW-w64（macOS 可用 `brew install mingw-w64`）：

```bash
make theme-probe
```

输出为 `build/native/wine_theme_probe.exe`。独立脚本也可执行：

```bash
bash scripts/build_wine_theme_probe.sh
```

脚本支持用 `MINGW_CC`、`MINGW_WINDRES` 指定编译器。运行时应选择要观察的 App 运行库与
**已经存在**的 bottle；不要为了看配色重启 SW 或整个容器。以下从仓库根目录运行，
使用当前开发 App 与主 bottle：

```bash
MACSW_APP="$PWD/build/app/MacSW.app"
WINE_RUNTIME="$MACSW_APP/Contents/Frameworks/wine"
WINEPREFIX="$HOME/Library/Application Support/MacSW/bottle" \
WINELOADER="$WINE_RUNTIME/lib/wine/x86_64-unix/MacSW" \
WINESERVER="$WINE_RUNTIME/bin/wineserver" WINEDEBUG=-all \
  "$WINE_RUNTIME/lib/wine/x86_64-unix/MacSW" \
  "$PWD/build/native/wine_theme_probe.exe"
```

可将这些环境参数指向独立测试 bottle。启动不存在的 bottle 仍会触发 Wine 自身初始化，
因此探针只读不等于 Wine 绝不会创建自己的运行文件。

## 预览内容

左侧四页、右侧始终显示两个真实 MDI 子窗口：

| 页面 | 覆盖内容 |
| --- | --- |
| Controls | 普通、默认、禁用按钮；白底自绘按钮；勾选、三态与禁用复选框；单选按钮；分组框；Tooltip；MessageBox |
| Inputs | 可编辑、只读、禁用、密码与多行输入框；滚动条；可编辑组合框和下拉列表；日期选择与日历 |
| Data | 列表表头、选中行、网格与滚动条；展开树和选中节点；进度条；滑块；数值输入和微调控件 |
| System colors | 31 个 GetSysColor 槽位的色块、名称和 RGB 值 |

菜单也使用真实菜单。Window 菜单可平铺、层叠、最大化和还原活动文档；点子窗口标题
可切换活动/失焦状态，每个子窗口带状态栏与尺寸拖动柄。Common Controls v6 manifest
嵌入 EXE，避免因为预览程序缺少 manifest 而只观察到旧版公共控件。

启动时 stdout 输出主题状态及 31 个系统颜色，窗口就绪后输出 READY。
程序支持以下参数（追加到上述启动命令的 EXE 后）：

```text
--page controls|inputs|data|colors  指定初始页
--show-page controls|inputs|data|colors  切换一个已打开探针的页（方便连续截图）
--dump-colors                      只输出颜色后退出，不显示预览窗口
--self-test                        检查控件创建、左右布局、四页切换及 MDI 激活/最大化/还原后退出
--close                            仅向一个探针窗口类发送 WM_CLOSE，不关闭其他程序
```

无参数时保留窗口供交互观察，不定时退出。修改配色后仅关闭并重开探针即可读新值；
不要以当前老进程的颜色缓存判断注册表是否写入成功。截图可用于比较，但自动检查通过
不代表每个主题、每种控件状态和所有自绘区域都具有正确的视觉对比度。

## 对照要点与限制

普通标签可能使用 WindowText 加 ButtonFace，而编辑框使用 WindowText 加 Window；
只有其中一个背景改深，可能产生浅字浅底。只读与禁用输入框也不一定使用 Window 背景。
白底自绘按钮故意把固定白底与系统 ButtonText 混用，用于暴露 SW Error Report 所示的
兼容性风险，但不是那个应用控件的复刻。禁用控件还可能有浮雕、阴影等额外绘制。

MDI 使用 MDICLIENT/DefMDIChildProc 的真实非客户区，不是伪造的标题条；不过它不加载
Codejock/XTP，不复现 SOLIDWORKS 的五个自绘标题按钮。这个探针能验证标准 Windows 控件
和系统色组合，不能代替 SW 的实际界面验证。英文样例用于隔离字体缺字问题。

现有运行库的标题栏兼容设置见 [标题按钮风格说明](caption-button-theme.md)。

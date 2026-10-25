# 中文界面字体

> Locale note: the Wine locale is a single setting, `MacSW.wineLocale` (Settings > Wine language).
> Default `en_US.UTF-8` (code pages 1252/437); `zh_CN.UTF-8` (code page 936) stays selectable.
> The PingFang link and the SimSun/宋体 aliases to Tahoma are written in both cases, so Chinese
> file names and UI text still render under en_US; no CJK system locale is forced. Detection of
> PingFang keys on the `PingFang.ttc` path, not on the localized family name. Switching locale on
> an existing bottle can reset SystemLink to the new locale's default list unless the
> `0012` patch is present; the startup Tahoma repair re-adds the PingFang link if it is missing.

MacSW 优先使用 macOS 已提供给 Wine 的苹方，不下载、复制或随 App 打包 Apple 字体。
Wine 按系统语言登记字体，简体中文环境里的注册表值名通常是「苹方-简 …」；
安装程序因此在 Wine 的 Fonts 注册项中查找 PingFang.ttc 路径，而不依赖英文值名。
若系统尚未提供可用的苹方资源，SOLIDWORKS 安装仍继续，环境状态会提示中文可能显示不完整。

安装期将缺失的 Windows 界面字体名映射到 Tahoma，再把苹方加到 Tahoma 的
FontLink\SystemLink 首位，同时保留 Wine 原有的其他语言链接。这样只用苹方补缺失
字形，避免直接把 Tahoma 换成苹方后增大固定高度控件的行高。注册表文件采用带 BOM
的 UTF-16LE，REG_MULTI_SZ 采用标准 UTF-16LE hex(7)，中文别名不会乱码。
首次安装在安装环境准备中配置这些设置。MacSW 每次打开时还会在后台检查已安装
容器的 Tahoma FontLink：已正确配置就不写入，缺失时在首位补回苹方并保留其他链接。
检查沿用字体文件名和 ASCII 类型名解析，不依赖可能以 GBK 输出的中文值名；遇到疑似
折行或无法安全解码的原有链接时拒绝回写。随后自动或手动启动 SOLIDWORKS 等待同一个
字体准备任务，失败后允许重试；全新安装删除容器前取消并等待该任务。没有已安装容器
时不会为检查创建前缀。字体平滑的 `FontSmoothingType=REG_DWORD 2` 仍只在安装期配置。

如果容器里另有真实的微软雅黑、Segoe UI 等字体文件，Wine 可能直接命中它们而不走
苹方回退。此类历史手动安装的字体应单独备份、移出并清除对应注册项；MacSW 不会
在安装时删除用户已有字体。SOLIDWORKS 自带的工程字体不受影响。

验证范围：临时干净 Wine 前缀的 GDI 绘制已显示中文，Tahoma 的 -16 请求保持
约 19px 行高；注册表查询、编码和别名均有 XCTest 覆盖。SOLIDWORKS 完整界面、
字体粗细及固定高度控件仍需在最终 App 中验收。

## wineboot 后的方块字与代码页切换

2026-10-10 在独立字体测试前缀复现：历史上 MacSW 的 Wine 环境固定为
`LANG=LC_ALL=zh_CN.UTF-8`（现默认 `en_US.UTF-8`，可在设置中改回），代码页为 `936,936`；终端的 `C.UTF-8` 或
`en_US.UTF-8` 使测试进程使用 `1252,437`。原版 Wine 11.16 的
`win32u/font.c:update_codepage()` 检测到变化后调用
`update_font_system_link_info()`，无条件用内置列表覆盖各字体的 SystemLink。
MacSW 追加的 `PingFang.ttc,PingFang SC` 因此丢失，Tahoma 又不含中文字形。
苹方的注册字体数量没有变化；这是链接丢失，不是字体文件被删除或字体平滑失效。

同中文环境执行 `wineboot -u` 未丢失链接；不同语言环境的 GDI 程序即使不执行
wineboot，也能复现覆盖。切回中文会再次换成中文默认列表，但不会自动补回苹方。
仅恢复 Tahoma 的苹方链接，再启动绘制进程，中文像素与覆盖前一致。
单独把 DPI 从 96 改为 120，以及同语言的 `wineboot -i`，未触发此问题。
因此不能将“任何 wineboot 都会损坏字体”当成根因。

`0012-win32u-preserve-custom-font-links.patch` 改变的是默认列表更新规则：

- 值不存在时生成正常默认值；与当前 Wine 内置的任一语言默认列表逐字节一致时，
  仍按代码页更新默认顺序。
- 不等于这些默认值时，完整保留用户列表、顺序、空值和原有类型；不强行追加苹方，
  也不重排或合并用户自行选择的回退。
- 动态查询完整注册表数据，避免大列表被固定缓冲截断后误当成缺失。
  读取失败或内存不足时不覆盖原值。

补丁作用于 Wine 的默认字体链接更新，不限定 SOLIDWORKS 或 Apple 字体。
它不冻结代码页，不改变 DPI、字体替换规则或语言环境；FontSubstitutes 的原有
语言更新仍然存在。由不同 Wine 版本生成而不匹配当前默认的列表也会保守保留。
构建缓存包含补丁 SHA，打包记录 `WineFontLinkPatchSHA256`，验证阶段同时核对
补丁 SHA 和实际 `win32u.so` 的 `WineInputModuleSHA256`。

### 回归验证

`make fontlink-probe` 构建可选诊断程序。**它会写入字体注册表测试值，只能在可丢弃的
临时 Wine 前缀中执行，不要运行在主容器或原生 Windows 日常环境。** 不打进 App，
不操作 SOLIDWORKS。先在中文环境设置，再从英文、日文、韩文、繁体中文、简体中文
及 `C.UTF-8` 环境分别启动验证进程：

```text
wine_fontlink_probe.exe setup-custom Z:\\temp\\custom.bin
wine_fontlink_probe.exe verify-custom Z:\\temp\\custom.bin
wine_fontlink_probe.exe setup-default
wine_fontlink_probe.exe verify-default
```

自定义测试逐字节比较 Tahoma 的苹方／中文名称／附带参数、多于 4KiB 的回退列表、
有意设置的空列表和不在 Wine 默认表中的字体。默认测试检查缺失值重新生成，以及
已知中文默认值随代码页切换后更新首选字体。切换须覆盖不同代码页，否则不会触发
需要验证的更新路径。测试前先保存主机语言环境，不要复用运行中的主容器。

已有 MacSW 启动修复暂时保留：它能补回历史上已经丢失的苹方链接；新补丁只防止
再次覆盖，不能恢复丢失的数据。链接正确时检查不写入。其他旧运行时、用户手动
删除链接或重建字体配置也可能仍需恢复，不能据此删除全部兜底。

2026-10-10 回归通过：六种语言环境逐字节保留自定义列表；五种代码页环境仍更新
内置默认列表并生成缺失值。主容器关闭 MacSW 后直接执行 `C.UTF-8` 的 `wineboot -u`，
未调用启动注册表修复，Tahoma 苹方链接仍在，前后中文 GDI 位图逐像素一致。
重新打开已替换运行时的主 SOLIDWORKS，欢迎页、菜单与任务窗格中文显示正常。

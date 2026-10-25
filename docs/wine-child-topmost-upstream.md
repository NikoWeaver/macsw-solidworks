# SOLIDWORKS PropertyManager 标题消失与 Wine 子窗口 TOPMOST 语义

调查日期：2026-09-24。适用对象：MacSW 的 Wine 11.16 补丁
[`0005-win32u-ignore-child-topmost.patch`](../patches/wine-crossover/0005-win32u-ignore-child-topmost.patch)。

## 现象与根因

在 SOLIDWORKS 中创建草图后打开“拉伸凸台”，或编辑已有特征时，PropertyManager
左侧分组标题会先出现，再从左向右逐渐消失。文档子窗口最大化时，移动并释放主窗口
还会重现一次；子窗口未最大化时没有观察到同样的拖动触发条件。特征树边缘另有几个
像素被裁切，**不是本补丁修复的对象**。

先前的 Windows 原生 / 未修补 Wine / 修补后 Wine 对照排查表明，SOLIDWORKS 会对
真正的子窗口调用 `SetWindowPos(child, HWND_TOPMOST/NOTOPMOST, ...)`。原生 Windows
在这一条件下返回成功，但不改变子窗口矩形，也不发送对应的 `WINDOWPOS` 布局消息；
Wine 11.16 则继续执行位置与尺寸更新。SOLIDWORKS 的 PropertyManager 因此重复
布局，每轮让标题控件向右缩窄约 4 px，最终宽度为零。视觉上像“擦除文字”，实际是
承载文字的控件不断变窄；同时观察到的 `WM_ERASEBKGND` 更可能是布局过程的症状。

这些动态观察来自此前的本机及原生 Windows 对照测试；原始抓取日志和 probe 源码
目前没有收录在本仓库，不能把它们当作可直接复跑的附件。不过 Wine 当前 master 的
[`dlls/user32/tests/win.c`](https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/user32/tests/win.c)
`test_SetWindowPos` 已经对 child + `HWND_TOPMOST/NOTOPMOST` 的矩形不变性写了
`todo_wine` 断言，独立佐证了 Windows 与 Wine 的兼容性差异。

## MacSW 本地修复与验证边界

本地 `0005` 在 `NtUserSetWindowPos` 中，仅对有**非桌面父窗口**的真正 `WS_CHILD`
窗口、且未设置 `SWP_NOZORDER` 的 `HWND_TOPMOST/NOTOPMOST` 请求直接返回成功。
保留 `SWP_NOZORDER` 边界很重要：此标志表示忽略 `hWndInsertAfter`，位置与尺寸
更新仍应正常执行。此前最小 Win32 对照及真实 SOLIDWORKS 复测确认，修补后标题
不再连续缩窄；MacSW 当时通过
`make app`、132 项 Swift 测试及 137 项 Python 测试。这些是 **MacSW 集成验证**，
不是 Wine 上游 CI 或 Wine Test Bot 的结果。

2026-09-24 对 Wine master `1977760e3745c58ee9c2b8aeb93e54e5fe7f14e2` 做了
`git apply --check`，本地补丁可应用；**尚未**在该 master 上完成构建或全套 Wine
测试。2026-09-25 发现先前版本的补丁拦截范围过宽：Wine 的 `ComboLBox` 虽有
`WS_CHILD` 样式，实际父窗口是桌面；`winecfg` 中 Windows 版本下拉框点击后
`CB_GETDROPPEDSTATE=1`、有 20 个选项，但列表未显示，位置也没有更新。方向键
仍可切换选项；诊断时用 `SWP_NOZORDER | SWP_SHOWWINDOW` 强制显示后，移开主窗口
才看到列表悬在旧位置。这个悬空列表是**诊断操作的结果**，不是普通点击时的表现。
因此本地补丁已增加非桌面父窗口检查，避免吞掉 `ComboLBox` 展开时的
`SetWindowPos(..., HWND_TOPMOST, ..., SWP_SHOWWINDOW)`。这仍是本地兼容性补丁，
不能替代上游 MR 的完整测试与审查。

修补前后用 [`check_combobox_drop.c`](../scripts/diagnostics/check_combobox_drop.c)
在独立 Wine 前缀测试：两次均为 20 个选项、`CB_GETDROPPEDSTATE=1`，修补前
`list_visible=0`，修补后 `list_visible=1`，列表位于控件正下方；真正的非桌面
子窗口仍保持几何不变，而 `SWP_NOZORDER` 时仍可移动。`make app` 与 `make test`
通过，后者为 133 项 Swift、137 项 Python 测试。实际 `winecfg` 的 Windows
版本列表已由用户截图确认正常展开；用户随后用新包确认 SOLIDWORKS
PropertyManager 标题也正常，两项回归均通过。此前另一次手工启动未使用 App
的完整运行库覆盖配置，遇到 `concrt140` 崩溃；它不属于这两项通过的验证结果。

## Wine 上游现状

Wine 官方[提交指南](https://gitlab.winehq.org/wine/wine/-/wikis/Submitting-Patches)
要求通过 [WineHQ GitLab](https://gitlab.winehq.org/wine/wine) 提交 Merge Request，
并使用已验证账号和真实姓名；邮件补丁通道已退役。上游已经有
[`!667`](https://gitlab.winehq.org/wine/wine/-/merge_requests/667)，标题为
“win32u: Ignore SetWindowPos() if it is trying to change topmost state for child window.”，
截至 2026-09-24 仍为 open。该 MR 同时：

- 移除 `user32/tests/win.c` 中 child + `TOPMOST/NOTOPMOST` 的 `todo_wine`；
- 在 `set_window_pos` 内仅对真正有非桌面父窗口的 child 略过这类请求；
- 测试 `SetParent(child, NULL)` 后仍应正常更新，以及重新挂回父窗口后的行为；
- 关联 [Wine-Bug 20190](https://bugs.winehq.org/show_bug.cgi?id=20190)。

因此再开一个内容相同、覆盖边界更少的 MR 没有价值。更合适的上游动作是向
`!667` 补充 SOLIDWORKS 2025 的实际受影响与 MacSW 回归验证，或在征得该 MR
作者/维护者意见后协助刷新现有提交。2026-09-24 已通过已认证的 WineHQ GitLab
账号，在 [`!667` 的评论](https://gitlab.winehq.org/wine/wine/-/merge_requests/667#note_152626)
中补充 SOLIDWORKS 2025 的复现与本地修补后验证情况；没有新建重复 MR，也没有
声称已完成 Wine 上游 CI 或提交原始 probe 日志。

## 复核清单

1. 在原生 Windows 与未修补 Wine 上复跑 child + `TOPMOST/NOTOPMOST` 和
   `SWP_NOZORDER` 的独立 probe，保存矩形与 `WINDOWPOS` 消息日志。
2. 若更新上游代码，先复跑当前 Wine 测试，再运行改动后的 `user32/tests/win.c`
   和 Wine Test Bot；按官方建议把测试提交排在修复提交之前。
3. 保留非桌面父窗口、桌面父窗口、跨线程与 `SWP_NOZORDER` 的语义边界；不要直接
   把 MacSW 的简化 `0005` 复制到 Wine master。
4. 在 SOLIDWORKS 实机验证 PropertyManager 标题，同时单独追踪特征树左侧裁切。
5. 在 `winecfg` 验证 Windows 版本下拉框点击后列表紧邻控件显示，且选中项可变；
   再确认 SOLIDWORKS 设置页的下拉框同样正常。

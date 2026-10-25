# Login Manager 隐藏弹窗导致 SOLIDWORKS 交互失效

## 结论

SOLIDWORKS 2025 的复合右键菜单和鼠标手势轮盘曾被两个独立问题影响。第一层是 Login
Manager 未正确注册时弹出的致命模态对话框被 UI 守护程序隐藏，但对话框及其模态消息循环
仍然存在。主窗口虽然可见，SOLIDWORKS 自己的消息预处理链却没有正常运行。

在全新干净安装的 bottle 中安装 `swloginmgr/SOLIDWORKS Login Manager.msi`，并完成
`sldLoginManager.dll` 的托管 COM 注册后，缺失提示不再出现；经真机验证，一级和二级
复合右键菜单均可点击并执行，鼠标手势轮盘也能正常保持、选择并切换视角。

第二层是 Wine 在窗口重复取得自身鼠标捕获时仍发送 `WM_CAPTURECHANGED`。SOLIDWORKS 的
PropertyManager 标准按钮会因此在按下后丢失释放：按钮保持按下状态、捕获不释放，命令也不
执行。这条路径与 Login Manager 是否安装无关，并可能使复合菜单和轮盘的释放行为再次变得
不稳定。App 现在为 `sldworks.exe` 启用范围受限的 `WINE_NOCAPTURERESEND` 兼容开关，并随包
覆盖对应的 `win32u.so`。

## 诊断证据

隐藏状态下枚举到的窗口为启用但不可见的 `#32770` 对话框，正文是：

```text
SOLIDWORKS Login Manager is not installed. Reinstall SOLIDWORKS or install SOLIDWORKS Login Manager.
```

消息 hook 显示左键按下和释放均已通过 `WH_GETMESSAGE` 以 `PM_REMOVE` 进入队列，hook 本身
没有吞掉消息。调用栈停留在：

```text
USER32!IsDialogMessageW / CallMsgFilter
COMCTL32 v6!TaskDialogIndirect
sldvistauiu.dll
sldappu.dll
```

这说明主线程仍在隐藏的 Task Dialog 模态循环内。SOLIDWORKS 的分体式 `swPopup` 依赖自身
`uiCustomPopup::PreTranslateMessage` 处理命令；该链路被模态循环绕过后，会出现菜单项无法
点击、外部点击无法关闭菜单，以及轮盘释放后错误弹出右键菜单等现象。

## 鼠标捕获 A/B 证据

在同一套已安装 Login Manager 的 bottle、同一个 `win32u.so` 和同一个零件中编辑拉伸，唯一
变量是 `sldworks.exe` 的 AppCompat 值：

- 未启用时，左上角绿色确认按钮在 `WM_LBUTTONUP` 后仍持有捕获，按钮状态保持为 `0x0c`，
  PropertyManager 不关闭。
- 启用 `WINE_NOCAPTURERESEND` 时，同一按钮在释放后捕获回到 `NULL`、状态回到 `0x00`，
  拉伸编辑正常完成。
- `BM_CLICK` 在未启用时也能执行命令，说明 SOLIDWORKS 的按钮命令和建模逻辑本身有效，
  故障位于真实鼠标按下/释放与捕获转换路径。

补丁只在同一窗口重复取得捕获且显式启用兼容开关时抑制多余的 `WM_CAPTURECHANGED`；窗口间
的正常捕获转换不变。App 在安装环境准备阶段随其他 SOLIDWORKS 兼容设置一次写入开关；日常
启动不再额外拉起 Wine 进程，也不承担已有 bottle 的迁移。

## 排除项

- 停用 UI 守护程序只能消除它对轮盘窗口的额外干扰，不能结束已经创建的模态对话框。
- `HKCU`/`HKLM` 的 `EnableSldLoginManager=0` 不能阻止缺失提示。
- `SW_Login_Disable=True` 只能关闭 3DEXPERIENCE 登录入口；实测仍会出现 Login Manager
  未安装提示。
- 官方 2025 安装编排在选择 SOLIDWORKS 时会同时安装 `SWLoginMgr`。当前 App 直接执行
  `swwi/data/solidworks.msi`，因此绕过了该前置组件。

## App 集成

- Builder 从微软官方 NuGet 包下载并校验 `stdole 7.0.3300`，并下载匹配的 Wine-Mono
  `mscorlib.dll` 与 x86/x64 托管 RegAsm。App 在安装前校验整套运行时，把依赖放到
  `SOLIDWORKS Shared`，安装 RegAsm 入口，并静默运行介质中的 Login Manager MSI。
  主 SOLIDWORKS MSI 继续使用官方交互窗口。2026-09-13 使用重新打包的 App 清理旧 bottle
  并完成干净安装端到端回归，新 bottle 生成真实 COM 注册项，随后启动 SOLIDWORKS 未再
  出现缺失弹窗；该结果不依赖此前手工注册残留。
- UI 守护程序不再隐藏 Login Manager 致命对话框，避免把阻塞状态伪装成成功启动。
- Builder 从固定 Wine 源码同时重建 `winemac.so` 和 `win32u.so`；包内清单记录两份补丁与
  两个模块的校验值，App 安装时写入 SOLIDWORKS 应用兼容开关。
- 鼠标手势轮盘的黑色背景是独立的屏幕背景读取问题，原因与修复见
  [调查记录](mouse-gesture-background.md)。

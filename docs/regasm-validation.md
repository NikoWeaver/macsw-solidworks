# Wine-Mono 托管 COM 注册验证

## 根因

SOLIDWORKS 主 MSI 与 Login Manager MSI 都会调用 .NET Framework 4 路径下的
`RegAsm.exe`。Wine 11.16 归档中的同名程序不执行程序集注册，因此安装日志中的退出码
不能作为 COM 注册成功的证据。SOLIDWORKS 启动时找不到
`sldLoginManager.LoginManager`，便显示 Login Manager 未安装的致命模态对话框。

官方 .NET Framework 4.8 RegAsm 也不能直接替代：它在 Wine-Mono 上会进入尚未实现的
注册路径。最终修复由相互匹配的 Wine-Mono 组件组成：

- 修复 x86 P/Invoke/stdcall 的 `libmono-2.0-x86.dll`；
- 实现 `RegistrationServices` 的 `mscorlib.dll`；
- 调用该实现的托管 `regasm-x86.exe` 与 `regasm-x86_64.exe`。

这四个文件由 prerelease
`wine-mono-11.3.0-X86StdcallFix-ComRegistration-v2` 提供，Builder 对每个文件执行
SHA256 校验，再覆盖 App 中对应的 Wine-Mono 文件及 Wine RegAsm 入口。

## 上游验证

x86 stdcall 与 COM Registration 补丁均移植到 Wine-Mono 11.3.0 使用的 Mono 基线。
新的 x86 DLL 由 Wine-Mono CI 提交 `a1f68cd224f38b6c636953b1cec2193e0b5c3448`
构建；其余托管注册组件沿用上一轮已验证的同源构建结果。发布与 Builder 校验值仅使用
各自 prerelease 中的固定文件。

## SOLIDWORKS 实机验证（2026-09-13）

在全新正式 bottle 中，原自动安装虽然到达成功页面，但启动仍出现 Login Manager
未安装提示。检查发现注册表没有真实 CLSID；带 `+mscoree` 日志运行安装时的入口后，
确认它没有加载托管 RegAsm。

将同一次已通过 CI 的 `mscorlib.dll` 与 x86/x64 RegAsm 装入 App 和正式 bottle 后，使用
x64 RegAsm 重新注册：

```text
C:\Program Files\Common Files\SOLIDWORKS Shared\LoginManager\sldLoginManager.dll
```

命令退出码为 0，且注册表实际生成：

- CLSID `{69EF7FA2-6705-47CF-AA78-2E4264D24EB3}`；
- `InprocServer32` 默认值 `mscoree.dll`；
- `Class` 为 `sldLoginManager.LoginManager`；
- `CodeBase` 指向真实的 `sldLoginManager.dll`；
- `RuntimeVersion` 为 `v4.0.30319`。

随后使用包含上述同源组件的重新打包 App 清理旧 bottle，并在新建的干净 bottle 中安装。
App 自动完成运行时校验、RegAsm 放置、`stdole.dll` 部署和 Login Manager MSI 静默安装；
安装完成后启动 SOLIDWORKS，未再出现 Login Manager 缺失弹窗。这排除了此前手工注册残留，
确认了 App 自动编排链路，而不只是手工注册命令可用。

因此验收条件是注册表内容以及后续 COM 激活/应用启动结果，不是安装器或 RegAsm 的退出码。
App 会在安装前校验整套运行时并安装两种架构的托管 RegAsm，详细日志为
`Application Support/MacSW/logs/managed-com-registration.log`。

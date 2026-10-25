> **Removed in this fork:** managed FlexNet/lmgrd installation, serial discovery and preloading, and the local license-server checks. Mentions of them below are historical. Licensing is only Dassault activation or a real remote SolidNetWork server (see development.md).

# App-only Wine 11 migration

## 交付与验证

构建：`make app`。输出 `build/app/MacSW.app`，可移动到其他目录；不依赖源码工作区、Homebrew、Python 或外部启动脚本。Apple Silicon 仍需 Rosetta 2。当前是本地测试包，未做 Developer ID 签名与公证。

先正常关闭旧 MacSW App，再打开新 App，在 Bootstrap 窗口选择官方 ISO 或安装介质目录，完成安装并验证启动。最终固定使用一个容器，不提供选择/切换容器功能。

唯一容器为 `~/Library/Application Support/MacSW/bottle`，日志位于同级 logs，含 sw_launch.log、install_msi.log、installer-wine.log、prerequisites.log 等。本轮按用户要求将旧正式容器备份后从空环境验证，不复制诊断容器作为安装结果。

当前已经验证官方安装程序能够完成、主界面能够启动、新建 Part 正常，以及 FeatureManager 在硬件加速视口前保持可见。草图/属性管理器切换、拉伸、旋转、保存并重开仍需继续回归。

## 实现边界

- WineService 仅解析 App 包内的 wine/bin/wineloader 与 wineserver；所有启动入口通过 RuntimeStore 统一执行本地许可服务前置检查与重复启动保护。
- 运行时固定 Gcenx wine-devel 11.16，SHA-256 校验归档；在其上覆盖由 Wine 11.16 官方源码和仓库补丁重建的 `winemac.so` 与 `win32u.so`。App 为 `sldworks.exe` 幂等启用 `WINE_NOCAPTURERESEND`，只抑制同一窗口重复取得捕获时多余的 `WM_CAPTURECHANGED`。
- 安装阶段使用 Mono 11.3.0 x86 修复模块和解释器模式，避免 32 位托管辅助程序在 Rosetta 下进入不稳定的 JIT 路径；64 位 SOLIDWORKS 使用 JIT。
- 启动启用 atiadlxx=d 和微软 VC++ native-first overrides。旧 UI 辅助程序已移除；注册表禁用 Login Manager 的值已确认无效并移除。
- 官方安装：用户选择介质 → 预先校验可选序列号输入 → wineboot → 校验 Wine-Mono COM 注册运行时并安装托管 RegAsm/stdole → 官方 VC x64 安装包 → 后台安装官方 Login Manager MSI → 可选写入文本序列号或原样导入已确认的注册表 → 可见的 SOLIDWORKS 官方 MSI（禁止回退并记录日志）→ 五个 WPF 主题库。组件和语言不再由 Swift 猜测、解包或注入。
- 安装任务可取消；取消只终止当前受管子进程，不默认终止整个 Wine server，且不会写入完成标记。全新安装在删除容器前验证所有输入都位于容器外。
- App 不提供替换 SOLIDWORKS 官方文件的功能。托管 FlexNet 只从设置页显式安装，验证后原子复制到 `C:\\opt\\FlexNet`；服务器列表以官方 `port@host` 保存，并保留用户配置的其他服务器。
- 安装失败仍会报告非零退出码并可显式清理不完整容器。Toolbox 数据库和剩余字体问题仍需单独验证。
- 删除 CAB 直接部署服务、介质组件扫描服务、相关测试、旧 run_sw.sh 和未使用的重复 LicenseService；历史可从 Git 恢复。开发诊断脚本仅留在源码，不随 App 运行。

## 既有容器的运行时升级与恢复（2026-10-10）

设置 → 维护提供 Wine 版本管理。SWCLI backend 同步只替换 Windows Python
目录；本功能独立处理 Wine、Mono、补丁及 App 位置变化，不能互相代替。

- 文件预检覆盖 `BuildManifest.plist` 的 Wine / Mono 字段（包括补丁与关键模块哈希），
  并记录 App 实际路径及容器 UUID。首次升级旧容器需要用户明确记录当前已知可用版本；
  不用 `reg query` 或 `wineboot` 探测版本，以免探测本身更新容器。
- 版本不匹配或有未完成迁移时，字体检查、SOLIDWORKS、Wine 工具与 Windows CLI
  入口均阻止启动新版 Wine。App 与 CLI 的预检＋启动共用文件锁，迁移期间也阻止
  wineserver 清理动作竞争。原生 CLI 与已有 daemon 的网络查询不启动 Wine。
- 用户确认已保存文档后，停止**选定容器**，保留完整旧 App、容器数据和注册表。
  同卷用 APFS clone；跨卷先检查实际所需空间，再用 `ditto` 复制。无法备份就不开始迁移。
- 显式执行 `wineboot -u`，重新绑定 Mono RuntimePath、放置校验过的 x86/x64 RegAsm，
  检查 SW COM 注册键、Windows Python 的 pythoncom/win32com/swcli 导入以及 Tahoma 字体链接。
  完成后仍需用户验证 SOLIDWORKS 打开、建模、保存与重开，不能将依赖检查称为 CAD 全面验收。
- 失败则保留失败容器，恢复升级前副本，并用归档旧运行时修复内置 DLL 链接和 Mono 路径。
  新 App 随后保持版本阻断；按提示退出它并打开归档旧 App。恢复失败或进程中断时保留
  journal 与备份，维护页可重试恢复。依赖检查成功但实际使用异常，也可选择“回退上次升级”。
  **回退恢复的是升级前快照，升级后新增的容器内设置/文件留在 failed-bottle，需自行取回。**
- 完成安装后归档并记录版本。固定主容器及已建立身份记录的诊断容器受管理；
  高级 CLI 指定、从未建立记录的自定义容器仍由调用者负责其升级，不隐式接管。

主容器状态与保留内容在 `~/Library/Application Support/MacSW/.bottle.wine-runtime/`：
`receipt.json`、`pending.json`（仅迁移未完成时存在）、`last-upgrade.json`、
`migration.log`、`apps/<Wine 身份>/MacSW.app` 和 `backups/<UUID>/bottle`。
不会自动清理 App、容器备份或失败副本。不要修改 journal 路径或在迁移中手动启动旧 App。

本地验证包含原有与修改后的 Wine 11.16 **真实补丁差异**迁移、主动回退、实际 wineboot
之后的失败注入与恢复/重试，以及同版本 App 搬位置后的重新绑定。主容器只建立可用版本
基线，本轮没有改变 Wine / Mono 版本。真正的新 Wine / Mono 版本兼容性仍须将来逐次验收。

## 本地检查

SwiftPM 编译与测试：

```bash
make launcher
make test
```

XCTest 覆盖序列号分区解析与 Security 拆分写入、介质同级及向下一层文件发现、多服务器规范化和本地地址合并/移除、FlexNet 包结构、安装子进程取消、Wine-Mono COM 注册运行时哈希校验与 RegAsm/stdole 原子放置、环境隔离、原生 VC 加载策略、含空格/单引号路径的 shell 转义和进程启动错误。SW GUI 由用户验证，以上检查不能替代建模验收。

## 正式单容器首次安装反馈（2026-09-11）

用户通过 App 完成了一轮官方安装操作并启动 SW，但安装器仍显示中断，SW 停在许可证错误，并未完成主界面验收。

- install_msi.log 的 SWRegistration 阶段调用 Framework64/v4.0.30319/regasm.exe 时 CreateProcess 失败，返回 0x643；DISABLEROLLBACK 和 RollbackDisabled 均为 1。
- 当时的 ui-daemon.log 确认旧 UI 辅助程序已启动 watch 模式；现已从 App 移除。
- 当前安装后的逻辑只补齐 WPF，不调用 applyComponentPatch/startLicenseServer。选择维护目录不代表已执行维护操作，用户对自动执行的预期尚未满足。
- 只读比较确认正式安装目录的 sldutu.dll、swsecwrap.dll 与用户所选组件目录中的文件不一致。
- 截图错误为 Invalid (inconsistent) license key (-8,544,0)；本机 25734 端口连通。尚未确认具体许可配置不一致的原因，不据此断言服务未启动。

此阶段提交保存 App-only 重构与官方安装链路，不代表完整安装、许可或建模验证通过。

## 安装与图形里程碑（2026-09-12）

- 修复后的 Wine-Mono x86 模块配合安装阶段解释器模式，使官方 SOLIDWORKS 2025 SP5 安装向导正常到达成功页面。
- SOLIDWORKS 主界面及新建 Part 已在唯一正式容器中启动。
- Wine `winemac.drv` 现在把 Win32 `SYSRGN` 转为视口 Core Animation 图层遮罩。实测 3D 窗口保持 SOLIDWORKS 原始几何，遮罩可见区从 FeatureManager 右缘开始，左侧树不再被视口覆盖。
- 当时曾以原生 x64 Win32 辅助程序替换 C# 守护程序；现已移除整个 UI 守护程序，窗口层级与离屏窗口需在无守护程序的 App 中回归。

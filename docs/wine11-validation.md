# Wine 11.16 隔离验证（2026-09-11）

## 环境与复现

- Gcenx `wine-devel-11.16-osx64.tar.xz`，官方发布 SHA-256：
  `6f9af818b7af6001aeed7818cb32bf0155598c5ea4e3b33380a03cf814e033cd`，下载后已校验。
- 解包到 `dist/wine-devel-11.16/`，实际 `wine --version` 为 `wine-11.16`。
- 包中只有 `bin/wine`，测试环境增加 `bin/wineloader -> wine`，显式设置 WINELOADER / WINESERVER。
- `prefixes/sw-wine11-baseline` 是原 MacSW bottle 的独立复制，未使用硬链接；跨卷 APFS clone 不可用，改用普通复制。
- `prefixes/sw-wine11-official` 是官方 MSI 使用的全新环境。
- 复现入口：`bash scripts/wine11_probe.sh init|launch|installer`。
- 运行时与 prefix 均为忽略的本地测试产物，未替换 MacSW.app 中的 GPTK。

## 已验证结果

1. 初始化副本后 `cmd /c ver` 成功返回 Microsoft Windows 10.0.19043。
2. 无 DLL override 启动 SW：未实现的 `atiadlxx.dll.ADL2_Adapter_Primary_Get` 导致崩溃。
3. 只增加 `atiadlxx=d`：通过前述错误，随后在 `sldworks.exe` 地址 `0x14000d9ca` 读取 `0x2c8` 时访问冲突。
4. 再增加原生 VC++ DLL override：复现相同访问冲突，未证明是 VC++ 内置实现导致。
5. 未开启 UI daemon，未配置 D3DMetal / DXVK 或覆盖 mscoree。不能将以上失败归因于图形后端或仅归因于 Wine 7.7。
6. 本机 `ngp_graphics.dll` 导入 OPENGL32 / GLU32；`sldappu.dll` 也导入 OPENGL32。尚未验证运行时模型视口。
7. 官方 `swwi/data/solidworks.msi` 已通过 wineloader 启动。用户截图确认进入 SOLIDWORKS 2025 SP05 Setup 的 Destination Folders 页；默认程序目录是 `C:\Program Files\SOLIDWORKS\`。这仅证明向导能运行，尚未证明安装成功。

## 日志

均位于 `scratch/wine-baseline/`：

- `wine11-init.log`
- `sw-wine11.log`
- `sw-wine11-no-adl.log`
- `sw-wine11-native-vc.log`
- `official-wine.log`
- `official-msi.log`

## 下一步

后续安装对照补充：已按用户指定向 official prefix 导入安装前注册表，验证 SolidWorks 序列号键存在。序列号值不写入本文。

第一次正式安装未带原项目已有的 `DISABLEROLLBACK=1`，这是本次诊断脚本遗漏，现已补齐。原实现位于 WineService.swift，最早出现在提交 `349bb64`。失败日志已保留为 `scratch/wine-baseline/official-msi-with-rollback.log`。

Wine 日志明确记录 `Register_DocMgrDLL.A48C1CF2_EBF8_48E8_ACAD_68CA04F776A2` 返回 1627，导致 InstallFinalize / ExecuteAction 失败；随后执行回退，回退中的 `RollbackUnReg_DocMgrDLL...` 也返回 1627。1627 是自定义操作失败结果，还不能解释该 DLL 注册失败的底层原因。

已重新通过 wineloader 打开带 DISABLEROLLBACK=1 的官方向导，等待继续安装。该参数只能保留失败后的现场，不代表失败后的组件已完成注册。

进一步查看失败动作前的 Wine 日志，明确发现 `swdocumentmgr.dll` 依赖的 `mfc140u.dll` 未找到，随后 regsvr32 报加载失败。这次直接运行 MSI 绕过了 VC++ 前置安装。已在 official prefix 运行介质 `PreReqs/VCRedist17/VC_redist.x64.exe /install /quiet /norestart`，进程退出码为 0；独立日志为 `scratch/wine-baseline/vcredist-x64.log`。

## 补齐 VC++ 后的安装与首次启动

- 本轮 `official-wine-registry-retry.log:2290` 确认 swdocumentmgr.dll 注册成功。
- `official-msi.log:1898` 起，安装器调用缺失的 Framework64/v4.0.30319/regasm.exe 注册 gdtanalysis.net.dll，CreateProcess 失败，SWRegistration 返回 1603。DISABLEROLLBACK / RollbackDisabled 均为 1，文件保留。托管组件注册未完成，不能算完整安装。
- 子代理只读分析还发现 VENOpenXR.dll 缺失相关加载错误，后续单独核查；它并非本次安装最后停止的动作。
- 增加 `bash scripts/wine11_probe.sh launch-official`，从 official prefix 的 `C:\Program Files\SOLIDWORKS` 启动，只有 atiadlxx=d，不使用 UI daemon / D3DMetal。
- 首次启动日志 `scratch/wine-baseline/sw-official-first.log`：未复现旧 CAB 副本的 0x14000d9ca 访问冲突；已经加载 swactwiz.exe 激活向导。尚未验证主界面、模型视口和建模操作。
- 其他日志信息包括 libodbc.dylib 缺失与一个 COM 类未注册；尚未证明它们是当前启动阻塞点。

完成官方安装后，从 official prefix 中的实际安装路径验证启动，再测试新建零件、草图、旋转及保存。诊断脚本的 launch 当前只针对旧安装副本。

当前 CAB 解包器没有完整按 MSI File / Component / Directory 表恢复布局，现有安装含大量 MSI 标识后缀文件；这是一项独立风险，不能靠升级 Wine 修复。尚未证明它就是访问冲突的根因。

上一轮提到 D3DMetal 搜索路径可能缺失，仅是静态推测，尚未做动态加载验证，不应作为已确认故障。GPTK 包的 Wine 7.7 与 D3DMetal 3.0 可以同时存在，不表示下载错版本。

## 官方安装环境的 WPF 主题库补齐

- 启动画面后退出的直接证据在 official prefix 的 `AppData/Roaming/SolidWorks/SOLIDWORKS 2025/SolidWorksPerformance.log`：`FeatureWPF.LoadFeatureWindow_c` 创建时无法加载 `PresentationFramework.Luna, Version=4.0.0.0`。
- 这是新测试环境遗漏了已有部署步骤。`AppState.extractAndInjectWpfThemes()` 和提交 `00695af` 已有对应处理，`WizardView.swift:392` 串联该步骤。
- 参照 Swift，从官方安装介质 .NET 4.8 包提取 Luna、Aero、Classic、Royale、AeroLite 五个主题库，复制到 official prefix 的实际 SW 主目录，再硬链接至 `windows/Microsoft.NET/Framework64/v4.0.30319/WPF`；十个目标文件逐一与提取源比较一致。未修改原用户 bottle 或共享 Wine-Mono。
- 修复后的启动日志为 `scratch/wine-baseline/sw-official-wpf-fixed.log`。补齐主题库不等同于解决安装期间 regasm 缺失，仍需独立验证运行结果。
- 上述日志第 4292 行确认 Luna 成功加载；第 4332 行明确因 Wine 内置 `concrt140.dll.?GetProcessorCount@Concurrency@@YAIXZ` 未实现而中止。之前的锁超时不能作为最终退出原因。
- 诊断脚本补回 `WineService.launchSolidWorks` / `run_sw.sh` 已有的 VC++ native-first overrides；继续保留 Wine 11 自身的 mscoree 和图形实现。新一轮日志为 `sw-official-wpf-native-vc.log`。

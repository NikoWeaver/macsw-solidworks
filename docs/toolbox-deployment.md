> **Removed in this fork:** managed FlexNet/lmgrd installation, serial discovery and preloading, and the local license-server checks. Mentions of them below are historical. Licensing is only Dassault activation or a real remote SolidNetWork server (see development.md).

# Toolbox 标准件部署（2026-10-10）

## 路径输出分流修复（0.1.2，2026-10-23）

另一台电脑在主 MSI、语言包和 WPF 主题完成后报“无法解析已配置的 Toolbox
数据目录”。原实现把 `winepath -u` 的 stdout 和 stderr 拼接成路径；即使命令
退出 0、stdout 路径正确，只要 stderr 有诊断信息，也会被多行路径检查拒绝。
收到的日志未记录该次 winepath 的原始输出，不能断言这是远端故障的唯一原因。

现改为只解析 stdout，仍要求退出 0 和单行绝对路径，并拒绝嵌入的 CR、LF、NUL
及解码替换字符。退出码、原始 stdout、stderr 和时间保存在独立的
`logs/toolbox-path.log`；每次转换覆盖旧记录，避免把上一次尝试当作本次证据。
非零退出码不会因输出看似路径而被忽略。后续数据库、标准配置、来源包、官方
更新器、索引及每个启用标准的模型校验保持不变。CI 安装日志白名单同时收集
`toolbox-path.log` 和 `toolbox-install.log`，仍经过既有证据脱敏流程。

本地使用本次 Core 源码和现有 Wine/容器、用户提供的只读官方 SP5 ISO 运行安装
阶段探针：真实 winepath 附加 stderr 诊断后仍正确解析目录，官方更新器退出 0，
索引及 1,844 个原生零件校验通过。Swift 202 项、Python 297 项（跳过 1 项）通过。
这不是本地全新安装，也不是正式签名包的验证；本次未删除主容器或替换主 App。
远端原始故障、特殊主机名电脑的后续 FlexNet 阶段及正式包验证仍需分别确认。

## 原安装状态

主容器的 Toolbox 程序、COM 注册和 SQLite 数据库都存在。用户与机器配置均指向
`C:\SWData`，`lang/english/swbrowser.sldedb` 的只读 `PRAGMA quick_check` 返回 `ok`。
但该目录只有数据库、`ToolboxStandards.xml` 和 `ToolboxVersion.dat`，没有 Browser
标准件模型与 `ToolboxFiles.index`。这不是完全未安装，也不是数据库文件缺失。

官方说明指出 Toolbox 根目录应包含 Browser 与 lang 两个目录：
[设置 Toolbox 根目录](https://help.solidworks.com/2025/english/SolidWorks/toolbox/t_toolbox_setting_toolbox_root_folder.htm?id=33.1.0.2)。

## 原因及同二进制对照

MSI 已执行 `sldtoolboxupdater.exe <数据目录> <介质Toolbox目录> TRUE`，但日志中
工具退出码是 `0x1`；外层 `WIDll_SldToolboxUpdater` 仍报告成功，因此 App 的 MSI
退出码检查没有发现标准件缺失。对应 Wine 日志显示 WPF 在构造 Application/
Dispatcher 的消息窗口时抛出 Win32Exception「该类不存在」，尚未进入解包。

在数据库副本、同一官方工具和同一介质上，仅改变 `WINE_MONO_AOT`：

- `interp`：退出 1，0 个零件，复现同一 WPF 窗口创建异常。
- `none`：退出 0，生成官方索引和 19 套标准的 1,818 个原生零件。

这是解释器与该 x64 WPF 工具启动路径不兼容的对照证据，不是某个 Wine API 或
Mono 源码函数的根因定位。未改写 SOLIDWORKS 程序，也未自行解包/拼装数据库。

## App 安装流程

`ToolboxService` 在主体 MSI、语言包和五个 WPF 主题库完成后，独立运行官方更新
工具，仅为这个进程设置 `WINE_MONO_AOT=none`。其他安装/RegAsm 进程仍走解释器。
读取官方注册的 Toolbox 数据目录，不固定 SOLIDWORKS 年份；用户覆盖优先，多个
不同目录时拒绝猜测。Windows 路径通过该容器的 winepath 解析，介质使用实际映射。

运行前检查数据库、标准配置和所选 ZIP，运行后既要求退出 0，又要求非空官方索引
及每个启用标准的原生模型。失败不写安装完成标记，日志单独保存为
`logs/toolbox-install.log`，取消沿用原有安装取消/容器收尾流程。不在日常启动时
重新部署标准件，也不覆盖用户的数据库或更改其标准选择。

Toolbox 载荷在介质上是可选的（体积大，可以先不拷）：开装前只校验核心 MSI、前置件
和所选语言，`Toolbox/*.zip` 缺失不算介质不完整。`BootstrapStore` 在挂载后用
`InstallationMedia.hasToolboxPayload(in:)` 判断：没有 `Toolbox` 文件夹、或文件夹里
没有非空 ZIP 时不运行 `ToolboxService`，该步骤记为“有警告”，安装完成页的“安装提示”
显示“Toolbox 未安装”一行。主体 MSI 的属性不变：当前 `ADDLOCAL` 没有列出 Toolbox
特性，`TOOLBOXFOLDER=C:\SWData` 照常传入；缺载荷时 MSI 内的 `WIDll_SldToolboxUpdater`
找不到介质 Toolbox 目录，按上文，它的失败本来就不影响外层 MSI 退出码。尚未用真实的
无 Toolbox 介质验证这一点（**[UNDETERMINED]**），首次实装时看 `install_msi.log`。
之后补装：把 `Toolbox` 文件夹拷回介质，`ToolboxService.install` 的前置条件（官方
数据目录、`ToolboxStandards.xml`、所选 ZIP）不变；目前没有单独的补装入口。

## 本机验证与未完成边界

共享 `Dependencies/SWCLI/scripts/ci/verify-toolbox.py` 门禁已接入 MacSW CI：每个
可见／隐藏模式在建模和驱动尺寸之后、同一 daemon/SOLIDWORKS 宿主中运行。
它从本轮隔离容器的真实注册表和映射发现数据目录，检查完整标准配置、官方
索引、模型与数据库，再用公共 CLI 只读打开、诊断、测量和关闭代表件；不重建、
不保存，也不修改主容器。数据缺失不能静默跳过，外层预算为每模式 600 秒。
接线的离线测试不代表真实运行已通过；安装与运行 CI 的顺序、证据和预算见
[运行验证说明](runtime-ci.md)。

主容器通过官方工具修复前保留完整 SWData 副本；实际退出 0，索引生成，19 个
启用标准均有模型（GB 330、ISO 140，总计 1,818）。重新打包校验并替换主 App，
保留旧 App；Wine、Mono、补丁身份不变。

主 SOLIDWORKS 33.5.0 的实际 COM 冒烟已加载 SwToolbox/SwBrowser（均返回 0），
只读打开 GB 六角头螺栓：OpenDoc6 错误 0、警告 2，模型非空、1 个实体，配置
为 Default/PreviewCfg。
警告 2 仍保留在证据中，不把只读打开称为完全无警告的规格/装配体验验收。

Swift 164 项、Python 169 项（跳过 1 项）、CLI 路由检查和成品校验通过。
本轮没有重跑全新安装；新增安装步骤有离线回归和相同官方命令的真实运行证据。
规格选型、拖入装配体、生成配置和保存重开仍需 GUI 验收，不能由文件存在或原生
模型能打开代替。

诊断过程中保留两个与标准件部署修复无关的发现：主 App 的进程名启发式会将其他
隔离实例误认作主实例；独立启动探针必须设置 SOLIDWORKS 工作目录。后者已修正
诊断命令，正式启动代码本来已有工作目录。进程归属逻辑已在随后独立修复，见待办。

## GUI 配置确认与 CCW 原型（2026-10-10）

以下测试仅使用主容器内的独立 SWData 副本，不把已有标准件文件改成测试夹具。

用户多次手动拖入尚未生成配置的 GB 螺栓，打开“配置零部件”，点击绿色对勾时
SOLIDWORKS 退出。既有配置的“选择配置”对话框不是同一条路径，不能代替复测。
已加载的 SwToolbox、SwBrowser、sldtoolboxdata 和 sldtoolboxconfigureaddin 均由
进程模块清单确认，不以设计库能展开推断插件成功加载。

原始 Wine-Mono 在 `cominterop_ccw_release_impl` 断言 `ccw->ref_count > 0`。
引用计数跟踪识别出 `sldtoolboxdata.ToolboxFile`，计数先从 2 降至 1、再到 0，
随后 SW UI 析构路径仍调用 Release；原生栈含 `slduiu.dll+0xc08aef`。
这证明触发点是零引用 CCW 的多余 Release，不是用户关闭应用或仅未加载 Toolbox。

Windows VM 的 .NET Framework 最小对照实测：Release 至 0 后再次 Release 返回 -1，
并且仍活着的托管对象可以再次 AddRef 至 1。CLR 实现也有零计数保护：
[SimpleComCallWrapper::Release](https://github.com/dotnet/runtime/blob/main/src/coreclr/vm/comcallablewrapper.h)。
这只适用于对象尚未被回收的情形，不能使悬空 COM 指针合法。

正式源码修复见
[共享 Mono 提交](https://github.com/YJBeetle/mono/commit/edc3bfecdcb5c1c4705bdc9b82257d1d35143f06)：
零计数时返回 -1，不做减法，也不改弱 GC handle；其余情况用原子 CAS 递减，原有
1→0 的强引用转弱引用行为保持不变。没有加一条永久 AddRef 或关闭垃圾回收。
本地原型基底为 `YJBeetle/mono@764c7bd0f9e3fc4f92e72e19472cd8a57cef9eaa`；
共享版本改为基于已有 v3 的 Mono 提交 `04226a35017ea035f09a109a728490055d1493f6`，
保留既有 x86 stdcall 与 COM 注册修复，不以旧原型源码替换共享基底。

回归探针为 [mono_ccw_release_probe.cs](../native/mono_ccw_release_probe.cs)。它覆盖
正常减引用、两次零计数 Release、重新 AddRef 和再次 Release，最后输出
`CCW_RELEASE_PROBE_PASS`。运行门禁必须同时检查完整标记、没有断言及退出码，
因为本机原始 Mono 断言进程竟返回 0。源码构建版完整通过，原版在第一次多余
Release 处断言；此前 Windows 对照覆盖一次多余 Release，新探针的 Windows
重跑因 VM 命令超时尚未形成新证据。随后共享版本的 Windows CI 已在原生
.NET Framework x86／x64 上通过完整七项对照，包括两次多余 Release 和重新 AddRef。

临时内存 detour 曾避开断言但随后失去响应，不作为可部署方案。随后不带 detour
的独立源码构建实例由用户手动确认正常，并读取到 7 个组件、4 类 GB 螺栓，引用
M8×45、M6×25、M5×30 配置及非空实体。结束重复插入后保留 6 个组件。

这一阶段的 DLL 仅从临时 Mono 副本加载，随后恢复 RuntimePath；原型构建禁用了
BTLS，用户确认只证明原型 GUI 路径。后续正式构建及打包验证见下文，不能将两者
混为同一次主 App 验收。

### 独立的保存失败

对勾正常后，用户将装配体另存为桌面 `123.SLDASM`，SW 提示“保存文档失败”，
实际文件为 0 字节。第一次 API 保存发生在仍有“插入零部件”命令的状态下，调用
超时并出现 Mono 原生异常日志；不能由此认定绿色对勾仍卡死。结束插入后 API 可
立即返回，但保存错误码为 1，文件仍为空。源码候选中的新空白装配体同样失败。

退出候选、恢复原版 Mono 并启动新进程后，模块清单确认加载主 App 原版 DLL；
同一模板的新空白装配体仍返回 1、生成 0 字节文件，证明保存失败独立于本次 CCW
修改。用户的桌面测试文件没有删除或覆盖。

随后捕获到 `sldmoasmu.dll+0x23dd6` 的空指针读取：官方 XML 验证函数返回失败且
原因字符串为空，SW 失败分支对该字符串计算长度。SW 使用 SchemaCache60，将
未声明 `targetNamespace` 的官方 `sw2005plusSchema.xsd` 加到
`http://www.solidworks.com/sw2003/schema` 下；Wine 未将它绑定到该命名空间，
导致实际保存 XML 验证失败。单独捕获原始 XML、官方 XSD 后可脱离 SW 复现。

[MSXML 补丁](../patches/wine-crossover/0014-msxml-schema-cache-namespace.patch)
仅在缓存的私有 DOM 副本上绑定无目标命名空间的 XSD，并调整需要绑定的未限定
QName；保留已有命名空间、局部 form、XPath 和调用者的原始 DOM。没有禁用验证，
非法整数仍须拒绝。回归探针
[msxml_schema_namespace_probe.c](../native/msxml_schema_namespace_probe.c)
覆盖七种有效／无效、空命名空间、显式目标命名空间和 QName 作用域情形。
V2 源码构建候选与 Windows 原生 MSXML6 均通过全部七项；真实 SW 捕获的 XML
也验证成功。最终补丁额外加固属性命名空间和分配失败处理，对应正式二进制及
打包产物已经重新通过全部七项，不将 V2 的证据直接代替最终产物回归。

仅替换 MSXML 的隔离运行时中，新空白装配体保存错误码 0、文件 35,664 字节，
关闭重开错误／警告均为 0。联合 CCW 和 MSXML 候选中，用户手动配置、确认新规格
不再崩溃；保存前 `GetRunningCommandInfo` 明确返回 `ui_active=false`。
三个组件的装配体保存错误码 0、文件 120,580 字节，关闭重开错误码 0、警告码 2
（本机官方类型库确认为 `swFileLoadWarning_ReadOnly`，不是配置丢失警告）。
配置名、组件名、路径身份、实体数及实体包围盒保持一致；路径按 Windows 的
大小写规则比较，实体顺序不作为身份，包围盒绝对容差为 1e-10 米，实测最大差值
仅 8.67e-19 米。原始 SWData 文件哈希复核没有变化。

用户另报仅 Toolbox 这一步 Esc 没有可见反应，草图 Esc 正常；当前读到空闲状态，
不足以区分先前按键未处理与当时已经没有可取消的动作，不能记作全局快捷键故障。
2026-10-11 用户随后实测插入螺栓时 Esc 已有效，并明确决定关闭这项调查，
将此前现象视为偶发。本次关闭基于用户实测与决定，不代表已查明原因或证明
CCW 修复改变了 Esc 行为，也未新增按键补丁。

### 正式构建与打包门禁

此前本地构建器使用固定提交和 SHA256 校验的源码构建 x64 Mono 引擎，
保留 `HAVE_BTLS=1`，复用固定 Wine 包中未改动的 BTLS DLL 和托管库；不发布此前
禁用 BTLS 的原型。源码、补丁、构建脚本、生成 DLL 及 BTLS DLL 的身份写入
BuildManifest，并由打包和成品验证检查；容器升级身份也纳入这三个新模块。
App 附带对应 Mono 源码来源和许可证。诊断探针不进入最终 App。

正式构建时曾发现嵌套源码目录中的 `git apply` 继承主仓库而跳过补丁；探针即使
退出码为 0，仍因缺少完整通过标记而拒绝产物。当时构建器改为初始化独立临时 Git
目录，应用后检查零计数分支，再构建引擎；该修正后的 DLL 完整通过 CCW 回归。

候选 App 的内容／哈希校验通过。`scripts/ci/verify-toolbox-native.py` 在全新、
一次性的独立 Wine prefix 中使用实际打包产物完成 wineboot、编译并运行三个
原生探针：MSXML 七项、CCW 七个引用计数检查，以及 BTLS 提供器初始化和本地
证书解析均通过。BTLS 探针确认真实原生 DLL 已加载，不代表远程 TLS 握手或
信任策略测试。CI 在上传 App 前运行相同门禁；上述本地原型构建阶段尚未推送，
当时没有声称远端 CI 通过。后续共享版本的 CI 结果见下节。

这些是运行时原语及打包验证，正式主 App 的新规格 GUI 确认、保存／重开仍需单独
验收，不能只凭最小探针宣告整个 Toolbox 完成。

主 App 已安装这份正式产物，主容器通过现有升级流程完成备份、wineboot、Mono
RuntimePath／RegAsm 更新及 COM、后端导入、字体依赖检查；回退 App 和原容器保留。
重启后确认 SW 加载主 App 的 x64 Mono。测试命令曾早于托管 FlexNet 就绪启动 SW，
产生许可连接错误；确认许可服务和 vendor 端口都可连接后重新启动成功，没有改
许可证或许可服务器配置。

正式主实例使用独立数据副本保存三个 Toolbox 组件：保存错误码 0、文件 120,323
字节；关闭重开错误码 0、只读警告码 2，组件名、配置、实体数和包围盒核验通过，
实测包围盒最大差值为 0。全量离线测试通过：Python 186 项（跳过 1）、Swift 173
项、SWCLI 1109 项（跳过 8）。

2026-10-11 用户随后在同一正式主实例手动配置并确认新规格，明确反馈绿色对勾
正常、没有崩溃。读取到五个组件、四类 GB 螺栓，配置为 M3×20、M5×25、M8×1×45
及 M8×1×40，每个零件均有非空实体。确认后的命令状态为 `ui_active=false`。
这份装配体保存错误码 0、文件 174,664 字节；关闭重开错误码 0、只读警告码 2，
五个组件的配置、实体数与包围盒核验通过，最大差值仅 4.34e-19 米。
最后关闭已保存测试文档，恢复主路径 `C:\SWData\lang\english`，主 SW 保持运行。
该证据闭合配置、确认、保存及重开路径，不扩展为所有标准件或 Esc 行为已验证。

回归时发现恢复主 Toolbox 路径会使 SW 自动把已保存测试装配体的标准件引用映射
回主库，并生成两份配置。路径边界断言阻止该轮保存，改用独立副本后回归通过。
那两份主库文件已从哈希匹配初始基线的升级前备份恢复，保留只读权限；完整
SWData 文件哈希复核再次为无变化。后续夹具重开时必须保持副本路径，不能提前
恢复主路径。

### 共享 CCWFix 版本接入（2026-10-11）

不再使用 MacSW 的本地 Mono 构建器或本地 CCW 补丁，改为下载
[共享 CCWFix Release](https://github.com/YJBeetle/wine-mono/releases/tag/wine-mono-11.3.0-X86StdcallFix-ComRegistration-CCWFix)
中已由 CI 构建的双架构引擎、mscorlib 与 RegAsm。所有文件和源码归档均由
`config/versions.env` 固定 SHA256；App 继续携带源码来源和许可证。
Mono 源码为 `edc3bfecdcb5c1c4705bdc9b82257d1d35143f06`，Wine-Mono 集成为
`eb8d3270298d2d59f7e304d23e6af0ff374f4559`，以现有 v3 为基础。

共享版本的 [双架构引擎门禁](https://github.com/YJBeetle/wine-mono/actions/runs/38078186166)、
[Windows CLR 对照](https://github.com/YJBeetle/wine-mono/actions/runs/38078186208) 和
[COM 注册集成门禁](https://github.com/YJBeetle/wine-mono/actions/runs/38078186212)
均在同一集成提交通过。x86 保持 v3 的 BTLS-disabled 配置，x64 保留现有
BTLS 支持；不修改 `System.dll`，x86 BTLS 调查延后。

MacSW 全量离线测试：Python 193 项（跳过 1）、Swift 174 项、SWCLI 1227 项
（跳过 14）通过。候选 App 的 bundle／模块哈希／许可证校验通过，实际打包
运行时在一次性 prefix 中通过 MSXML、CCW、x64 BTLS 三个原生探针。
诊断源文件只参与 CI，不进入 App，也不在日常启动时执行。

主 App 已替换，并通过正式升级流程完成原容器备份、wineboot、Mono
RuntimePath／RegAsm 绑定和依赖检查；旧 App 与容器备份保留。备份标识为
`22f312f5-7bb0-46aa-90cc-b8d7ae4fbd1c`。新的主 SOLIDWORKS 已通过可见 daemon
启动和空文档列表读取，COM 宿主 PID 为 420。现有许可配置未改动。
这是新共享包的启动及运行时原语验证，本次未重跑手动 Toolbox 配置确认或
完整装配体保存重开，不将此前 GUI 证据冒充为这次新包的实测。

# DatabaseConverter 安装停滞调查

## 当前正式安装现场

2026-09-11 的 install_msi.log 显示 SWRegistration 和
WriteToolboxStandardsXML 已通过。18:01:24 进入 UpdateBrowserData 后，安装器
等待 DatabaseConverter.exe 处理 C:\SOLIDWORKS Data\lang\english\SWBrowser.mdb。
调查时进程已运行约 18 分钟，CPU 约一个核心。正式容器仅有
SOLIDWORKS Data/ToolboxStandards.xml，没有 lang/english 目录。
调查没有终止或修改正式安装进程。

## 静态检查与最小对照

转换器 IL 的 CorFlags 为 0x3（ILONLY、32BITREQUIRED），引用 WinForms、
OleDb 和 System.Data.SQLite。入口先初始化 WinForms，再检查输入路径；
目录不存在时跳过该输入，最后退出。因而缺少目录本身不能解释持续高 CPU。

macOS 线程采样有大量 Rosetta exceptionserver 活动，但符号不完整，不能
据此确定具体异常或 CLR 函数。

在独立 scratch/app-runtime-smoke 容器，用 App 内 Wine 11.16 / Mono 11.3.0
编译并运行同源 FormsStartupProbe.cs：

- /platform:x64：打印 MAIN（指针宽度 8）、EnableVisualStyles passed、
  WinForms initialization passed，退出 0。
- /platform:x86：一分钟仍未打印第一行，CPU 约 104%；主动终止该独立测试进程。
- 此最小程序不访问数据库、不调用 SolidWorks，也不创建窗口。

输出位于 scratch/regasm-zero-logs/forms32.log、forms64.log。
静态分析输出 DatabaseConverter.il 与线程采样仅作为本地诊断产物，不提交二进制或反汇编。

## 结论与待查

已复现 32 位托管 WinForms 启动路径异常，不能把当前停滞简单解释成数据库
转换耗时；尚未定位到 Wine、WoW64、Mono 或 Rosetta 中的具体缺陷。
第一行未输出不一定代表 CLR 完全未启动，也可能在入口 JIT/依赖加载期间停滞。

数据库资源缺失是另一条需要独立处理的问题。不能仅把转换器改成返回零就
声称 Toolbox 已准备完成，也不能未经验证取消 32BITREQUIRED，因为存在
OleDb 与本地 SQLite 依赖。下一步应以最小程序定位 32 位启动问题，再单独
核查官方安装介质中数据库资源的部署流程。

补充介质检查：swwi/data/English.cab 已包含 swbrowser.sldedb（20,250,624 字节）
及 updatedb.sldedb（18,605,056 字节）。因此不能认为介质只有待转换的旧 MDB；
新容器可能应直接部署现成数据库。仍需核查 MSI 文件/组件映射和语言部署流程，
解释为何这些资源没有落入正式容器；本轮仅列出 CAB 内容，未提取或写入容器。

## 纯托管程序与解释器对照

同一独立容器、同一 App 内 Wine/Mono 的进一步对照：

| 程序 | 默认模式 | WINE_MONO_AOT=interp |
| --- | --- | --- |
| 32 位原生 cmd.exe | 正常退出 0 | 未测 |
| ConsoleProbe x64 | 输出 pointer=8，退出 0 | 未测 |
| ConsoleProbe x86 | 无 Main 输出，持续约一个核心 CPU | 输出 pointer=4，完成退出 |
| FormsStartupProbe x86 | 无 Main 输出，持续高 CPU | 输出 MAIN，随后在 EnableVisualStyles 崩溃 |

默认 x86 Console 的 +seh,+loaddll 日志已加载 libmono-2.0-x86.dll 和
mscorlib.dll，随后记录 c0000005。按同一进程模块基址定位，异常地址
7BF21135 对应 wow64cpu.dll +0x1135，访问地址 0x2ec5。这只是异常现场，
不能据此认定缺陷一定在 wow64cpu；Mono、WoW64 与 Rosetta 的交互仍待定位。

解释器模式下 WinForms 的托管栈为 Main → EnableVisualStyles →
ThemingScope.CreateActivationContext → CreateActCtx，随后发生执行访问异常。
因此解释器绕过了纯 Console 启动问题，但不能作为安装器的正式修复。
尚未对实际 DatabaseConverter 使用该开关，也未改变正式安装进程的环境。

Wine mscoree 源码通过 WINE_MONO_AOT=interp 选择 MONO_AOT_MODE_INTERP_ONLY：
https://github.com/wine-mirror/wine/blob/master/dlls/mscoree/metahost.c
此前试过 MONO_ENV_OPTIONS=--interp，仍停滞；不能把它当成已生效的解释器测试。

本地日志：console32-seh-modules.log、console64.log、console32-wine-interp.log、
forms32-wine-interp.log（均在 scratch/regasm-zero-logs）。复现源代码保存在
macos/Bootstrap/Tests/ConsoleProbe.cs 与 FormsStartupProbe.cs。

下一步应独立对照 32 位托管到原生调用，以及不同 Wine/Mono 组合，避免将
wineloader 的存在误当成所有 32 位运行时路径都兼容的证明。

## 最小 P/Invoke 对照

NativeCallProbe.cs 在解释器模式下依次调用 GetCurrentProcessId 和
CreateActCtxW(NULL)，不依赖 WinForms，也不创建实际激活上下文。

- x86 GetCurrentProcessId 正常返回，说明并非所有原生调用均失败。
- x86 CreateActCtxW 出现 execute access 异常（023C0080）。移除
  DllImport.SetLastError 后仍复现，不能归因于该选项。
- 同源 x64 正常输出 PID，并从 CreateActCtxW(NULL) 返回 -1。
- x86 直接导入 kernelbase.dll 的 CreateActCtxW 仍崩溃（023C0088），
  不是仅换掉 kernel32 入口转发就能解决。

以上定位到具体调用路径，但尚未区分 Mono 调用桩、Wine API 内部或
Rosetta 执行权限处理。没有修改正式运行时或把失败调用替换为成功。
本地日志为 nativecall32-interp.log、nativecall32-no-last-error.log、
nativecall64-interp.log、nativecall32-kernelbase.log。

## 运行时组合对照

继续以 NativeCall32NoLastError.exe 和解释器模式对照，同一探针二进制：

| Wine 来源 | Mono | 结果 |
| --- | --- | --- |
| App Gcenx 11.16 | 10.4.1 | PID 正常，CreateActCtx 崩溃 |
| Gcenx stable 11.0_1 | 11.3.0 | PID 正常，CreateActCtx 崩溃 |
| CrossOver 26.3.0.39832 | 自带 10.4.1 | PID 正常，CreateActCtx 崩溃 |

每组通过 loaddll 确认实际 libmono-2.0-x86.dll 路径。旧 Mono 对照克隆
app-runtime-smoke 到 scratch/mono104-compare/prefix，并仅在该副本设置
HKCU\Software\Wine\Mono 的 RuntimePath。稳定版使用全新
scratch/wine110-compare/prefix，CrossOver 使用 CX_BOTTLE_PATH 指向
scratch/crossover-compare，通过 cxbottle 创建 mono-probe（win10_64）。
没有替换 App 内运行时，也没有修改已有 CrossOver 容器。

日志分别为 mono104-compare/nativecall-interp.log、
wine110-compare/nativecall-interp.log、crossover-compare/nativecall-interp.log，
均位于 scratch。稳定版来源：
https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1

这些结果不足以把问题归因于 Gcenx 11.16 或 Mono 11.3.0 的单独回归。
它们只是解释器原生调用对照，不代表所有组合的默认 JIT、WinForms 或实际
安装器均已测试。旧 Wine 主版本仍未完成：查询时 Gcenx 官方发布与标签清单
仅列出 11 系列，需另找可核实的历史构建来源。

## 返回类型对照：IntPtr 与 uint

在 Wine 11.16 / Mono 11.3.0 的 x86 解释器模式下进一步测试：

- GetFileType(NULL)（返回 uint，参数 IntPtr）正常返回 0，排除所有单参数
  调用或所有 IntPtr 参数均异常的推断。
- GetModuleHandleW（返回 IntPtr）在查询导出地址前就崩溃，无法通过该探针
  得到 CreateActCtx 的真实入口地址。
- 同一个 CreateActCtxW(NULL) 将托管返回声明从 IntPtr 改为 uint 后，正常
  返回 0xffffffff，进程退出 0；这只在 x86 等宽返回值诊断中使用。

因此前述“CreateActCtx 调用异常”并不等于 API 实现缺陷，当前证据更指向
32 位解释器的指针返回值调用桩/封送路径。尚未定位到具体源码函数，也不
解释默认 JIT 模式的启动卡死；两条路径不能混为一谈。未修改 SOLIDWORKS
程序集或正式运行环境。新增 NativeArgumentProbe.cs 保存可复现对照，日志
为 nativeaddress32.log、nativeargument32.log、nativereturn32.log。

## 上游线索与调用桩证据

Wine-Mono PR #226（2026-06-04 合并）删除 macOS 32 位 mscoree 测试步骤，
并给 Mono 测试添加 -arch:x86_64。维护者提交说明怀疑 Rosetta 2 缺陷，
但该 PR 没有运行时修复，也没有足够异常细节证明与本地故障相同：
https://github.com/wine-mono/wine-mono/pull/226

设置 WINE_MONO_AOT=interp、WINE_MONO_VERBOSE=1 运行原有 x86 探针，
intptr-verbose.log 仍记录 interp_in / interp_in_static 包装器机器码生成，
地址约 02310d48 至 023110a5；随后 CreateActCtx 的 execute fault 位于
023C0080。两者不重合，尚不能将该异常地址标记为已识别的包装器。

上游 mono/mini/interp/interp.c 的 init_jit_call_info 也存在明确调用
mono_jit_compile_method_jit_only 的路径。这说明“解释器”并不等于全部
运行路径完全没有生成机器码，但仅阅读 main 分支不证明本机执行了该函数。
后续需要异常现场的内存属性/字节或精确版本源码映射；不能据此宣称已确定
Rosetta、内存执行权限或某个 Mono 函数为根因。

## WineDbg 异常现场

以 WineDbg 启动同一 NativeCall32NoLastError.exe，在首次执行异常处读取：

- EIP/EDI = 023c0080，ESP = 0022f584。
- info maps：023c0000–024bffff 为 commit/private/RW，没有 X。
- x /16b 0x023c0080：ff ff ff ff 00 00 00 00 30 c1 eb 7b 00 00 00 00。
- 栈首为 7bebc130，回溯包含 libmono-2.0-x86 +0xd93ee。
- 另一处 02310000–0231ffff 是 RWX，符合此前包装器机器码地址范围。

现在可以确认跳转目标是已提交的数据页，而不是未映射内存；目标开头并非
正常代码，不能用给该页增加执行权限作为修复。开头 ffffffff 与预期失败
返回值一致，但尚不能仅据此证明 API 已返回或确定是谁把数据地址当作代码。
下一步应追踪间接调用目标及返回值存储位置，定位调用桩/ABI 路径。

## x86 调用约定嫌疑

将上一轮栈值映射到本机 DLL：7bebc130 对应 kernel32 的 CreateActCtxW
导出入口，不应直接把它描述为该 API 的返回地址。Mono +0xe4600 附近的
分派代码包含 call *eax 后 add esp,4 等调用者清栈指令，布局与上游 interp.c
的 do_icall 快速分派相符；后者使用普通 C 函数指针类型。

如果 x86 stdcall API 被送入该分支，可能发生调用双方重复清栈，从而把
数据指针当作返回地址。这是具体待验证假设，不是已确认根因：按导出名称
设置 WineDbg 断点未成功解析，尚未在调用前后逐步观察 ESP 的变化。
需要使用已加载模块地址断点或探针主动断点继续验证。

## 已验证：stdcall 参数被重复清栈

NativeStackProbe.cs 在 API 调用前主动 DebugBreak；在模块加载后，以地址
断点捕获 kernel32 CreateActCtxW 入口及 Mono 调用后的指令：

1. API 入口 7bebc130：ESP=0022f568，栈首返回地址 7a7c46a4，下一项参数 0。
2. API 返回到 Mono +0xe46a4：EAX=ffffffff，ESP=0022f570，说明返回地址
   和一个 4 字节参数均已弹出。
3. 单步执行该处 add esp,4：ESP=0022f574，再次清理同一个参数，造成栈失衡。

仅在该测试进程把 ESP 临时恢复到 0022f570 后继续，越过了原崩溃路径，
最终 WineDbg 报告进程终止，未再停在异常。未捕获最终控制台文本或退出码，
不能据此宣称完整安装已修复。后续该公共分派位置还承接了一个普通 C 调用，
其返回后 ESP=0022f56c，需要正常清栈；因此不能全局删除 add esp,4。

这确认了当前 x86 解释器 IntPtr 测试的直接故障机制：stdcall 调用错误地
走入调用者清栈路径。它不证明默认 JIT 卡死有同一根因。正确修复应在调用
约定/快速分派选择处区分处理，不能修改所有 API 返回声明或全局删清栈指令。

## 发布版源码对应

Wine-Mono wine-mono-11.3.0 标签的 mono 子模块指向
73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc，已按该提交核对 transform.c，
不是仅依据 main 分支：
https://github.com/wine-mono/mono/blob/73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc/mono/mini/interp/transform.c

- 2317 起 interp_type_as_ptr：按类型判定可走指针快速路径，包含 I4，
  没有列出 U4；因此不能把 IntPtr/uint 对照推广为所有整型/指针差异。
- 2341 起 interp_icall_op_for_sig：按参数数目和类型选择 ICALL 操作。
- 2945–2947：native 且非 dynamic 时尝试快速路径，此处没有排除 stdcall。
- 2965–2967：普通路径在 TARGET_X86 下断言只支持 DEFAULT/C 调用约定，
  注释 Windows not tested/supported yet。

结论：已定位到发布版源码中的快速分支选择与 x86 调用约定支持缺口。
仅禁用快速路径不是完整修复：会进入具有明确支持限制的普通路径。
后续若补 Mono，需要增加/正确选择 stdcall 桥接，并覆盖参数数目、返回类型
及普通 C 调用回归；不能把未构建验证的源码改动直接放进正式 App。

## 原生桥接双向对照

安装 mingw-w64 后，用 GCC 16.2.0 编译 NativeBridge.c 为 x86 DLL：
两个导出均调用真实 CreateActCtxW，一个使用 cdecl，一个使用 stdcall。
NativeBridgeProbe.cs 按各自正确调用约定声明，均返回 IntPtr。

Wine 11.16 / Mono 11.3.0，WINE_MONO_AOT=interp：

- cdecl 桥接：RESULT=-1，退出码 0。
- stdcall 桥接：同样在 023C0080 发生执行异常，复现原问题。

桥接没有伪造 API 结果。此对照说明 IntPtr 本身并非必然失败，正确桥接
调用约定即可使该最小 API 调用工作。尚未改造 Mono 通用分派，也未解决
WinForms 全部 P/Invoke 或默认 JIT 启动问题，不能直接作为 App 修复交付。
本地构建：i686-w64-mingw32-gcc -shared -O2 -Wl,--kill-at；日志为
scratch/regasm-zero-logs/bridge-cdecl.log 和 bridge-stdcall.log。

## GitHub CI 基线产物验证

用户要求引擎只在 GitHub CI 构建；本地仅编译探针、编辑源码和运行验证。
fork 的基线 run 34594568831 全部成功，仅构建 libmono-2.0-x86.dll：
https://github.com/YJBeetle/wine-mono/actions/runs/34594568831

产物 SHA-256 校验一致：
003255a0ef2a59d47e2052abb883d9925a206a534ee4bcbe8ab8786de5bd3d7b。
在 scratch/mono-ci-runtime 中克隆运行时与测试容器，只替换副本的 x86 引擎，
通过 RuntimePath 指向该副本。loaddll 确认实际加载新引擎。

- baseline-stdcall.log：同一探针在 03290080 执行异常。
- baseline-cdecl.log：同一探针正常输出 RESULT=-1。

因此 CI 产物复现了原有差异，可用于补丁前后比较。正式 App 和容器未修改。

## 修复候选回归

首版 568c710c2cb 同时把 DEFAULT 和 STDCALL 分派到 stdcall，虽然 CI 编译
通过，本地字符串分配等内部 C 调用出现回归，不能使用。

第二版 6eda363b409 只处理显式 STDCALL，CI run 34597231628 成功：
https://github.com/YJBeetle/wine-mono/actions/runs/34597231628
DLL SHA-256：55d2566ab1eefc2c5e3a10ae823a0fe34c195b4a34b7be5be90b24e4b7815569。

- v2-stdcall.log：RESULT=-1，退出 0。
- v2-cdecl.log：RESULT=-1，退出 0。
- v2-forms.log：仍在 ThemingScope.CreateActCtx 执行异常。

显式 stdcall 修复已通过最小对照，但默认 Winapi 路径尚未覆盖。下一步
必须区分外部 P/Invoke 的默认约定和内部 C 调用，不能恢复首版的全局
DEFAULT→stdcall 判断。正式 App 和正式容器仍未替换。

第三版引擎 98e9f24ed64 在外部 P/Invoke 快速调用处识别默认 Winapi，
CI run 34598167173 成功。产物 SHA-256：
bbe67c144f36e1fcf5fd2ef6e82c0b1cf979480014c79a45f5b2e52cd5c286dc。

- v3-stdcall.log、v3-cdecl.log 均返回 -1，退出 0。
- v3-forms.log 输出 MAIN、EnableVisualStyles passed、WinForms initialization
  passed，退出 0，原 WinForms 初始化阻塞已越过。
- 实际 DatabaseConverter 在隔离 prefix 中以相同 C 盘参数启动，推进至
  Directory.Exists，但在 Kernel32.GetFileAttributesExPrivate 路径崩溃。
  日志 v3-database-converter.log 显示空地址读取异常；未完成数据库转换。

本轮仅从正式安装目录读取转换器，C 盘映射仍为 scratch/mono-ci-runtime/prefix，
未将补丁应用正式运行时，也未重跑正式安装。仍需定位后续原生调用路径。

DirectoryProbe32 最小复现仅调用 Directory.Exists（不存在的目录），无需
SOLIDWORKS 或数据库。v3-directory.log 与转换器相同，在
GetFileAttributesExPrivate 路径跳转至地址 0。弹窗返回地址 0x7a7c46e1
对应引擎 RVA 0xe46e1；反汇编前一条为 call *%eax，EAX=0，后接
add $0xc,%esp，是三参数 C 调用分支。尚不能确定目标指针为何为空。

同一隔离 prefix 换回未修改的 CI 基线 DLL 后，baseline-directory.log
更早在 PathInternal.GetIsCaseSensitive -> Guid.NewGuid -> BCryptGenRandom
崩溃（执行地址 0x00e13f98）。因此基线也不能完成目录探针，但未到达相同
调用，不能据此排除第三版补丁引入回归。需直接构造 GetFileAttributesEx
探针以绕过 PathInternal 初始化，检查目标指针与参数布局。
本次对照结束后隔离 runtime/bin 中暂为基线 DLL；正式容器不变。

随后恢复第三版候选 DLL，新增 FileAttributesProbe32 直接调用
GetFileAttributesExW，绕过 PathInternal 初始化。默认 Winapi 指针版本
返回 1；string + out 顺序布局结构体 + BOOL 封送版本返回 True，目录
属性为 16，均退出 0。对应 v3-attributes-default.log 和
v3-attributes-marshaled.log。成功调用后的 GetLastWin32Error 非零值
不作为失败依据（该 API 成功时无需清除旧错误）。

因此暂未在直接调用或普通字符串/结构体封送上复现空指针；下一步应核对
mscorlib 的 GetFileAttributesExPrivate 实际声明及其生成的包装器，而非
仅凭相同 API 名推断原因。隔离运行时现为第三版，正式容器仍未更改。

FileAttributesMetadataProbe 使用 x64 反射读取实际 mscorlib：内部方法为
Interop+Kernel32.GetFileAttributesExPrivate(string, GET_FILEEX_INFO_LEVELS,
ref WIN32_FILE_ATTRIBUTE_DATA)，返回 bool；DLL=kernel32.dll，入口
GetFileAttributesExW，Winapi/Unicode/SetLastError=true/ExactSpelling=false。
参数属性均为 None。记录见 attributes-metadata.log。

FileAttributesProbe 新增 enum 模式，使用枚举与 ref 结构体匹配上述差异，
第三版下返回 True、属性 16、退出 0（v3-attributes-enum.log）。因此
枚举与 ref/out 差异本身仍未复现崩溃；尚不能归因于普通 P/Invoke 声明。
下一步应直接调用框架内部方法并检查实际包装器，隔离调用上下文差异。

FileAttributesMetadataProbe32 invoke 在第三版解释器中通过反射直接调用
mscorlib 的 GetFileAttributesExPrivate，返回 True、退出 0
（v3-attributes-internal.log）。directory 模式在同一进程先完成相同调用，
随后 Directory.Exists 仍在 PathInternal 初始化的嵌套目录检查中崩溃，
仍为 GetFileAttributesExPrivate 路径的空地址调用
（v3-attributes-warm-directory.log）。提前解析/调用该入口不足以规避故障。

当前证据不支持将问题简单归因为 API 缺失或声明不兼容；需进一步检查
嵌套调用上下文的解释器实参布局、目标函数指针和优化路径。未修改运行时
补丁或正式容器，也未启动正式安装器。

关闭优化的对照尚未成立：MONO_DEBUG=mdb-optimizations 被运行时明确
拒绝；MONO_ENV_OPTIONS=--interp=-all 下仍崩溃，但未证明宿主读取该变量。
新增 MonoInterpreterHost.c 直接调用现有 DLL 的 mono_main，显式传入
--interp=-all。该启动路径在 DirectoryProbe 的 Main 输出之前即崩溃
（v3-direct-host-noopt.log），与 mscoree 宿主路径不同，不能用来判定
目录故障是否与优化有关。测试宿主不是 App 的实现方案。

第四版修复签名生命周期（Mono 50c8800d806）：第三版把归一化签名存入
td->mempool，转换结束会销毁该池，但 data_items 仍保留指针。WineDbg
观察到签名地址内容全为 0xFEEEFEEE。现改用所属映像分配的签名副本。
CI 34605603341 成功，DLL SHA-256：
1541b5f189664e7f3d09d7e5ee5c3ae9e1c19534b79e8331fb9a51f9c1c21562。

隔离 prefix 第四版结果：DirectoryProbe32 输出 False 和 completed，退出 0；
cdecl/stdcall 均返回 -1；FormsStartup32 完成 EnableVisualStyles 和初始化，
退出 0。实际 DatabaseConverter 使用此前相同路径参数运行，日志为空，
退出 0；这仅验证不再崩溃及进程正常结束，未验证数据库转换产物。
日志为 scratch/mono-ci-runtime/v4-*.log。正式容器和 App 引擎未替换。

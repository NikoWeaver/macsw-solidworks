# x86 JIT：执行后的 RWX 页面再次写入触发异常

2026-09-12，Wine 11.16 / Darwin 24.6.0 / Apple Silicon。

## 安装现场

JIT 修复安装停在 UpdateBrowserData 的 DatabaseConverter.exe，持续约一个
核心 CPU。macOS sample 显示 Rosetta exceptionserver 活跃，线程在信号
处理路径。未取得安装完成结果。日志在 scratch/jit-installer-validation。

## 最小复现与对照

PerformanceCounterProbe.c 不依赖 Mono、.NET、SOLIDWORKS。编译为 x86：

```sh
i686-w64-mingw32-gcc -O2 -o PerformanceCounter32.exe PerformanceCounterProbe.c
```

同一个二进制按参数运行：

| 参数 | 行为 | 结果 |
| --- | --- | --- |
| 无 | 100000 次 QPC | 退出 0 |
| alloc | 分配 RWX 页，不写入执行，100000 次 QPC | 退出 0 |
| write | 写入 RWX 页并 FlushInstructionCache，但不执行 | 退出 0 |
| jit | 写入 mov eax,imm32; ret，执行并再次改写同一页 | 第 0 轮完成，第 1 轮 before write 后异常 |
| jit-protect | 相同流程，写前 VirtualProtect(RW)，执行前 VirtualProtect(RX) | 10 轮全部完成，退出 0 |

jit 的 native-qpc-rwx-stages.log 出现与 Mono Console32 完全相同的异常：
EXCEPTION_ACCESS_VIOLATION at 0x7bf21135，读取 0x2ec5。此时尚未输出
第 1 轮 after write。jit-protect 的 native-qpc-protect.log 完成全部轮次。
这排除了把此前 100000 次动态改写的耗时直接当成卡死的混淆。

Mono Console32 的 WineDbg 原始现场也为 wow64cpu+0x1135，上层为
mono_100ns_ticks 中 QueryPerformanceCounter。Mono 编译阶段字符串及
反汇编表明处于 mono_codegen 后的计时调用。异常地址属于 WoW64 的
syscall_32to64 中 RIP 相对读取 cs32_sel 的指令；32 位异常视图将它解释
成绝对地址读取 0x2ec5。跳转 thunk 仍含正确的目标和 0x2b 选择子。

## 结论与边界

已定位可独立复现的触发条件：当前环境中，执行过的 32 位 RWX 代码页再次
写入会走入异常处理故障。Mono 代码管理器使用 MONO_PROT_RWX，符合该条件。
QPC 是暴露故障的调用位置，不是独立调用 QPC 就必然失败。

这是 Wine/Rosetta 交互层面的自修改代码问题，不是 SOLIDWORKS 数据库逻辑，
也不是第四版解释器签名生命周期修复的问题。尚未精确判定 Wine 或 Rosetta
内部哪一处实现负责，也未证明 RW/RX 切换可以直接安全套用于 Mono：共享
代码页、多线程同时执行和写入需要专门处理，不能粗暴全局切权限。

保留安装解释器基线。下一步应以此原生复现定位上游，或设计独立的 Mono
代码页策略候选并交给 GitHub CI 构建。本轮没有修改生产 DLL 或默认模式。
本轮独立探针已终止；原安装转换器未终止，安装现场仍待处理。

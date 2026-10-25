# 64 位 Mono 运行模式对照

2026-09-12，在正式容器完成安装后，对现有 x64 探针按进程分别设置
`WINE_MONO_AOT=none`（不强制解释器）和 `interp`。未改变 App 默认配置，
未重跑安装，也未将结果推广到 32 位 JIT。

| 探针 | none | interp |
| --- | --- | --- |
| Console64 | pointer=8，退出 0 | pointer=8，退出 0 |
| FormsStartup64 | EnableVisualStyles、WinForms 初始化通过，退出 0 | 相同，退出 0 |
| NativeCall64 | PINVOKE OK，CreateActCtx(NULL)=-1，退出 0 | 相同，退出 0 |

日志位于 `scratch/jit64-validation/`。本轮运行的是现有编译探针，结果仅
覆盖日志实际打印的检查，不声称覆盖源码后续新增的其他调用。

这不是性能测试，也不证明 SOLIDWORKS、WPF 或所有插件兼容。安装阶段继续
保留已验证的解释器模式；运行阶段下一步可单独启动 SOLIDWORKS 做 JIT 对照，
重点检查新建零件、界面、保存及托管插件。运行进程的子进程会继承环境，
因此不能将全进程切换等同于仅对 64 位托管模块启用 JIT。

# COM 与 WPF 手动测试探针

这三个源码用于独立检查托管运行时，不参与 MacSW App 构建，也不随 App
自动运行。它们不是 SOLIDWORKS 授权测试，不需要安装 SOLIDWORKS。

## 文件与判定

| 文件 | 用途 | 成功条件 |
| --- | --- | --- |
| `DotNetProbe.cs` | 提供带固定 CLSID 的 COM 可见接口和测试类；编译为库 | 编译成功仅证明源码可编译，不证明 COM 注册成功 |
| `ComActivationProbe.cs` | 按 CLSID 创建上述类，并调用 `Ping()` | 输出 `MacSW COM OK`，退出码为 0 |
| `WpfProbe.cs` | 创建带按钮的 WPF 窗口，等待首次内容渲染后自动关闭 | 输出 `WPF ContentRendered`，退出码为 0 |

激活或 WPF 探针捕获到异常时返回 1；结果不符合预期时返回 2。
WPF 的两秒关闭计时器只在首次渲染后启动：如果窗口从未渲染，程序可能不退出，
运行者需要设置独立的超时并记录挂起，不能把“仍有进程”算作成功。

## 编译与执行顺序

在独立测试容器中使用待测运行时及其 C# 编译器。输出放到忽略的 `scratch/`
目录，不把二进制提交到仓库。下列为 Windows 命令参数示例；`csc`、`RegAsm`
和引用程序集需使用当前测试环境中已确认的实际路径。

```text
csc /target:library /out:DotNetProbe.dll DotNetProbe.cs
csc /target:exe /out:ComActivationProbe.exe /reference:DotNetProbe.dll ComActivationProbe.cs
RegAsm DotNetProbe.dll /codebase
ComActivationProbe.exe
RegAsm DotNetProbe.dll /unregister
```

DLL 与激活程序放在同一目录。分别测试 x86/x64 时给两个编译命令都指定
`/platform:x86` 或 `/platform:x64`，并匹配对应架构的 RegAsm。
注册和注销会改变测试容器的注册表，因此不要默认在正式容器执行。
RegAsm 的注册退出码不能单独证明注册成功；必须检查 CLSID/CodeBase，并以随后实际激活与
方法调用结果为准。

WPF 探针需引用完整桌面框架程序集：

```text
csc /target:exe /out:WpfProbe.exe /reference:WindowsBase.dll /reference:PresentationCore.dll /reference:PresentationFramework.dll WpfProbe.cs
WpfProbe.exe
```

程序集未在编译器默认搜索路径中时使用绝对路径引用。
窗口标题只是测试标识，不证明加载了原生 .NET；记录程序输出的 `CLR:` 路径，
以及 Wine 版本、运行时版本、架构、解释器/JIT 配置、退出码和是否超时。

## 验证边界

历史实验见 `docs/regasm-validation.md`（相对仓库根目录）。本次整理只归档
源码和运行说明，未重新执行 COM 注册或 WPF 测试，不增加新的兼容性通过结论。

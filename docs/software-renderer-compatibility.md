# macOS 软件 renderer 兼容待办

这是独立的低优先级工作，不作为 SWCLI 主线的前置条件。Apple 软件 renderer、
SOLIDWORKS 的“软件 OpenGL”选项、`0008` 位图白图修复和托管 `CloseDoc` 异常
属于不同层面，不能将其中一项通过当成其余问题已解决。

## 已确认的托管环境

MacSW `76e4fcc` 的 [CI 37765558540](https://github.com/YJBeetle/MacSW/actions/runs/37765558540)
中，ARM64 和 Rosetta x86_64 都只枚举到一个未加速 renderer。主显示器加速和
任意加速 legacy 请求均在格式选择阶段返回 `10002`；自动选择和指定软件请求
均成功创建、绑定，报告 `Apple Software Renderer`、`2.1 APPLE-21.0.19`，支持
FBO、framebuffer blit、packed depth/stencil。

原 Wine `init_context()` 强制要求加速，因而 OpenGL 驱动初始化失败。八组
DIB/WGL 探针都停在 `create-context`，随后 loader 超过 60 秒期限；这轮没有
进入 SOLIDWORKS。上述证据不说明之前的 `CloseDoc / 0x800703e6` 已找到根因。

## 独立候选补丁

[`0009-winemac-software-renderer-fallback.patch`](../patches/wine-crossover/0009-winemac-software-renderer-fallback.patch)
在 `0008` 后应用，不重写 `0008` 的 FBO、像素转换或共享上下文实现：

- 首先保持原来的主显示器加速初始化请求。
- 仅 legacy 加速格式不存在（`kCGLBadPixelFormat` 或成功但无格式）时，尝试
  明确指定 `kCGLRendererGenericFloatID`；分配、创建、绑定错误直接失败。
- GL3/GL4 core 探测不降级为 legacy，版本与扩展继续读取实际 GL 上下文。
- 查询所选上下文的虚拟屏幕与 `kCGLPFAAccelerated`。只有实际选择了软件
  renderer 时才允许本次软件格式枚举，不写 `AllowSoftwareRendering` 注册表。
- 位图格式继承真实加速属性；软件格式通过原 Wine 描述路径报告
  `PFD_GENERIC_FORMAT`，不宣称硬件加速。
- 创建失败时不再绑定空上下文；查询或绑定失败释放临时资源，保留原上下文。

选取软件 renderer 的属性来自 Apple 的
[像素格式选择说明](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_pixelformats/opengl_pixelformats.html)。
它不等于启用 SOLIDWORKS 内部的“软件 OpenGL”。此前勾选后卡死的现象需要单独
调查；本补丁与验证都不更改用户这个选项，也不表示 Linux 已有相同能力。

补丁 SHA-256 接入 Wine 内部构建键、CI 的既有 `patches/wine-crossover/**`
缓存输入、`BuildManifest.plist` 的 `WineMacSoftwareRendererPatchSHA256` 与
`verify_app.sh`。独立 CGL mock 覆盖硬件优先、软件回退、core 不降级、空返回、
错误分类和资源释放；mock 不构成真实 renderer 或 SOLIDWORKS 验收。

## 验证边界

八组原生位图门禁保留全部像素、上下文、深度模板与状态恢复断言，并增加
实际 GL renderer/version 和 WGL 加速属性观察。Apple 软件 renderer 必须报告
`PFD_GENERIC_FORMAT` 和 `WGL_NO_ACCELERATION_ARB`；属性不符也是失败。

本机允许使用临时 CGL 测试夹具，拒绝加速格式选择来触发回退；其余软件 CGL
调用仍执行真实 Apple 实现。当时未增加产品强制软件开关，也未将夹具注入发布 App，
也不把本机触发回退算作 CI-only 软件环境已通过。

## 本机验证：2026-10-08

在 M2 Max、macOS 15.8 上编译新的 Wine 模块，用临时 App 副本和用户授权的
主 bottle 验证。软件组通过临时 CGL interpose 拒绝加速格式选择，其余调用
仍进入真实 Apple CGL。这不是模拟 GL 返回值，也没有修改 SOLIDWORKS 内部
“软件 OpenGL”设置；夹具不进入产品构建、缓存或发布 App。

| 验证项 | 正常硬件路径 | 触发软件回退路径 |
| --- | --- | --- |
| 实际 GL renderer | Apple M2 Max | Apple Software Renderer |
| 实际 GL version | 2.1 Metal - 89.4 | 2.1 APPLE-21.1.1 |
| 八组位图门禁 | 8/8，GL error 0 | 8/8，GL error 0 |
| 像素格式加速属性 | `WGL_FULL_ACCELERATION_ARB` | `PFD_GENERIC_FORMAT` / `WGL_NO_ACCELERATION_ARB` |
| 共享建模 | 85 个事件，通过 | 85 个事件，通过 |
| 随后的共享尺寸 | 242 个事件，通过 | 242 个事件，通过 |
| SWCLI 报告的宿主 PID | 32，两项一致 | 1148，两项一致 |
| 清理错误 | 0 | 0 |

两组均为可见、daemon 独占的 SOLIDWORKS 33.5.0。每组的建模→尺寸使用同一个
daemon/SW 实例，未在两项间重启，未重试原生操作，也未修改共享断言。最终
文档列表为空，daemon 正常退出。硬件组首次调用因已有未修改的空白文档而被
共享测试的前置条件拒绝；该记录保留，关闭此空白文档后才开始上述连续测试。

运行基线是原 App 打包的 SWCLI `fb147c19e65a4d4b2a84e8e8c140c1589171c54e`，
共享脚本也从同一提交导出。硬件与软件证据保存在本机忽略目录
`build/diagnostics/renderer-20261008/`，包含 renderer 日志、共享测试 JSON、
失败的前置检查及最终退出记录；未上传主容器日志或模型。

`make winemac` 成功；四项新增离线测试包含 15 个真实补丁函数的 CGL mock
场景。补齐临时测试环境的 `jsonschema==4.26.0` 后，`make test` 通过：MacSW
Python 71 项（1 跳过）、Swift 141 项、当前 SWCLI 子模块 Python 621 项
（8 跳过）。完整 `make app` 则在打包前因已有 SWCLI 子模块 `4cde3b2…` 与
配置固定值 `fb147c19…` 不一致而停止；未改动此指针，也未将临时 App 当作正式
打包通过。新补丁的 manifest/校验接线已完成，但完整成品验证仍待版本一致后
执行。临时 App 副本和已编译的注入夹具已清理，正常 MacSW 已恢复，未部署
候选模块到日常 App。

## 剩余验收

### 扩充门禁的预算与时间日志（2026-10-11）

[成功运行 38049622744](https://github.com/YJBeetle/MacSW/actions/runs/38049622744)
同样报告 Apple Software Renderer；可见建模 175 个事件，用时 1630.6 秒，
可见尺寸 3122.7 秒。隐藏建模／尺寸分别 703.9／1247.0 秒，两个模式的
Toolbox 门禁也通过。这说明软件路径并非每次失败，不证明不存在偶发停滞。

[后续运行 38079035678](https://github.com/YJBeetle/MacSW/actions/runs/38079035678)
增加自建装配体与样例导出；超时前已完成 238 个事件、五组用例。最后的
`sketch.rectangle` 执行约 247 秒，原生边界仍持续返回，整套建模却被 1800 秒
总期限终止。因此不能将这两轮视为完全相同序列的随机成败，也不能仅凭该轮
认定死锁或确认纯性能原因。

按用户要求，将 MacSW CI 整套建模预算从 1800 加倍到 3600 秒，双模式共享步骤
从 225 调整为 300 分钟，仍在 360 分钟 job 期限内。单请求 300 秒、尺寸 3600 秒、
Toolbox 600 秒、原生调用超时与全部 CAD 断言不变；不重试或中途更换宿主。
这是预算调整，不是软件渲染故障修复，实际结果须由后续 CI 确认。

适配层从现有匿名 stdout 文件实时观察共享脚本的固定进度行，输出 UTC 时间、
本阶段累计耗时及距上一次进度的间隔，并保存 `shared-step-progress.log`。
时间基准明确为 `stdout-observed`（0.5 秒轮询）；它不是原生调用的精确耗时，
积压行可能在一次读取中被观察到。未识别的输出、参数、结果和 stderr 不转发。
每个外层命令在 `runtime.json` 保留开始／结束 UTC 时间和总耗时；非零退出与
真超时仍失败，日志观察错误不改变 CAD 结果，也不等待后台进程持有的管道 EOF。

### 单次请求预算与重复采样（2026-10-11）

[运行 38091260009](https://github.com/YJBeetle/MacSW/actions/runs/38091260009)
完成五组建模用例后，新的矩形请求触发单请求 300 秒上限，而非整组 3600 秒
期限。该请求已返回 619 次 COM 读取，合计 254.8 秒；读取耗时中位数从前一个
矩形的 8 毫秒升到 299 毫秒。创建矩形本身 13.6 秒，退出草图 7.1 秒，直到
请求开始后 299.6 秒仍有调用返回。它与此前某个调用不返回的轮次不能直接
归为同一种停滞，尚未确定软件渲染、重建或宿主资源状态中的实际根因。

按用户授权，CI 传给共享门禁的单请求预算从 300 增至 600 秒；启动仍为 300 秒，
建模／尺寸整组仍各为 3600 秒，Toolbox 整组仍为 600 秒，步骤／job 期限不变。
不改 SWCLI 产品默认值、不删断言、不重试业务操作、不在门禁间更换宿主。

原生采样不再每阶段只抓一次：未返回的边界停留 30 秒可触发首次采样；持续
返回的慢请求也可触发周期采样，两次启动至少间隔 60 秒。每次仅对唯一、
daemon 自有的 CI SW 宿主执行 2 秒、10 毫秒间隔的只读线程采样，工具期限
30 秒；每个可见／隐藏模式最多 140 次，计数和频率跨三组门禁共享。
报告采用 `visible-native-sample-001.log` 等独立名称，不覆盖早期样本。
`*-host-metrics.log` 中的 `native_sample` 记录 UTC、阶段、原生边界及触发原因；
周期采样不意味着调用已卡死。采样会有观察开销，不是业务修复。

系统内存指标在每阶段开始及随后每分钟采集：只读 `vm_stat` 的已知计数、
`vm.swapusage` 的交换空间用量，以及 `memory_pressure -Q` 的可用百分比。
每个工具期限 2 秒，仅保留白名单数值，不保留原始输出；通过相邻样本的
Swapins／Swapouts 差值观察交换活动，不能将累计计数当作瞬时活动。
这些指标与线程样本都不参与成功判定；诊断失败只记录缺口，原始业务失败
仍会保留。后续完整 CI 通过前，签名／公证的输入门槛保持不变。

### 整组期限与用例清场（2026-10-12）

[运行 38122863117](https://github.com/YJBeetle/MacSW/actions/runs/38122863117)
已实际使用 600 秒请求预算，原先失败的矩形请求在约 444.7 秒后成功；随后
拉伸用时 111.6 秒。最后的圆形请求只执行约 52.6 秒，仍在返回 COM 读取，
整套建模便触及 3600 秒外层期限。这不是单请求 600 秒再次超时。

CI 建模整组期限调整为 5400 秒；尺寸仍为 3600 秒、Toolbox 仍为 600 秒，
单请求仍为 600 秒。双模式共享步骤为 340 分钟，job 仍为 360 分钟。
测试同时核算两模式的阶段、启动、采样收尾及 renderer 探针预算；安装及
其他 job 步骤仍受全局期限约束。预算调整不证明软件渲染性能问题已经修复。

同步的共享 SWCLI 门禁在建模每个用例、尺寸每个平面的圆径／中心／矩形组
结束后，读取真实文档列表并要求为空，才进入下一组。证据增加 `case_cleanup`
及清场进度；关闭调用报告成功但仍有文档的反例必须失败。未知残留不自动
关闭，不重启宿主、不重试用例；同宿主连续回归和全部原有 CAD 断言保留。
Toolbox 已有前后文档列表一致性检查，保持不变。

该轮系统记录到约 2.6 GiB swap，但末段交换活动不大，不能认定 swap 是
COM 读取变慢的根因。重复 Rosetta 采样也未可靠展开 PE 线程，不能把重复的
ntdll 地址当作死锁证明。新的完整 CI 仍需确认组间清场及全部新增导出测试。

### 日常档与完整双模式验收（2026-10-12）

诊断开关 `MACSW_OPENGL_RENDERER=software` 会显式选择真实 Apple 软件 renderer，
并排除硬件像素格式；未设置或 `auto` 保持原来的硬件优先／软件回退逻辑。
不写永久注册表，不伪造 GL 属性，不将软件 legacy 冒充 GL3／GL4 core。
修改环境后应冷启动 Wine，确保 SW 和其激活服务不沿用旧进程环境。
CI adapter 可使用 `--renderer software`，会核对实际位图 GL renderer；默认 auto。

共享门禁采用 `--suite core|full`。MacSW 普通提交跑日常 core 档，仅启动一个
可见宿主，依次执行建模 → 尺寸 → Toolbox；完整验收用 full 档，保留可见／隐藏
两轮完整序列。每轮内部不重启、不重试，文档清场、租约、同宿主及各类导出断言
仍为必需。两轮有独立证据目录；不使用隐藏文档生命周期冒烟替代完整验收。

日常尺寸档在 Front 验证通用权限、CAS、保存重开、过期句柄和中心固定，Top／Right
保留直径、矩形尺寸、中心和实体几何校验。完整档保留三平面的全部组合，以及
feature-depth、面／边等完整建模观察。运行 JSON 明确记录 suite 和 mode coverage，
建模和尺寸的 suite 必须相同。用例拆入共享 CLI 的 gate_support 文件，平台不复制 CAD 断言。

日常共享步骤最多 240 分钟；完整验收在一个 runner 上依次跑可见／隐藏模式，
整个共享步骤最多 330 分钟。每组换新的 CLI／SW，会话隔离不修复底层内存积累。
组内 CAD 限制 1800 秒、单请求 600 秒不变；runtime job 仍最多 360 分钟。
Windows 使用相同分档／模式规则；DockerSW 保留后台单模式，
自动正式镜像提升仍要求 full，手动 core 不提升正式标签。MacSW 签名输入只接受同一
提交上 runtime job 和 full 双模式共享步骤成功。实际耗时待新 CI 验证。

### 本机短用例内存对照（2026-10-12）

使用新的进程级 renderer 开关和主容器，三种条件分别冷启动 daemon 独占 SW。
调用共享 `DrivingSmoke.center_constraints("front")`，每轮均要求实际文档清空，
宿主 PID 不变，不复制 CAD 实现、不重试业务调用。真实 GL 日志分别确认
`Apple M2 Max / accelerated 1` 和 `Apple Software Renderer / accelerated 0`。

| 条件（两轮） | 耗时 | 初始 footprint | 第一轮结束 | 第二轮结束 |
| --- | --- | --- | --- | --- |
| 软件、不执行 sample | 95.2 秒 | 1.2G | 2.0G | 2.4G |
| 硬件、不执行 sample | 97.9 秒 | 1.2G | 1.7G | 1.7G |
| 软件、每分钟 sample | 106.0 秒 | 1.2G | 2.0G | 2.4G |

第三个软件宿主再连续执行三轮（不再采样），总计五轮后 footprint 依次为
2.7G／3.1G／3.4G。每轮保存重开、清场通过。相同宿主的 `vmmap -summary`
显示 IOSurface 虚拟区域从第二轮后的 627.5M 增至第五轮的约 1.5G；
硬件两轮后仅 27.4M。RSS 不等于 footprint，关闭文档也不等于释放图形资源。
这支持软件路径存在图形内存滞留线索，尚未定位到具体 Wine/Apple/SW 资源所有者，
不能仅凭区域尺寸认定泄漏、或把所有 CI 慢调用都归因于它。短用例不是完整 CI 验收。

诊断脚本 `scripts/diagnostics/compare_runtime_memory.py` 用 App 自带 native Python
运行，调用共享用例，并保存 `vmmap`、可选 sample、业务记录和清理结果。
调用者负责冷启动及 renderer 环境；脚本拒绝共享交互宿主或已有文档，不创建容器。
证据保留在本机 `/private/tmp/macsw-renderer-selection.v4A0P6/`，不上传主容器材料。

以下为历史 2026-10-08/09 的验收记录，不能作为当前提交的通过结论。
已通过单元测试、构建、完整打包校验、真实安装和基底缓存保存。托管 Wine
确实回退到 `Apple Software Renderer` / `2.1 APPLE-21.0.19`，八组位图均输出
成功及真实无加速属性，但外层捕获命令在 60 秒处超时，因此整项门禁仍失败，
没有启动 SOLIDWORKS。这不构成共享建模或 `CloseDoc` 验收。

2026-10-09 将宿主日志接收改为私有匿名文件，等待真实子进程退出而非管道 EOF，
保留退出码、期限和所有断言。新增测试覆盖后台进程仍持有日志句柄、非零退出、
真超时和超时／退出竞态。该接线仍须新的托管 CI 验证；原运行未记录超时瞬间
的子进程状态，不能据此断言当时仅为管道假超时。
本机完整 `make test` 通过：MacSW Python 78 项（1 跳过）、Swift 141 项、
SWCLI Python 621 项（8 跳过）；离线测试不替代云端真实运行证据。

隐藏模式尚未验证。托管软件-only CI 还须依次通过八组位图、SOLIDWORKS 启动，
以及同一 daemon/SW 实例中的共享建模→尺寸门禁。继续遵守中途不重启、不重试
原生失败、不修改共享几何断言；某模式失败时保留证据，不继续后序尺寸门禁。

最终仍须在只存在软件 renderer 的托管 CI 获得上述证据。软件 OpenGL 2.1 的
能力、性能和稳定性都不能由原生上下文创建成功推定；硬件本机的历史通过也
不能作为新补丁或托管 `CloseDoc` 的完成证明。

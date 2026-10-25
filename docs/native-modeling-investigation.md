# 原生建模 CI 调查

## 当前结论

MacSW 的构建、全新安装及托管软件 renderer 的完整可见／隐藏共享序列曾通过
`37894268328` 和 `37900743068`；每模式 85 个建模和 361 个尺寸事件均成功，
保持同一宿主并正常清理。但后续 `37930459544` 在隐藏模式重开模型的原生
`CloseDoc` 上再次超过 120 秒。因此完整成功不是间歇关闭故障已经修复的证明。
此前的 CLI 元数据校验、错误原点样例和隐藏模式中心拓扑差异已分别修正；
当前仍没有足够证据把关闭故障归因于某个 Wine 模块或隐藏窗口。
调查保持原有共享门禁，不重试失败操作，不中途重启后续跑。此前证据使用
120 秒操作超时；2026-10-10 经用户确认，后续 MacSW CI 改用可配置的 300 秒
操作预算，以区分机器缓慢与长期阻塞，不把更长等待本身称为根因修复。

MacSW 负责安装、Wine、App 打包、驱动映射、宿主准备和证据收集；建模操作与
断言仍只维护在 SWCLI。Windows、DockerSW 的成功不能替代本仓库 macOS 的证明。

## 最新调查：2026-10-10

### 2026-10-10：只放宽低性能 CI 的预算

SWCLI 共享脚本增加 `--request-timeout`，默认仍为 120 秒；MacSW 显式使用
300 秒，CLI 与直接协议调用一致，外层 CLI 额外留 15 秒。每模式建模／尺寸
门禁分别为 1800／3600 秒，双模式步骤 210 分钟；启动 300 秒、就绪等待
330 秒，同一次 Wine 激活预算 240 秒。原生采样工具预算增至 30 秒，采样仍是
两秒／10 ms、begin 不变至少 30 秒后触发，不延长采样持续时间。

参考成功运行 `37900743068`，可见尺寸门禁用时约 1838 秒，单次矩形约
52 秒；该模式 25 次关闭最长约 8 秒。因此给整体慢操作留余量是合理的，但
之前 `CloseDoc` 120 秒未返回仍是独立的待调查证据。保留全部断言、同实例
顺序和失败诊断，新预算下的结果须按新配置单独记录，不能改写旧运行结论。

### 缓存命中后再次出现的原生关闭阻塞

[37930459544](https://github.com/YJBeetle/MacSW/actions/runs/37930459544) 固定 MacSW
`9b38f50da6639b0084db24c81f321f5506280ea9`、SWCLI
`a857b75c7298a9225b0415cf06c761e0623e672b`。构建通过；官方安装基底 v3 缓存命中，
完整校验及复制约 55 秒，全新安装被跳过。两模式部署的 SWCLI 清单摘要均为
`f91801acb68a1c768ac0e40ab4f6112f5a963c83cc565f21cf9384ed068e3489`，与完整成功的
`37900743068` 一致。代码部署没有漂移；这不能单独排除注册表或宿主状态因素。

准确失败步骤为 `SOLIDWORKS installation & runtime` /
`Shared modeling then driving dimensions on one host`。可见 PID 504 的 85 个建模及
361 个尺寸事件全部通过；隐藏 PID 468 的建模 85 个事件通过，尺寸在事件 205
（从 0 开始）的 `document.close` 首次失败，最终记录 209 个事件。随后三次清理
出现的 `WorkerStartupError / REGDB_E_CLASSNOTREG` 是超时后的错误，不是首次启动失败。

首个失败请求 `9afe4610-5353-4c86-9d9b-2d78871653fe` 关闭保存后只读重开的 top
圆柱 `d-arjqm9`。目标 `modified=false`、stamp 147、`needs_rebuild=0` 且诊断健康；
它是后台文档，另有两个空白零件，故不是最后一个文档触发 SW 退出。关闭请求前
约 0.451 秒的描述读取均正常返回，最后边界是 sequence 56 的
`SldWorks.CloseDoc / begin`，此后没有 end/error 或批次状态恢复，直至 120 秒截止。
旧文档首次关闭和同序列 front 重开文档的后台关闭均成功，因此不能将问题简单
归结为后台文档、top 平面或重开本身。

完整成功运行 `37900743068` 的相同事件在约 1.199 秒返回；WGL 日志先记录非空
上下文绑定，再记录上下文及 drawable 销毁。失败运行则在 begin 后只有九条空
上下文解绑记录，没有非空绑定、创建或反复切换。该差异只缩小证据范围，尚不证明
具体 OpenGL 方法、COM 引用或 `CommandInProgress` 是根因。失败前 SW CPU 已较高，
不能用 CPU 百分比定位线程。

原采样器在 begin 不变超过 30 秒后确实触发，但 `/usr/bin/sample` 自身超过四秒
工具预算，未产生线程报告；日志尾部仍保留该 begin，不是 128 KiB 读取范围漏掉了
边界。`dea7243` 单独改进诊断：采样仍为两秒、间隔改为 10 ms、工具预算为 15 秒，
无论成功与否都保留请求/方法/PID 关联及报告是否存在。`sample` 会在观察点短暂
暂停线程，不能称为零扰动；CAD 超时仍为 120 秒、共享断言及宿主连续性不变。
这不是关闭逻辑修复。诊断版本的完整运行
[37949982837](https://github.com/YJBeetle/MacSW/actions/runs/37949982837) 必须按其终局
产物另行判断，不因再次成功就宣布本间歇故障已解决。

### 本机生命周期对照：没有复现不等于修复

以下都使用未修改的 SWCLI `a857b75`，业务期限仍为 120 秒，失败不重试；
只改变测试宿主，不改变几何断言、目标文档或原生关闭操作。

- Windows VM 的隔离环境以可见自有 PID 4396 完成一次 85 事件建模，随后同一
  daemon/SW 连续完成三次 361 事件尺寸序列。75 次关闭全部成功，约 113–656 ms；
  其中九次对应只读重开的后台圆柱、另一空零件在前台，关闭前均未修改、stamp 147。
  清理错误为空，最终文档列表为空、daemon 正常停止，VM 保持开机。
- M2 Max、macOS 15.8 上，单独克隆的临时 Wine prefix 在隐藏/可见模式各完成
  三轮精确 top 生命周期样例（每轮 80 个事件）；重开后的后台关闭分别约
  248–286 ms / 831–1174 ms。随后分别从新宿主 PID 336 / 1672 完成原有完整
  建模 85 → 尺寸 361 序列，同模式宿主不变、清理无错误，正常停止。
  该 App 的 Windows/native SWCLI 源码和 prefix 后端逐文件匹配固定源码，但
  WGL 明确显示 `Apple M2 Max`，不是托管 CI 的软件 renderer。

本机完整对照保存于 `full-gates.json`，Windows 对照保存于独立的三份
`driving-dimensions.json`；不把临时控制器的 PID 观察错误归为 CAD 失败。
两次本机健康采样因无法精确识别 Unix PID 而未执行，也不能用它们声称大型
Rosetta/SW 报告已在 15 秒内生成。软件-only临时驱动仅作为下一项诊断变量，
不部署到生产 App、不作为关闭修复或正式能力；必须另证实际 renderer 与上下文
加速属性。以上阴性结果不足以排除托管软件、OS/调度或累计状态因素。

本机随后仅在临时 App 副本替换诊断 `winemac.so`，将初始化、像素格式枚举和
上下文创建固定为 Apple GenericFloat 软件 renderer；不在生产提供该开关。
7853 个常规文件的比对中唯一差异是这个驱动，SWCLI/loader/Python 不变。
日志实际记录 `Apple Software Renderer`、初始化及创建的上下文非加速。
隐藏自有 PID 436 在同一实例完整通过 85 → 361 事件，清理为空、正常停止；
相同 top 重开后台关闭请求用时约 227 ms。因此软件 renderer 本身也不是在
本机充分复现故障的条件，仍不能据此排除托管 OS、调度或配置差异。

该软件实例在业务结束后的空闲健康采样确实执行成功：两秒/10 ms 采样、
15 秒工具预算，最终约 4.403 秒生成 13,103,646 字节报告。这支持旧四秒预算
过紧的诊断判断，但它不是失败调用的线程栈，不能替代托管故障样本。
本机临时 prefix/影子 App 在停止后等待清理确认，小型 JSON/日志独立保存；
未修改主 bottle、主 App 或正式 Wine 补丁。

### 此前完整成功的托管序列

[37894268328](https://github.com/YJBeetle/MacSW/actions/runs/37894268328) 固定 MacSW
`4e9e002635b653ffd2c682a76bd4658571972a0d`、SWCLI
`a857b75c7298a9225b0415cf06c761e0623e672b`，构建及真实安装／运行两个 job 均成功。
可见模式 PID 504、隐藏模式 PID 464，版本均为 `33.5.0`；各自建模 → 尺寸前后
宿主不变，四份业务记录均完成、成功且清理错误为空，22 条 runtime 命令全部退出 0。

三个平面的中心固定首次创建、重复 no-op、原生保存重开均保留精确身份和几何。
真实额外原点约束样例在两模式仍返回 `UnsupportedCenterConstraint`，stamp
`142→142`、无活跃编辑，原前台文档不变。重复固定 stamp `144→144`，不是通过
重试、降低约束或重启同一序列换来的成功。

arm64 与 Rosetta x86_64 CGL 清单仅有 Apple Software Renderer；自动／软件上下文
成功、加速格式不可用。八组 Wine 原生位图探针在此软件 renderer 上全部通过，
像素数精确且 GL 错误为零。因此本轮补足软件宿主的完整共享验证，而不只是本机
硬件渲染证明。本轮仍使用旧缓存策略的全新安装，不覆盖后续 `34de644` 的 v3
缓存与当前 SWCLI 重部署改造；后者须独立记录。

### 前一轮的 CLI 结果校验失败

[37885314239](https://github.com/YJBeetle/MacSW/actions/runs/37885314239) 固定 MacSW
`601f1616e5460c0a3385cabdc44c731da619e6ed`、SWCLI
`e06313680f5e410b29ea0ffb457b738252f20eb5`。构建、安装、软件 renderer 位图门禁和
可见启动通过；85 个共享建模事件通过，包含首轮拉伸、切除、三面建模、保存重开、
反向切除及拒绝切除后的继续建模。前后宿主 PID 均为 504、版本 33.5.0，清理错误 0。

随后 front 尺寸门禁的矩形与 `sketch.fix-center` 实际成功：中心 (3,4)、40×30 mm、
边界 [-17,-11,23,19]。请求 `b1fe45f7-dbd9-4cfa-ba4e-5e99c06e72dd` 的 CLI 输出
带有展示层 `request_id`；共享脚本直接把平坦 JSON 交给仅描述业务结果的 Schema，
于是报 `OperationResultInvalid / Additional properties ('request_id')`。准确失败步骤
仍为 `SOLIDWORKS installation & runtime / Shared modeling then driving dimensions on one host`，
但这轮不是 `WorkerTimeout` 或宿主断连；未进入隐藏模式。

这一轮没有出现满足 30 秒不变 begin 边界的调用，因此没有原生线程采样文件。
不能将未复现解释为旧 Wine 阻塞根因已修复，也不能继续拿旧 FirstFeature 超时解释
本次明确的共享脚本校验错误。SWCLI 已独立修复 CLI 元数据校验，并按用户选择
换成确实带额外原点约束的固定原生拒绝样例；本仓随后同步新源版本继续完整门禁。

## 已完成运行的证据

| 运行 | 首个业务失败 | 已证明的边界 |
| --- | --- | --- |
| [37706684327](https://github.com/YJBeetle/MacSW/actions/runs/37706684327) | front 建模和切除后，top 矩形超过 120 秒 | 缓存恢复、可见模式就绪及此前操作成功；未进入尺寸或隐藏模式 |
| [37727420806](https://github.com/YJBeetle/MacSW/actions/runs/37727420806) | 第一次实际后台 front 矩形超过 120 秒 | 全新安装、可见模式就绪、无租约及错误 stamp 的前置拒绝成功；此前没有实际切除 |
| [37730038675](https://github.com/YJBeetle/MacSW/actions/runs/37730038675) | 保存后的后台文档 `document.close` 返回 `0x800703e6` | 缓存恢复、front/top/right 草图、拉伸、圆、切除和保存成功；未进入尺寸或隐藏模式 |
| [37732440131](https://github.com/YJBeetle/MacSW/actions/runs/37732440131) | 首次拉伸在重建后的特征诊断遍历期间超过 120 秒 | 全新安装、可见模式就绪、首次矩形成功；未进入尺寸或隐藏模式 |
| [37736636613](https://github.com/YJBeetle/MacSW/actions/runs/37736636613) | 首次切除在重建后的特征诊断遍历期间超过 120 秒 | 缓存恢复、可见模式就绪、矩形、拉伸、测量、圆及草图检查成功；未进入尺寸或隐藏模式 |
| [37741088903](https://github.com/YJBeetle/MacSW/actions/runs/37741088903) | 保存后的后台文档关闭返回 `0x800703e6`，非超时 | 全新安装、可见模式及 front/top/right 建模、检查、测量和保存成功；未进入尺寸或隐藏模式 |
| [37746169893](https://github.com/YJBeetle/MacSW/actions/runs/37746169893) | 后台 `CloseDoc` 返回 `0x800703e6`，非超时 | 构建、安装与可见模式就绪及此前几何/保存成功；直接关闭日志已配对为 begin/error，未进入尺寸或隐藏模式 |

`37727420806` 和 `37730038675` 都固定 SWCLI `86c52f27c0b2bdcfe0bf990debfc840481608d58`，
获得就绪的自有 SOLIDWORKS PID 488、版本 `33.5.0`、简体中文、可见模式。
失败点不同，因此“始终在第一次矩形”“只发生在切除后”“只因隐藏”均不成立。

`37730038675` 的 Wine 异常日志包含服务器端捕获的空地址访问异常，随后 COM
返回 `0x800703e6`。这证明该调用出现原生异常，不证明整个 SOLIDWORKS 进程已
崩溃，也不足以区分 SOLIDWORKS 缺陷、Wine 兼容性或其他宿主因素。日志中的
`slduiu.dll` 帧不能单独确定最初错误来源。

`ISupportErrorInfo` 封送警告在成功调用中也出现，不能单独作为失败原因。
超时后清理触发的 `WorkerStartupError` / `REGDB_E_CLASSNOTREG` 是后续错误，
不能取代首个超时，也不能倒推首次 COM 激活失败。

## 诊断基线

MacSW `498e3883b4a53a6c673e1e21d171a244282a9ea1` 同步 gitlink 与
`config/versions.env`，固定 SWCLI
`93d40e274be9d3714ccab00905fc36a6675fc195`（`0.1.0a6.dev0`）。
[37732440131](https://github.com/YJBeetle/MacSW/actions/runs/37732440131)
使用这一版本全新安装。构建、安装及可见模式就绪成功，但共享建模失败，
准确失败步骤为 `SOLIDWORKS installation & runtime` /
`Shared modeling then driving dimensions on one host`。

首个矩形操作成功，用时 113.723 秒；`CreateCenterRectangle` 已返回，用时
14.399 秒，几何校验 31.206 秒。随后首次拉伸已经返回原生特征，并进入
`EditRebuild3` 之后的特征错误诊断。截止超时前，同一请求有 90 个已完成的
原生边界记录，累计覆盖约 80.572 秒；其余时间包含未单独记录的方法。
最后未配对的是 `GetNextFeature`，它在总预算只剩约 1.4 秒时开始，之前同名
调用多次用时约 0.6–1.8 秒。不能仅凭这条未配对记录认定该方法死锁；
本轮证据更支持大量慢调用累计用尽预算，而非单一矩形创建方法长期不返回。
它还不能确定宿主变慢的原因，也不能解释上一轮独立的关闭异常。

CI 设置 `SWCLI_TRACE_NATIVE_CALLS=1`，在普通 daemon 日志里记录立即刷新的
调用开始、结束与耗时。它不修改原生参数、几何断言、租约或恢复策略。
按 `(worker_pid, request_id, sequence)` 配对事件；`end` 只表示调用返回，不表示
业务成功。只对已经覆盖的调用边界作判断，不能把日志空白解释为任意原生方法阻塞。
在既有 `93d40e2` / `f75a56f` 证据中，请求前的 `RevisionNumber` 探测和直接
`CloseDoc` 没有独立方法边界；后述版本只补齐 `CloseDoc` 的边界。
详见 [运行适配器与诊断约定](runtime-ci.md#原生调用分段诊断)。

`37736636613` 使用 MacSW `0bf251e94ce2420446ec3f6376e584bbb32968f7`，
SWCLI 固定版本未变。构建和官方基底缓存恢复成功，可见模式自有 PID 488 就绪。
矩形、拉伸、圆及草图检查分别用时约 55.971、48.371、103.160、111.440 秒。
第一次切除返回原生特征并进入重建后的诊断遍历；超时前 87 个已完成调用边界
累计约 77.901 秒，最后 `GetNextFeature` 开始时只剩约 1.8 秒。这再次支持
累计慢调用消耗预算，不证明最后一个方法死锁，也不解释前述关闭异常。

该轮在共享门禁期间每 15 秒从 macOS `/bin/ps` 采集已知 Wine 进程的 CPU、
累计 CPU 时间、RSS 和状态，同时记录系统负载及空闲磁盘。输出只含数字、固定
进程名及受限状态字段，不包含原始命令行、参数、环境、模型数据或工具 stderr。
诊断失败只记录错误类别，不代替 CAD 结果；记录进入既有 `.log` 脱敏屏障。
RSS 是宿主 `ps` 的观测值，尤其在 Rosetta 下不等同于真实物理 footprint。
每个门禁有独立的经过时间；不得直接比较它与 Windows worker 的 monotonic 时钟。

37 次采样中，SOLIDWORKS CPU 使用率中位数约 177.1%，Python 两个进程的
采样中位数为 0%；1 分钟负载范围约 5.0–18.2，可用磁盘始终超过 21 GB。
这说明主要 CPU 活动在 SOLIDWORKS/Wine 宿主，而非 Python 的协议处理；
不能单凭百分比确定是哪条线程、渲染、Rosetta 或 Wine 模块导致慢调用。

## 当前改进版本：请求级原生 API 批次状态

性能改进首次集成时的 gitlink 与版本配置固定 SWCLI
`f75a56f05ae8246749514dbaf36d49a79b2cf495`（`0.1.0a6.dev0`）。
本机另一独占可见实例 PID 1004 对同一后台文档完成只读对照：
`CommandInProgress=false → true → false` 时，相同 18 个特征的诊断遍历分别
用时 4.308、0.086、4.280 秒。原值已恢复，测试实例正常退出。
首次对照启动时本机许可服务未运行，尚未进入对照即失败；恢复后从新实例执行，
这个启动失败不计入建模或耗时结论。

按 SOLIDWORKS [官方说明](https://help.solidworks.com/2024/english/api/sldworksapi/SolidWorks.Interop.sldworks~SolidWorks.Interop.sldworks.ISldWorks~CommandInProgress.html?format=P&value=)，
该标志用于减少连续进程外 API 调用期间的中间更新。SWCLI 当前将它限定于
daemon-owned 宿主的单个请求，结束后恢复并验证原值；共享交互实例不改变。
恢复失败会中止 worker、清理精确的自有 SW PID 并要求显式重启，不续用未知状态。
断言、租约、120 秒预算、可见/隐藏顺序均不变。该改进已经通过下面列出的门禁，
但正式托管 macOS 运行尚未完成，不能宣称托管超时或独立的关闭异常已经修复。

### 改进版本的门禁结果

以下均使用 SWCLI `f75a56f05ae8246749514dbaf36d49a79b2cf495`。
每个模式内部连续执行建模 → 驱动尺寸，没有更换 daemon/SW；所有结果均为
`success=true`、`state=completed`、清理错误为零。

| 宿主 | 模式 | 原生 PID | 建模事件 | 尺寸事件 |
| --- | --- | --- | --- | --- |
| [Windows 正式 CI 37740915090](https://github.com/YJBeetle/SWCLI/actions/runs/37740915090) | 可见 | 2424 | 97 | 242 |
| 同一 Windows CI | 隐藏 | 1744 | 97 | 242 |
| 本机主 bottle | 可见 | 1332 | 85 | 242 |
| 本机主 bottle 的另一完整序列 | 隐藏 | 1972 | 85 | 242 |
| workspaceroot 独立 Linux/Wine 容器，叠加当前源码 | 隐藏 | 620 | 97 | 242 |

Windows CI 的四份共享结果及可见/隐藏 box BMP 已下载核对，两张图均显示实体。
本机重新打包 App 并显式同步 Windows backend，旧包有可恢复副本；文件仍集中在
原有独立测试目录。两个模式均以空文档列表正常停止 daemon。Linux 使用既有
`localhost/swcli-a5-probe:20261008` 基底，挂载当前源码和共享脚本；仅用于集成
回归，没有改动镜像标签或晋升镜像。正常停止 daemon 后已移除专用测试容器，
主机与本机保留生成的结果和日志。

[MacSW 正式 CI 37741088903](https://github.com/YJBeetle/MacSW/actions/runs/37741088903)
使用本仓库 `71f23a7909e71e870b06bb083b2af634d293b681` 和相同 SWCLI 指针。
构建、全新安装及官方基底快照成功，运行门禁失败，准确步骤为
`SOLIDWORKS installation & runtime` / `Shared modeling then driving dimensions on one host`。
首个失败为请求 `0d553828-551f-47ff-b946-b85ef048e0e0` 的后台模型关闭，返回
`0x800703e6`，不是 `WorkerTimeout`。建模记录共 56 个事件；另两次关闭失败属于
清理，尺寸和隐藏模式未进入。此前矩形、拉伸、切除的操作最大耗时分别约
23.107、18.648、13.419 秒；这轮已越过原来的累计慢调用失败点，但不是整个
托管流程通过的证明。该原生关闭异常在启用批次状态之前也已出现。
27 次宿主采样的 SW CPU 中位数仍为约 176.1%，Python 为 0%。
具体跨宿主证明边界见 SWCLI 的
[验证记录](https://github.com/YJBeetle/SWCLI/blob/main/docs/verification/macsw-background-rectangle-2026-10-08.md#request-scoped-implementation-validation)。

当前 gitlink 与版本配置已同步为
`fb147c19e65a4d4b2a84e8e8c140c1589171c54e`。它只为既有 `CloseDoc` 调用增加
可选、立即刷新的 begin/end/error 日志，沿用同一诊断开关，不记录文档标题或
原生参数，也不改变关闭顺序、异常结果或门禁。621 项便携测试通过，8 项仅
Windows 可执行的测试在本机跳过。新托管运行 `37746169893` 仍失败在共享建模的
关闭阶段；首个 `CloseDoc` 的 begin/error 间隔约 0.641 秒，后续两次清理关闭
分别约 0.459 和 0.473 秒，也返回同一
错误，不能把它解释为 120 秒预算耗尽。此次位图修复与该关闭异常分别跟进。

#### CloseDoc 的下一层证据边界

`37746169893` 首次关闭的是已保存、未修改的后台模型，但随后前台空零件也
返回同一异常，不能把故障限定为非活动文档。三次均在 SW 的界面线程捕获
execute access violation，再经 COM 转为 `0x800703e6`；这不是整个进程退出的证明。

现有 SEH unwind 记录的最内层返回位置为 `slduiu.dll + 0xa43d95`。对本机相同
布局 DLL 的只读检查表明，该位置前的间接调用处于 OpenGL 上下文 fallback
分支：先调用 `wglGetCurrentContext`，为空时再从一个 SW 对象取得上下文，
之后调用 `wglMakeCurrent`。这把调查范围缩小到关闭时的上下文/对象生命周期，
不证明 Wine 返回值错误、SW 对象损坏的来源，也不能单凭本机 DLL 布局替代 CI
二进制的一致性证明。后续应采集 Wine 自带 `wgl` 绑定日志作成功/失败对照，
仍保留原关闭顺序、120 秒预算、异常和几何断言；不把提前渲染或重试当作修复。

本机同一主 bottle 的另一可见自有 PID 1856 已在仅增加 `wgl` 和请求边界日志
的情况下，通过原有共享建模全部 85 个事件、零清理错误，7 次 `CloseDoc` 均
返回成功，用时约 0.365–0.864 秒。结果仍集中在原目录：
`close-wgl-modeling/modeling.json`、`close-visible-wgl-daemon.log`。
这份成功对照不证明托管故障已修复；CI 适配器现补上同类 `wgl` 日志，不改变
CAD 操作、参数或门禁，也不启用逐 GL 函数 trace。

#### 新门禁先暴露宿主 OpenGL 初始化失败

新增 bitmap-only FBO 后的运行
[37761317878](https://github.com/YJBeetle/MacSW/actions/runs/37761317878) 和带 WGL
日志的 [37763677305](https://github.com/YJBeetle/MacSW/actions/runs/37763677305)
均通过构建及安装/缓存校验，却在 SW 启动前的 `bitmap-driver` 阶段失败，
不是新的 `CloseDoc` 复现。八组 DIB 都选择格式 7、flags 120
（含 `PFD_GENERIC_FORMAT`），`wglCreateContext` 失败；探针记录已打印，但 Wine
loader 未及时结束，外层 60 秒截止。不能仅将其归为慢调用。

后者明确记录 `macdrv_OpenGLInit → init_context → CGLChoosePixelFormat`
返回 `10002 / invalid pixel format`，driver 初始化返回 `STATUS_NOT_SUPPORTED`。
与 Wine 原源码请求相对应的是主显示器 mask + 加速 legacy CGL；因此当前证据
证明此请求在托管环境不可用，不证明所有 renderer 不可用、FBO 像素错误或
之前关闭异常已找到根因。现追加不依赖 Wine/SW 的双架构 CGL 观察，区分显示器
约束、加速能力和 Rosetta 的影响，不修改 CAD 调用或将失败模式静默跳过。

本机 ARM64 与 x86_64 原生观察均取得 Apple M2 Max 加速 legacy 上下文及
Apple Software Renderer；两种 renderer 都报告 FBO、blit 和 packed depth/stencil
扩展。软件模式只作能力观察，未用于 SW 或门禁，不能宣称软件路径已经验收。
另外，本机与 `37746169893` 中十个被记录的 VC 运行库文件哈希全部一致；这
排除了这些文件的版本差异，但不等于所有安装内容相同。

### 独立跟进：本机 BMP 白图

隐藏序列完成后，重开它生成的模型并执行严格 STEP 导出成功；800×600 的
等轴测 BMP 虽通过文件与尺寸检查，实际却是纯白图，不能计为渲染成功。
另一可见自有实例 PID 396 对同一只读模型按 `CommandInProgress=false → true →
false` 渲染，三张图均只有一种 RGB 颜色。随后显式调用官方
`IModelView.GraphicsRedraw` 的同类对照也均为白图。
另一个自有可见实例 PID 1880 中，用户将 SW 切到前台并确认模型区能看到实体。
同一模型、相同参数的前台渲染仍为白图，前后 BMP 的 SHA-256 完全相同；
只读测量返回 5 个实体，均有非零体积。因此单纯切前台未改善本次捕获结果，
可见场景与 BMP 捕获存在差异；下面的原生日志进一步缩小捕获失败路径，但不能从
这次对照宣称旧版本渲染正常。它与累计调用延迟、原生关闭异常
分别跟进，不通过改动几何门禁、重试建模或中途重启来掩盖。

#### 位图像素格式与离屏 drawable 对照

同一本机主 bottle 的自有可见实例 PID 2020 直接调用 `SaveBMP`，绕过 CLI 的
尺寸校验，分别请求 800×600、0×0 和 1600×1200。0×0 产生窗口大小的
2398×1181 位图，但三张图都只有一种 RGB 颜色，不能归因于固定导出尺寸。

另一个自有可见实例 PID 528 启用 Wine 内建 `wgl`、`opengl`、`bitblt` 日志。
在实际 `SaveBMP` 调用内，GDI 先填充白色位图；`ChoosePixelFormat` 随后请求
`PFD_DRAW_TO_BITMAP | PFD_SUPPORT_GDI | PFD_SUPPORT_OPENGL`（`0x38`）。
winemac 提供的 720 个格式均缺少 `PFD_DRAW_TO_BITMAP`，最终返回 0。
本次捕获没有取得位图 OpenGL 格式，尽管 `SaveBMP` 仍返回成功、文件也存在。
这是捕获失效的直接证据，不是实体缺失或窗口未切前台的证据。

一次未提交的最小试验只为支持 pbuffer 的单缓冲格式声明 bitmap/GDI 能力。
构建和静态契约检查通过，真实实例 PID 1612 的 `ChoosePixelFormat` 改为返回
109，但随后 `CGLCreatePBuffer` 返回 `10005 / invalid drawable`，BMP 仍为白图。
不依赖 SOLIDWORKS 的 8×8 DIB/WGL 最小程序也停在 `wglMakeCurrent`，64 个
预期红色像素均未产生。因此只增加能力标志不足以实现位图绘制；此试验未纳入
生产补丁，相关构建和清单改动已撤回。

进一步绕过 Wine，直接运行本机 CGL 最小程序：硬件渲染器 `Apple M2 Max` 和
`Apple Software Renderer` 都能创建上下文，但 rectangle/2D、RGB/RGBA 四组
`CGLCreatePBuffer(8, 8, ...)` 均返回同一错误。x86_64 和 arm64 程序结果一致。
该结果只证明本机 macOS 15.8 的这条旧式离屏路径不可用，不单独判定 Apple
缺陷，也不宣称所有 macOS 版本或硬件都有相同问题。

证据集中保存在既有 `C:\Workspace\MacSW-trace-20261008.6A0yEq`：
`render-native-sizes.log`、`render-native-capture-trace.log`、
`render-native-bitmap-patched.log`、`bitmap-opengl-minimal-patched.log`，以及
`bitmap-opengl-probe.c`、`cgl-pbuffer-probe.c` 和两种架构的 CGL JSONL 结果。
失败的标志试验保留为 `bitmap-format-experiment.patch`，不作为可用修复。

Windows 正式 CI 的可见和隐藏 BMP 均已核对有实体；Linux 的补充对照见下节。
后续修复必须同时验证像素内容与原有建模/尺寸序列，不能仅以
`ChoosePixelFormat` 非零或 `SaveBMP=true` 作为成功。

#### workspaceroot Linux 补充对照

同日使用现有 `localhost/swcli-a5-probe:20261008` 基底及 SWCLI
`fb147c19e65a4d4b2a84e8e8c140c1589171c54e` 源码覆盖层，启动专用 Podman 容器。
运行环境为 Wine 11.16、SW `33.5.0`、Xvfb 和 Mesa llvmpipe。
自有隐藏 PID 616 和另一自有可见 PID 1464 分别通过真实 CLI，只读打开
Mac 的同一模型副本与此前 Linux 门禁模型，并导出 800×600 等轴测 BMP。

| 模型来源 | 隐藏模式 RGB 颜色数 | 可见模式 RGB 颜色数 |
| --- | --- | --- |
| 在 Mac 上产生白图的同一个模型 | 3683 | 3700 |
| 此前 Linux 共享建模门禁 | 3650 | 3737 |

四张图均已逐张目视核对包含实体，不仅是背景渐变；四次测量均为 5 个实体，
总体积约 `308558.406140636 mm³`。Mac 模型副本 SHA-256 与本机源文件一致：
`e77c6e4c461226ffd507700824e8d4a609ea318944eab2bdfc633ebeb2d5c438`。
同一个不依赖 SW 的 8×8 DIB/WGL 程序在 Linux 也通过：位图格式选择成功，
上下文绑定成功，64 个预期红色像素全部正确。

每个模式内部未重启宿主；结束时文档列表均为空，daemon 正常停止，专用容器
随后移除。原镜像、公开标签和其他容器未改动。产物与日志保存在 workspaceroot
`/tmp/swcli-bmp.ETxLrC/output`，本机副本为 `/private/tmp/swcli-bmp-linux.En0KlH`。
因此这次白图在已测 Linux 环境没有复现，证据指向 Mac 的 winemac/CGL 图形
路径；这仍不是所有 Wine 版本、Linux 图形后端或 Mac 硬件的普遍保证。

#### 修复候选：FBO 离屏路径

补充的不依赖 Wine/SW 的原生 CGL 程序使用兼容上下文和
`GL_EXT_framebuffer_object`，创建 RGBA8 颜色附件与 24 位深度/8 位模板附件。
在本机 x86_64、arm64 两种架构上，`Apple M2 Max` 与
`Apple Software Renderer` 四组测试均得到完整 FBO、零 GL 错误，64 个红色
像素全部正确。源码与结果继续放在原测试目录：`cgl-fbo-probe.c`、
`cgl-fbo-x86_64.jsonl`、`cgl-fbo-arm64.jsonl`。Apple 的
[离屏绘图文档](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_offscreen/opengl_offscreen.html)
也将 FBO 列为优先的离屏绘制方式。

这只验证替代图形能力可用，没有修改日常驱动，也不等于 `SaveBMP` 已修复。
Wine 11.16 的现有通用 FBO surface 实现在 EGL 条件分支内，使用 named/DSA
调用；不能直接作为 winemac 的兼容上下文实现照搬。正式修复需验证默认帧缓冲
与 FRONT/BACK 映射、上下文切换、深度/模板语义、内存 DC 像素同步及资源释放，
再通过独立 DIB/WGL 探针、真实 SW 四视图/尺寸导出和未削弱的共享建模门禁。
只在最小标志改动上继续尝试不能覆盖这些职责；上述候选对照阶段没有替换生产驱动。

#### 修复实现：bitmap-only FBO

`0008-winemac-bitmap-framebuffer.patch` 为 winemac 新增两个 bitmap-only 格式，
追加在原格式之后，窗口格式编号、窗口绘制与原有 pbuffer 路径保持不变。它使用
独立的 legacy CGL share group、RGBA8 颜色及 24 位深度/8 位模板附件，并将
逻辑默认帧缓冲和 FRONT 系列缓冲映射到内部 FBO。格式不宣称双缓冲、MSAA、
accum 或 render-to-texture 能力；资源创建/释放时恢复原 CGL 上下文。
现有 Wine 在这类独立 legacy share group 中不公开应用级 FBO 扩展，探针如实
记录 `application_fbo_available=false`，不把未公开扩展算作通过的能力。

最初修复虽可绘制，却在真实 SW 的 24 位 BMP 中出现条纹：原有内存 DC 同步
把像素直接当作四字节 BGRA。最终实现仅在 FBO drawable 路径使用 GDI 格式
转换器与 32 位 staging buffer，处理 24/32 位、行补齐及上下方向，并恢复 GL
pixel-store 状态；旧窗口和普通 pbuffer 的同步路径不变。

仓库中的 `scripts/diagnostics/check_bitmap_opengl.c` 在本机主 bottle 通过八组
真实像素测试：24/32 位 × 宽度 7/8 × top-down/bottom-up。每组均验证初始蓝色
GDI 上传、全部红色像素、24/8 深度模板、逻辑默认帧缓冲、FRONT_AND_BACK、
上下文切换、双色行方向和 pack 状态恢复；GL 错误均为零。最初 CGL share-format
失败及后续 24 位条纹结果仍保留，不作为成功证明。

真实 SW 对原只读五实体模型直接 `SaveBMP` 的 800×600、窗口大小 2398×1181
及 1600×1200 三组均产生非白像素；800×600 已查看为正常实体、无条纹。
可见 daemon-owned PID 820 随后连续通过未修改的共享建模和尺寸门禁，分别为
85 和 242 个事件、清理错误为零，再通过 CLI 生成 isometric/front/top/right
四张 800×600 BMP，RGB 颜色数分别为 4077/624/3330/702；已查看等轴测与前视图。
各操作在同一 daemon/SW 中完成，最后只读文档关闭且 daemon 正常停止。

另一隐藏 daemon-owned PID 1184 也在同一实例内连续完成 85 个建模和 242 个尺寸
事件，清理错误均为零；随后同一只读模型的四视图全部成功，RGB 颜色数按上述
视图顺序为 4026/685/3230/786。四张 BMP 均已逐张查看为正常实体，无白图或
条纹。最终文档列表为空，daemon 正常停止，原模型 SHA-256 仍为
`e77c6e4c461226ffd507700824e8d4a609ea318944eab2bdfc633ebeb2d5c438`。
这证明已测隐藏模式，不等于最小化、移出屏幕、所有 macOS/硬件均已逐项验证。

重新编译最终探针后，`bitmap-opengl-final.log` 的八组测试全部通过、GL 错误均为
零。现有 `make app` 及 App 清单/模块/签名校验通过，`make test` 通过 66 项
MacSW Python（1 项跳过）、141 项 Swift、621 项 SWCLI（8 项平台跳过）。

证据继续集中在原测试目录，主要为 `bitmap-opengl-fbo-v3.log`、
`render-native-fbo-v3.log`、`fbo-visible-modeling/`、`fbo-visible-driving/`
以及对应的 `fbo-hidden-*`、四视图 BMP/JSON。这轮不改 SWCLI 操作、协议或几何断言。
本机构建、实际绘制与共享序列通过不能替代托管 CI、其他 Mac 硬件或版本证明，
也不宣称独立的托管 `CloseDoc` 异常已解决。

## 本机交叉验证

托管 CI 后续确认了仅软件 renderer 的环境，见
[软件 renderer 兼容待办](software-renderer-compatibility.md)。`0009` 是独立的
初始化回退候选，不能用它推定此文记录的 `CloseDoc / 0x800703e6` 已解决，
也不能将 `0008` 在本机硬件上的通过扩展为软件 renderer 验收。

2026-10-08 使用重新打包的 `build/app/MacSW.app` 和日常主 bottle，保留旧
Windows backend 后，仅同步 SWCLI Python 包。测试文件集中在一个独立的
`C:\Workspace\MacSW-trace-20261008.6A0yEq` 目录，没有修改安装样例或用户模型。
以自有可见模式启动，SW PID 376、版本 `33.5.0`，启用同一调用诊断。

共享 `verify-modeling.py` 已完成：`success=true`、85 个事件、清理错误为零，
包含 `native-model`、`reverse-cut`、`rejected-cut-then-sketch` 三个用例。
后台操作、保存关闭重开、预期原生失败后的继续建模均在同一宿主上通过。
第一次 `CreateCenterRectangle` 用时约 1.2 秒。MacSW 适配器没有传入可选的安装
Part/Assembly 样例，因此 85 个事件不等同于 Windows/DockerSW 含样例导出的
97 个事件。随后 `verify-driving-dimensions.py` 也在同一 PID 376 上完成，
`success=true`、242 个事件、清理错误为零，front/top/right 的驱动直径、
修改后的实体指标、保存重开及引用重新发现均通过。

可见序列完整完成并正常停止 daemon 后，独立启动隐藏模式自有 PID 1116。
同一 PID 内建模和尺寸门禁也分别完成 85、242 个事件，`success=true`、清理错误
均为零。两组序列内部都没有重启；正常停止前，文档列表均为空。
隐藏序列的矩形、拉伸、驱动尺寸修改最大操作耗时分别约 2.635、1.693、0.935 秒。
这是本机这一轮的时序观测，不是可见/隐藏的严格因果对照：启动配置同时涉及
`UserControl` 和 `UserControlBackground`，实例和预热顺序也不同。

本机 macOS 为 15.8，本轮构建 runner 为 14.8.9，均为 arm64。
本机与 `37730038675` 的 `msvcp140`、`msvcp140_2`、`vcruntime140_1`
文件 SHA-256 完全相同且含 Wine builtin 标记，不能仅凭这些标记解释两端差异。

此结果仅证明本机现有主容器在该次可见与隐藏序列中通过，不是托管 runner、
全新安装、缓存恢复或 GUI 交互的替代证明，也不是故障已经修复的结论。

## 后续收口

1. 取得诊断 CI 的首个失败及最后已覆盖调用；若失败发生在未覆盖边界，只增加
   相应方法的开始/结束记录，不先改变调用顺序。低性能 CI 的预算调整单独记录，
   不把延长等待本身称为原生故障修复。
2. 本机共享建模 → 尺寸的可见与隐藏序列均已完成；继续对照托管宿主慢调用，
   每个正式门禁序列内仍不得更换 daemon/SOLIDWORKS。
3. 只有具体调用和宿主证据支持时才修改 Wine/MacSW 或 SWCLI；修复后重新执行
   未削弱的共享门禁，并分别记录本机、全新安装和缓存恢复的结果。
4. 当时的 Windows backend 升级仅是可恢复的显式测试操作；正式 App 的自动同步
   已在后续独立修复，见下方升级记录，不把部署问题与托管 CI 的原生异常混为一项。
# 托管拉伸后的诊断阻塞（2026-10-09）

[CI 37833182637](https://github.com/YJBeetle/MacSW/actions/runs/37833182637)
使用 MacSW `fd8d65b` / SWCLI `d5fc84b`，构建、安装基底验证、八项软件
renderer 位图探针和可见 SW 启动通过。后台 front 矩形 100×50 mm、中心
(10,20) mm 已通过；第一次 20 mm 拉伸随后超过原有 120 秒期限。
此次没有到达切除或尺寸测试，不能拿它确认上轮切除问题已修复。

请求 `26c1d990-acbf-4098-93ef-c341c5028e6f` 的特征名称／类型读取均返回，
`EditRebuild3` 约 1.019 秒后返回；紧接着诊断遍历的 `FirstFeature` 只有
begin，无 end/error（sequence 78）。Python 空闲，SW 的 CPU 持续约
216–219%。这定位到最后进入的读取边界，但尚不能区分 SW、COM 或 Wine
内部的等待／忙循环。超时后的 `REGDB_E_CLASSNOTREG` 属于清理失败，不是
首次启动失败。

下一轮在现有 `HostMetrics` 内增加一次只读 `/usr/bin/sample`：同一原生
边界连续观察至少 30 秒未变化，且只有一个明确属于 daemon 的隔离 CI SW
进程时，采样 2 秒，工具期限 4 秒，每个模式最多一次。输出为
`visible-native-stall.log` / `hidden-native-stall.log`，通过既有日志脱敏屏障
后上传，关联请求／调用／Unix PID 写进 host metrics。缺少工具或采样失败
只记录诊断缺口，不修改原 CAD 结果。不挂调试器、不暂停宿主、不调用 COM、
不重试、不放宽期限／几何断言、不在建模与尺寸之间重启。

SWCLI 同步到 `e063136` 的有范围矩形 `AddToDB` 修复，以保持两宿主开发门禁
版本一致；该改动处理 Windows 的独立矩形吸附问题，不作为托管阻塞修复
结论。公共产品版本和已发布镜像不变。

## 既有容器的 SWCLI backend 升级（2026-10-10）

之前仅官方安装和 CI prepare 会复制 Windows Python/backend；换 App 后通常只更新
macOS client，日常主容器的 `C:\\MacSW\\Python311` 可能继续使用旧代码。

现在安装器、App 启动/手动启动以及需要 Windows backend 的 CLI 入口共用
`swcli_runtime.py`。打包生成含公开版本、源码 commit 和全部文件 SHA-256 的清单，
验证阶段核对清单身份及文件内容。部署先校验 App 源 payload，再对目标逐文件检查，
包括缺失、损坏及多余的旧模块；正常 Python 缓存不触发替换。

一致时不启动 Wine 进程、不改 backend 文件。需要升级时，以非阻塞文件锁排除同时
部署，并使用当前 `WINEPREFIX` 的 tasklist 检查 Python/pythonw 进程；不能确认占用
状态时也拒绝覆盖。进程查询用临时文件捕获 tasklist，避免 Wine 常驻后代持有
管道句柄导致已完成查询仍等待 EOF。不同容器里同名 Python 不计入当前容器占用。

新目录完整暂存、校验，并在发布前再次检查占用；现有目录移动到同级
`.Python311.previous` 后发布新目录，发布失败则恢复旧目录，下次执行也能恢复
中断后的旧目录。最近一次旧版本保留在这个固定备份位置，更早的备份会在下一次
成功准备替换时清理。部署文件操作只管理 Python311，不修改 SOLIDWORKS 和文档，
也不直接写入注册表；进程探测仍会启动 Wine，不能将它称为完全无副作用的离线检查。

`daemon stop/status` 使用现有 backend，不受待升级状态阻挡；其他 Windows 入口在
同步失败时停止，不继续启动旧代码。Native typed client 不自动启动或接管 SW。
App 准备任务在后台执行，失败可见且可重试，删除/重装容器前会等待部署结束。

隔离 Wine 容器实测：旧 backend 和旧模块被完整替换；Windows Python 实际导入
`0.1.0a6`，模块路径在 `C:\\MacSW\\Python311`；运行中的 Python 阻止升级，旧清单
字节未改；停止后同步成功，重复同步保持 python.exe inode/mtime 不变。

正式 App 已打包、校验并替换，旧 App 保留为
`build/app/MacSW.before-backend-sync-20261010.app`。启动新主 App 后，既有主容器
自动生成部署清单，源码 commit 为 `7896adf47ff75dd8e4dfa043519b30a563931a53`，
全部 payload 与 App 一致，重复同步不写盘，前一份 Python runtime 保留。
主 SOLIDWORKS 已正常退出并重启；专用端口 18505 上的测试 daemon 显式 attach
主实例（Windows PID 1868、revision 33.5.0、owned=false），能力及文档列表查询
通过。测试 daemon 已停止，不关闭共享主 SOLIDWORKS。

CLI 路由回归、149 项离线测试（跳过 1）、146 项 Swift 测试均通过。本机默认测试
Python 缺少 jsonschema，完整脚本中的 SWCLI 阶段因此失败；使用 App 已打包且
经过验证的原生 Python 重跑当前固定源码，847 项 SWCLI 测试通过，跳过 8 项。
没有为此修改宿主 Python、SWCLI gitlink 或公开版本。以上不是托管 CI 门禁结果。

这不等同于 Wine 容器升级支持。后者仍需单独记录 Wine/补丁身份，停止所有容器
进程并备份完整前缀，显式执行 wineboot 迁移，再覆盖字体、许可、COM、建模与保存
重开回归。只有成功后才能更新迁移记录；失败应恢复旧运行时和对应的前缀备份。

# MacSW 开发说明

安装与日常使用见 [中文 README](../README.cn.md) / [English README](../README.md)。
这里保留构建、安装实现和兼容性修复细节，不作为全部功能已验收的声明。

## 构建与测试

工具链需要支持 Swift 5.10，并提供 macOS SDK、Xcode Command Line Tools；Wine 构建
依赖 Homebrew 的 Bison 和 MinGW-w64。源码检出时应包含 `Dependencies/SWCLI` 子模块。

```bash
brew install bison mingw-w64
make app
```

产物为 `build/app/MacSW.app`。可直接打开构建产物：

```bash
open build/app/MacSW.app
```

常用目标：

```bash
make test                 # Swift XCTest、SWCLI Python 契约及宿主接线测试
make app                  # 构建、打包并校验 MacSW.app
make verify               # 校验已有 MacSW.app
make archive              # 生成 zip，会占用额外磁盘空间
make dmg                  # release disk image and SHA256SUMS in build/dmg (docs/packaging.md)
make ci                   # 测试并生成归档
```

`make test` 的 Python 测试需要 SWCLI 的 `jsonschema` 等依赖。使用隔离环境，避免修改系统 Python：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install ./Dependencies/SWCLI
PATH="${PWD}/.venv/bin:${PATH}" make test
```

首次构建联网获取固定依赖并验证 SHA-256；下载及 Wine 模块构建结果缓存于 `dist/`。
`build_winemac.sh` 的缓存身份包括 Wine 版本、源码校验值、全部补丁、配置及脚本内容。
每次打包只保留最终 `MacSW.app`，不累计保留含完整 Wine 的旧 App 副本。

签名默认为 ad hoc。设置 `MACSW_SIGN_IDENTITY`（证书名称或 SHA-1，可选
`MACSW_SIGN_KEYCHAIN`，钥匙串需事先解锁）后，`package_app.sh` 和
`package_solidworks_app.sh` 用该身份签名 App 包；指定要求（designated requirement）
是证书而不是 cdhash，重新构建后 macOS 的隐私授权仍然有效。打过补丁的 Wine 模块始终
ad hoc 签名：其 SHA-256 是 BuildManifest 中的运行时身份，证书签名含签名时间，不可复现。
校验脚本两种签名都接受；设置了 `MACSW_SIGN_IDENTITY` 时只接受证书签名。见
`scripts/lib/codesign.sh`。

打包时 `package_app.sh` 会去掉 16 个自行重建的 PE 模块（含补丁 0037 的 `glu32.dll`）的 DWARF 调试信息和
COFF 符号表（前 15 个共约 72 MB，去除后约 12 MB；见 `scripts/lib/strip_pe.sh`），Wine 的 builtin 标记保持不变，
BuildManifest 里的 SHA-256 是去除符号后的文件的哈希。`dist/winemac-*` 中的缓存仍带符号，
可用于调试，也不会使 `build_winemac.sh` 的缓存失效。需要 MinGW-w64 的
`x86_64-w64-mingw32-strip` 和 `i686-w64-mingw32-strip`（`brew install mingw-w64`）。
设置 `MACSW_STRIP_PE=0` 可保留符号（需要符号来分析崩溃时）；BuildManifest 的
`PEModulesStripped` 记录这个选择，`verify_app.sh` 按它检查。固定的 Mono 文件不处理，
它们的 SHA-256 是固定值。

## 构建职责与依赖固定

- SwiftPM 管理 `MacSWCore`、SwiftUI App、CI 专用入口和 XCTest。
- 顶层 Makefile 编排依赖获取、构建、打包、校验与归档。
- Shell 脚本处理固定依赖下载、Wine autotools 构建和 `.app` 装配。

应用、Wine、Wine-Mono、stdole、7-Zip、SWCLI 和 Python 的版本与校验值位于
[`config/versions.env`](../config/versions.env)。MacSW 应用版本独立于 SOLIDWORKS 版本；
SOLIDWORKS 的实测版本记录在[兼容性报告](compatibility.md)，不作为 Builder 版本选择依据。
SWCLI 子模块 HEAD 必须与 `SWCLI_SOURCE_COMMIT` 的完整提交一致，打包时强制校验。
当前配置的 `0.1.0a6.dev0` 是开发快照，不代表 a6 已正式发布。

SWCLI 的纯 Python 依赖及 macOS ARM64 / Windows AMD64 的 `rpds-py` wheel 固定在
[`config/swcli-wheels.tsv`](../config/swcli-wheels.tsv)，逐个校验并保留许可证、包元数据。
App 内置 SWCLI、Windows Python 3.11、macOS 原生 Python、pywin32 和完整 JSON Schema
依赖；构建时获取、校验和展开，全新安装时一次部署到容器，使用时不联网下载运行时。
普通协议客户端原生运行，只有 `doctor` 和 `daemon` 生命周期命令使用 Wine Windows Python。

菜单栏“复制 AI 接入信息”使用 `AIConnectionInfo` 根据当前 bundle 与 `RuntimeStore.paths`
生成接入文字；`AIConnectionClipboard` 只预检随包文件并写入纯文本剪贴板，不调用 CLI、
Wine 或安装流程。端点来自 App 的 `SWCLI_ENDPOINT` 环境配置或启动器默认值，不声称
daemon 已运行。skill／指南直接引用随包原生 Python 中的完整资源，打包校验同时检查
文件存在及与固定 SWCLI 源码一致，不维护第二套建模教程或 agent 安装适配器。
复制反馈使用主运行循环 common 模式的两秒单次计时器复位，避免依赖菜单视图的异步任务；
连续点击会取消旧计时器并重新计时，菜单打开或收起均不应留下过期的“已复制”状态。

完整打包流程包括：

1. 编译 SwiftUI 启动程序，并从 C 源码重建原生辅助程序。
2. 下载、校验固定版本 Gcenx Wine。
3. 从配置指定的官方 Wine 源码构建打过补丁的 `winemac.so`、`win32u.so`、
   x64 `combase.dll` 和 loader。
4. 覆盖已验证的 Wine-Mono x86 修复模块、RegistrationServices mscorlib 和 x86/x64 托管 RegAsm。
5. 从 Microsoft NuGet 包提取、校验托管 COM 注册使用的 `stdole.dll`。
6. 打包两种 Python 运行时、SWCLI 和固定依赖，对原生模块临时签名并校验。

`win32u.so` 构建使用 Homebrew Bison 和 FreeType 头文件；运行时通过相对 RPATH
定位包内固定的 x86_64 FreeType，不依赖最终用户机器上的 Homebrew。
`BuildManifest.plist` 保留构建版本、来源提交与校验值。

## 安装实现

Bootstrap 默认静默部署官方介质：主体 MSI 使用 `/qb` 和已验证属性树；用户可以在设置中
关闭静默，交由官方向导处理。选择介质时只做目录判断，不读取介质旁的文件，不挂载 ISO 或启动
子进程；挂载推迟到“开始安装”。支持 ISO、`setup.exe`，以及在本级或一级子目录内
含 `setup.exe` / `swwi/data/solidworks.msi` 的目录。开装前校验核心 MSI、
VC++ / Login Manager / .NET 前置件。Toolbox 载荷（介质 `Toolbox/*.zip`）是可选的：
介质没有 `Toolbox` 文件夹、或其中没有非空 ZIP 时，跳过 Toolbox 部署步骤，安装摘要提示
“Toolbox 未安装”；介质补齐 `Toolbox` 后 `ToolboxService` 仍按原流程可用。

SOLIDWORKS / Simulation / Motion / MBD 序列号作为 MSI 公共属性传入，不预写注册表。
官方安装器写入 `HKLM\Software\SolidWorks\Licenses\Serial Numbers` 的
`SolidWorks` / `COSMOSWorks` / `COSMOSMotion` / `MBD`；组件范围只由 `ADDLOCAL` 决定。
MSI 详细日志会明文包含序列号属性，必须保持私人。关闭静默时，组件和序列号由官方
向导询问，App 不收集序列号。

Licensing in this fork (English, replaces the earlier discovery and managed
FlexNet description):

- Serial numbers come only from the user's own input. Nothing next to the media
  (text, `.reg`, `.lic` files) is scanned or read.
- The license source is a single choice: unconfigured (SOLIDWORKS runs Dassault's
  own activation) or a remote SolidNetWork server written as `port@host` to the
  standard `*_LICENSE_FILE` client values. A start is allowed only when the chosen
  source has valid input.
- MacSW never installs, starts or edits a FlexNet/`lmgrd` server or any license
  file, and never replaces SOLIDWORKS program files.

界面语言按 macOS 偏好在固定官方清单中预选，可由用户更改，不扫描介质内部生成清单。
不追加语言资源时使用介质自带英文；语言 MSI 在主体安装完成后静默安装。

安装阶段的 32 位托管辅助程序使用 Wine-Mono 解释器，64 位 SOLIDWORKS 使用 JIT。
App 先校验并放置固定 `stdole`，再安装官方 Login Manager；按注册表内容校验托管 COM
注册，主体 MSI 后再校验 `SldWorks.Application` 的注册链。注册校验或安装器退出码
不能单独证明 COM 激活、宿主就绪或建模成功。字体策略见[字体说明](font-fallback.md)。

## Mac folders as drive letters (DriveMapService)

`DriveMapService` (MacSWCore) keeps drive letters and profile links for the owner's Mac
folders, so nobody has to make `dosdevices` links by hand:

- `H:` the home folder, `B:` `~/Library/CloudStorage/Box-Box`, `I:` iCloud Drive
  (`~/Library/Mobile Documents/com~apple~CloudDocs`, only if it exists). Every other folder in
  `~/Library/CloudStorage` takes a letter from the pool `Y X W … J G F E` (top down, so Wine's
  mountmgr keeps the low letters for volumes). `A:`, `C:`, `D:` and `Z:` are never used; `H:`,
  `B:` and `I:` are not in the pool.
- Assignments are stored in `<Application Support>/MacSW/drive-letters.json`
  (`"cloud:<folder>": "Y"`), outside the bottle, so a letter survives a clean reinstall and stays
  reserved while its folder is missing. SOLIDWORKS.app's launcher shares the file (a `UserDefaults`
  write from it would land in its own domain, not MacSW's). Mode 0600: the keys hold CloudStorage
  folder names, which can contain an email address.
- Every cloud folder also gets a link in `drive_c/users/<user>/`: `Box`, `iCloud Drive`, or the
  provider part of the folder name (`OneDrive`, `GoogleDrive`, `Dropbox`); if that name is taken
  (case-insensitive), the full folder name. Only if the profile folder exists. The home folder gets
  no profile link: the bottle lives in it, so the link would be a cycle.
- Idempotent and conservative: a link that already points at the folder (made by MacSW or by hand)
  is kept. A cloud folder already mapped under any letter or profile name keeps it (no second pool
  letter or link); `H:`, `B:` and `I:` are still made when free, and with two letters for one folder
  Wine's `/unix` lookup and `WineDocumentPath` both use the lower one. A letter (`x:` or an `x::`
  device) or name that exists for anything else (another target, a real directory, a dangling
  link) is reported as a conflict and never removed or replaced. Turning the feature off adds
  nothing and removes nothing. Wine's msi sets `ROOTDRIVE` to `C:\` (dlls/msi/action.c), so the
  extra drives do not move an installation.
- Runs before every SOLIDWORKS launch in `RuntimeStore.launch()` (MacSW and SOLIDWORKS.app's
  launcher), in `BootstrapStore` after `wineboot -u`, and after a successful Wine migration in
  `RuntimeStore.maintainWineRuntime`. Nothing happens in a prefix without `dosdevices`.
- `maintain` finds the folders inside `FolderConsentService.bounded` (120 s, like the consent
  check): finding iCloud Drive may itself show a macOS prompt in this process. On a timeout nothing
  is mapped, the launch continues and `drive-maps.log` records it. Setting:
  `MacSW.mapMacFoldersToDrives` (default on, Settings > General).
- Consent gate: a drive letter makes Wine open the folder at every Wine start (mountmgr's
  `create_drive_devices` reads `.windows-label` and `.windows-serial` in each drive root, and the
  first process of every Wine session runs `wineboot --init`), also in Wine starts that come before
  any consent check (the font-link `wine reg query` at app start, the SWCLI daemon, Settings tools).
  So `maintain` first runs `apply(dryRun: true)` for each cloud folder alone, lists every folder that
  would get a new letter or profile link with `FolderConsentService.check` (same 120 s timeout and
  no-answer handling), and maps only the folders that come back `.granted`. Denied, no answer and
  missing are logged as `noAccess`; nothing new is made for them and the next run tries again.
  Existing links, also hand-made ones, stay as they are; a folder with nothing new is not listed
  here, because the consent check right after touches it.

Consent: `FolderConsentService.protectedFolders` reads the `dosdevices/<x>:` links as well as
the profile links, follows symbolic links on the way (`~/Box` -> Box, stopping at the first
protected folder so nothing inside one is read), and maps targets in a CloudStorage folder or
iCloud Drive to that folder ("Box", "OneDrive", "iCloud Drive"). Links to folders that only contain
protected folders (`H:` home, `Z:` /) do not count, as `Z:` never did; browsing into `H:\Library`
can therefore still reach other macOS prompts (for example other apps' data) from Wine.

## Bottle gate (WineBottleGate)

Rule: no Wine session of a managed bottle starts while a drive letter (`dosdevices/<x>:`) or a
profile link (`drive_c/users/<account>/<name>`) points into a cloud folder (iCloud Drive, a folder
of `~/Library/CloudStorage`) that the current process has not listed itself, with macOS's consent,
since it started. These are the mappings drive maps add (and the same ones made by hand). Links
into Desktop, Documents and Downloads keep the behaviour from before drive maps: listed natively
first (the consent preflight), never set aside.

Why: Wine 11.16's mountmgr opens the root of every drive letter when a session starts
(`get_filesystem_label`/`get_filesystem_serial` read `.windows-label`/`.windows-serial`,
dlls/mountmgr.sys/device.c:168,186, unixlib.c:456, synchronously from `disk_driver_entry`,
device.c:2001), and SOLIDWORKS can open a profile link at any time. The first Wine process to open a
protected folder raises its macOS prompt for Wine's responsible app and wineserver waits. MacSW
starts Wine as soon as it opens (the font-link `wine reg query`, SWCLI sync), and grants do not
carry over to an ad-hoc build (new identity) or to SOLIDWORKS.app (another app that `exec`s Wine).

Why not the shell folders: Wine links a missing `Desktop`, `Documents`, `Downloads`, `Music`,
`Pictures` or `Videos` of the profile to `$HOME/<folder>` again inside the session
(dlls/shell32/shellpath.c `_SHCreateSymbolicLink` -> mountmgr `set_shell_folder`, unixlib.c:534,
from `SHGetFolderPath` with `CSIDL_FLAG_CREATE`, `wineboot -u`, comdlg32 and others). Setting one
aside would only make Wine link the real folder again, unchecked. So these six profile names are
never moved, whatever they point at (also one its owner redirected into Box); a cloud folder behind
one of them is still listed natively first.

How:

- `WineBottleGate.prepare` (async, 120 s per folder, status line while a prompt is on screen) lists
  every protected folder (Desktop, Documents, Downloads too) that a present or held link reaches and
  this process has not opened yet (`FolderConsentService.Session.current`, grants only), then
  `apply`: a gated link (`Link.isGated`: into a cloud folder, not one of the six shell folder names)
  to a folder macOS did not let this process open (denied, no answer, gone) is moved, unchanged
  (`rename(2)` of the link), to `<prefix>/.macsw-held/<same path>`; a held link that is not such a
  link (its folder is allowed now) is moved back. Links that reach no cloud folder are never moved.
  `.macsw-held.lock` (`flock`) serializes MacSW, SOLIDWORKS.app and `wine_runtime.py`.
- Explicit `prepare` runs first in every Wine task the stores start: the app-start font-link task
  and the SWCLI sync task (`RuntimeStore`), `launch` (after `DriveMapService.maintain`, replacing the
  old consent check; its notice names the folders refused and the letters set aside),
  `handOff(documents:)` (SOLIDWORKS.app's open-documents and forward modes), the Wine maintenance
  (before `wine_runtime.py`), and `BootstrapStore` after `wineboot -u`.
- Backstop: `WineService.start` (every `makeProcess` program: reg, winepath, taskkill, start,
  msiexec, wineboot, winecfg, tools, `launchSolidWorks`, the installer path too) and
  `execSolidWorks` call `WineBottleGate.guardWineStart` for managed bottles
  (`WineRuntimeService.isManaged`), never for wineserver (`-k`/`-w` open no drive). It lists only
  cloud folders behind gated links that are new since the last `prepare` (10 s each), never waits
  for held folders again, and throws when a link cannot be set aside, so Wine does not start.
  `openDocumentsInRunningInstance` runs it before it works out the Windows paths. The store calls
  that can wait here (document hand-off, Settings tools) run off the main actor.
- `wine_runtime.py` (`prepare_wine_start`): the same rules in Python for `launch` (sw-cli daemon and
  doctor, CMD in Terminal), `run` of the loader (wineboot, reg, the backend check in an upgrade,
  rollback or recovery; not wineserver) and `swcli_runtime.py`'s `tasklist` probe. Its own process
  lists the cloud folders behind gated links (60 s each, once per process), so the prompt belongs
  to whatever app started it: MacSW for maintenance and SWCLI, Terminal for `sw-cli` typed there.
  Only for managed bottles.
- A running session is never changed: while a Wine session of the bottle runs, no link moves in
  either direction and `DriveMapService.maintain` adds no cloud letter or link (only `H:`). Both
  ask for the session after their native checks (`guardWineStart` before them too), so a session
  that another app starts while a macOS prompt is on screen is not changed either.
  mountmgr read the drive roots when that session started and a process that joins it does not read
  them again, while Wine resolves `dosdevices/<x>:` at every path: taking `b:` away would break
  `B:\...` in the running SOLIDWORKS (for example when SOLIDWORKS.app forwards a Finder open while
  MacSW's SOLIDWORKS runs), and bringing it back would let a session that another app started (one
  macOS refused Box) reach Box. Held links come back at the next start without a session.
- Session detection (`sessionRunning`, `session_running`): wineserver holds a write lock on
  `/tmp/.wine-<uid>/server-<dev>-<inode>/lock` while it lives (server/request.c `acquire_lock`,
  ntdll `init_server_dir`; read with `F_GETLK`) and takes clients on `socket` next to it. While the
  lock is held the session counts as running (fail safe: no link moves); only a cleared lock means
  no session. No new session can start while the lock is held (the server that holds it owns the
  bottle; a Wine process started then waits for it to exit), and the next start after it clears is
  gated as usual. A server that takes a test `connect` answers at once. One that does not is waited
  for up to 8 s (`sessionEndWait`) and still counts as running if its lock does not clear: a server
  that shuts down (it closes the socket first and keeps the lock for seconds more: up to 4 s, then
  the registry save; server/process.c, request.c `close_master_socket`), one that is just starting,
  and one frozen on a macOS prompt whose `listen(5)` backlog is full, so that connects are refused
  (a closed test client does not free its slot). The test connection makes wineserver count a
  client briefly, which can put off the end of an idle session by its 3 s grace time.
- Spellings: on a case-insensitive volume (`pathconf(_PC_CASE_SENSITIVE)`, the macOS default)
  paths compare without case and Unicode form (NFD), so `~/documents` is Documents and
  `~/library/cloudstorage/box-box` is Box; the home folder also counts under its real path and its
  Data volume name (`/System/Volumes/Data/Users/<me>`, a firmlink). A `..` in a link's target is
  taken from the real folder before it, as the kernel does (`standardizedFileURL` in Swift,
  `_standardized` in Python): with `~/BoxAlias` -> Box, `~/BoxAlias/../OneDrive-Personal` is
  OneDrive. Consent is keyed the same way (`Session`, `_answers`), so one answer covers every
  spelling of a folder.
- Moving back: a free name takes the link again; the same link made again is kept and the held copy
  dropped; an empty folder in its place is removed; anything else (a file, another link, a
  non-empty folder) blocks the move and is logged. Setting aside a link whose name is held already
  replaces the held one (the newer link wins).
- `DriveMapService.apply` counts held letters and profile names as taken and as present for their
  folder (`heldTargets`), so `maintain` neither makes a second `B:` nor hands a held letter to
  another folder; `maintain`'s grants go into the same session. A profile link never takes one of
  the six shell folder names (`~/Library/CloudStorage/Pictures-Acme` gets `Pictures-Acme`, not
  `Pictures`), which the gate could not set aside.
- Hand-off (ac96ef9) uses the bottle as it is after the gate: with Box's `b:` and profile link set
  aside a Box file is `H:\Library\CloudStorage\Box-Box\...` (`wine start /unix`), Documents keeps
  `C:\users\<user>\Documents\...`; once Box is allowed both come back and Box files are
  `C:\users\<user>\Box\...` again.

Not covered: a session that ends between the check and the spawn (milliseconds; the new process then
starts a session with the links as they were checked for the old one); two apps starting sessions at
the same moment; a dying wineserver that keeps its lock for more than 8 s: it counts as running, so
nothing is gated, and a Wine process started then waits for it (Wine's client retries for about 5 s)
and can start the next session with the links as they are; a `..` inside the target of a second
link on the way, or in a relative target after a link (Swift takes those `..` by the path alone;
Python takes a relative target's `..` from the real folder); a grant reset with `tccutil
reset` while the app runs (the grant is remembered for the life of the process; a grant turned off
in System Settings fails quietly instead, so Wine cannot freeze on it); Desktop, Documents and
Downloads that macOS refused or nobody answered (Wine starts with their links, as before drive
maps); and a document handed to Wine from a cloud folder that no link reaches (not checked natively
first). A Wine start outside `prepare` (Settings tools, quit and stop, MacSW's own hand-off) waits
at most 10 s for a link that is new since the last `prepare` and sets it aside if nobody answers.

Finder hand-off (`WineDocumentPath`, unchanged): a linked profile folder keeps its
`C:\users\<user>\...` path first (ac96ef9). The cloud profile links count as linked folders, so
`~/Library/CloudStorage/Box-Box/a.sldprt` opens as `C:\users\<user>\Box\a.sldprt`, the path Box
Drive uses on a Windows PC. A drive letter names only the other paths: `H:\Projects\...`, or
`B:\...` when there is no profile link. `wine start /unix` (running instance, files outside linked
folders) lets Wine pick the deepest drive root, which matches `windowsPath`'s longest-root rule.
Opening Box files as `B:\...` instead would need `folderLinks` to skip links whose target is a drive
root.

Tests (`DriveMapServiceTests`, `FolderConsentTests`, `WineDocumentPathTests`,
`WineBottleGateTests`, `scripts/tests/test_wine_bottle_gate.py`) use a fake home and prefix in a
temporary directory, a fake `list` for macOS and their own consent session; they never read the
real home, CloudStorage or iCloud Drive and never start Wine.

## Wine 兼容性修复

补丁保留 SOLIDWORKS 自身窗口几何和硬件加速，不由守护程序移动或缩放视口。

### 视口图层裁剪

原版 `winemac.drv` 没有把 Win32 子窗口可见区域同步给硬件加速视口的 macOS 原生图层，
导致视口覆盖 FeatureManager 等停靠控件。
[`0002-winemac-metal-layer-clipping.patch`](../patches/wine-crossover/0002-winemac-metal-layer-clipping.patch)
从 HDC 读取 `SYSRGN`，转换为视口本地坐标及 Core Animation 遮罩，仅在窗口布局改变时更新。
详见[视口裁剪调查](winemac-opengl-child-clipping.md)。

### 前缓冲刷新

Wine 在应用已调用 `glFlush` / `glFinish` 后，额外调用交换双缓冲的
`NSOpenGLContext.flushBuffer`。SOLIDWORKS 的前缓冲选择、预选与局部 UI 因此在
空白点击或失焦后丢失模型画面，橙色边线预选只闪现。
[`0004-winemac-preserve-front-buffer-flush.patch`](../patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch)
将真正的交换限定于 SwapBuffers 路径；证据见[前缓冲说明](opengl-front-buffer.md)。

### 应用身份、捕获与 COM

位图导出的离屏绘制由
[`0008-winemac-bitmap-framebuffer.patch`](../patches/wine-crossover/0008-winemac-bitmap-framebuffer.patch)
实现：只为新增的 bitmap-only 像素格式使用兼容 CGL 上下文和 FBO，保留原有窗口
格式编号及窗口/pbuffer 路径；`win32u` 在这条路径将内存 DC 转换为 32 位 staging
像素，正确处理 24 位、行补齐和上下方向。补丁进入构建缓存、打包清单和校验。
这不是全局切换到软件绘图，也不改变 SWCLI 的导出实现。原生探针与实际 BMP
证据见[原生调查](native-modeling-investigation.md#修复实现bitmap-only-fbo)。

[`0009-winemac-software-renderer-fallback.patch`](../patches/wine-crossover/0009-winemac-software-renderer-fallback.patch)
是独立的软件 renderer 初始化候选：保留硬件优先，只在 legacy 加速格式不存在
时回退，继承真实加速属性，不改 SW 内部设置。状态与验证边界见
[软件 renderer 待办](software-renderer-compatibility.md)；托管环境的完整验收仍待完成。

- [`0001-winemac-macsw-branding.patch`](../patches/wine-crossover/0001-winemac-macsw-branding.patch)
  为 loader 内嵌 MacSW bundle 元数据，由 `wine -> MacSW` 链接满足 Wine 重新执行的固定路径。
  Dock 与应用菜单显示 MacSW，EXE 图标仍走 Wine 原生路径，不替换各程序图标。
- `win32u.so` 提供由 App 为 SOLIDWORKS 单独启用的鼠标捕获兼容路径。
- x64 `combase.dll` 延长 SOLIDWORKS 冷启动时首次 COM 类工厂注册等待，其他 CLSID
  保持原有上限；等待不等于重启或重试建模。补丁范围与云端证据见[运行 CI](runtime-ci.md)。

Wine 及其派生补丁使用 LGPL-2.1-or-later。App 包含许可证与精确源码说明；正式 Release
附带构建所用 Wine 源码归档，仓库保留所有补丁和构建脚本。

## 验证

GitHub Actions has one job, `build`, which runs `make test` and `make archive` as
separate steps. `make ci` remains a local shortcut for both. The upstream
`runtime-test` job (real SOLIDWORKS install and runtime gates) was removed from this
fork because it relied on non-official media, a "fake" CI serial and licensing
fixtures; see the note at the top of [runtime CI](runtime-ci.md) and the
[compatibility report](compatibility.md) for the historical results.

GUI 回归至少覆盖：

- 新建 Part 后 FeatureManager 完整可见。
- FeatureManager / PropertyManager 切换时视口不覆盖左侧面板。
- 进入和退出草图、拉伸、旋转。
- 连续点击空白画布、切换 macOS 窗口后模型仍可见。
- 边线橙色预选持续到鼠标移开。
- 浮动工具条和对话框位于视口之上。
- 保存、退出并重新打开零件。

这些是回归清单，不是本次构建全部通过的声明。

# KeyTrail 累计 v1.2 需求覆盖审查

审查日期：2026-10-27。结论：当前源码已覆盖累计功能；下列五项修复已完成整合自动化检查，仍保留指标适配和目标平台验收边界，不能仅凭这些检查宣布全平台实机验收完成。

本表以原 V1/V1.1 的需求清单、累计 v1.2 约定和后续用户修订为范围，以当前源码为实现依据。历史材料仅用于定位需求；本表不复用个人输入样本、个人数据库信息、机器路径、旧包版本或历史截图作为当前通过证据。功能覆盖以源码独立审查为基础；后续合成数据与平台检查按下述范围单独记录，没有将它们当成真实采集验收。

## 状态与证据规则

- **有实现**：已找到实际生产代码；不等于测试已执行或用户已验收。
- **适配实现**：保留需求目的，但数据形态或指标口径依用户确认的隐私边界调整，差异明确列出。
- **本轮待核验**：本轮正在修改的路径；即使文件已出现，仍需整合后的执行结果及独立复核。
- **实现缺口**：当前实现与需求仍有具体差异，可继续以代码推进。
- **平台待验收**：需要目标 OS、正常权限、用户输入、私有部署或持续负载证据。

表中的“检查来源”指仓库存在相应测试入口或断言，不代表本次重新执行。当前最终源码已实际执行 locked Cargo 122 项（Core 63、Server 21、Windows 库 38）、Swift Core 独立 14 项、Runtime 36 项、Text 34 组、Sync 11 组及调度 5 组；新增趋势与原有重连/DST 均通过 Chromium/WebKit 的合成数据检查。Docker/Wine 当前 PE 测试共 125 项通过（上述 122 项加 Windows 原生 cleanup 3 项）；这仍不是 Windows 内核验收。完整执行记录应另绑定对应源码、程序和资源版本；独立 Core 入口不能称为完整 `swift test`。Wine、浏览器手机配置、Android OS 模拟器、iOS OS 和实体设备的结果互不替代。

## 基础统计、隐私和数据管理

| 需求 | 实现状态与源码证据 | 检查来源 | 待核验或验收条件 |
| --- | --- | --- | --- |
| 原始键鼠流水 | **适配实现**：统计仅存分钟汇总、各键直方图、活动掩码和节奏聚合；不存有序物理按键流、逐次事件或光标坐标。[Rust 核心](../rust/keytrail-core/src/lib.rs)、[数据契约](implementation-contract.md) | `rust/keytrail-core/src/tests.rs` 的 schema、CSV 隐私检查；`extension_tests.rs` 的附加表检查 | 只能分析聚合，不能恢复键序、轨迹或逐次事件明细；该差异是明确的产品约束 |
| 长期累计、不自动清零、旧库兼容 | **有实现**：SQLite `user_version=1`，附加表初始化，重启保留统计；只有显式删除/清空或开启容量策略会删除历史 | Core restart、v1 bootstrap、导出快照升级测试 | 当前发布包对已有数据的升级、异常退出和备份恢复需隔离副本验证；不能用重新建库替代 |
| 键盘次数、鼠标左右中键、滚动和距离 | **有实现**：物理键归一化、过滤长按重复；鼠标只累计标量距离。[Mac 输入](../Sources/KeyTrailRuntime/InputMonitor.swift)、[Windows 输入](../rust/keytrail-windows/src/lib.rs) | Core、Runtime、Windows 宿主测试 | 真实键盘、漏释放、设备切换、第三方注入输入需平台验证；未知键仍归 `Other` |
| Windows 数字小键盘与主键区分开 | **本轮已回归**：使用既有 `Num 0`–`Num 9` 和运算/Enter 标签；新增有界锁定键/Insert/PrintScreen 标签；旧 ID 继续兼容 | 本轮 Windows 宿主库 32 项及 Docker/Wine 当前 116 项全部通过，包含归一化→直方图→CSV→复制回放及非法标签拒绝；Swift 白名单整合通过 | 宿主与 Swift 白名单整合检查通过；Windows Raw Input 目标平台验收仍保留；历史已合并记录不能反推拆开 |
| 鼠标距离为物理米 | **适配实现**：显示游标距离使用 display points（pt），不是桌面移动或人体运动；Mac 过滤大于 2,000 pt 的单次跳变 | InputMonitor 实现、Core scalar distance 与 Windows DPI 距离测试 | 多屏跨越、缩放和不同 DPI 的真实设备检查；不能把 pt 直接宣传成物理米 |
| 小时、日、周、月、年、自定义范围 | **有实现**：本地 Calendar 构造边界，查询半开 `[start,end)`；历史选择/删除精度一分钟；总览趋势按范围压缩。[趋势计划](../Sources/KeyTrailCore/OverviewTrendPlan.swift)、[AppModel](../Sources/KeyTrailApp/AppModel.swift) | Core half-open、trend；Runtime Calendar/DST；Web DST/range 脚本 | **网页全范围趋势已通过双浏览器与真实本机服务合成数据检查**，不能用自然周/月面板代替多年范围曲线；100×366 天是产品预算，不是无限期查询承诺 |
| 键盘、鼠标、去重联合活跃时长 | **有实现**：输入后 30 秒活动窗口，按已观测秒裁剪并去重；暂停/锁屏/睡眠边界截断，不为离线补时 | Core union/pause/restart、Analysis mix、Runtime 边界检查 | 当前包真实锁屏、睡眠、唤醒及系统时钟改变仍需验证；活动窗口不等于连续工作时长 |
| 当前监控状态与显式启停 | **有实现**：正常系统权限、主动开始、暂停/恢复；安全输入/中断有状态说明；演示使用独立库与标记 | Runtime 状态/验证 profile 测试、InputMonitor interruption 路径 | 需验证当前签名包的系统授权、拒绝/撤销/恢复；不绕过或反复自动请求权限 |
| 可选文字记录 | **有实现，覆盖有限**：默认关闭，Mac AX / Windows UIA 提交片段；焦点/候选/正文/选区/安全上下文一致性检查，不支持或不一致则跳过。[文字采集](../Sources/KeyTrailRuntime/TextCapture.swift)、[Windows 快照](../rust/keytrail-windows/src/text_snapshot.rs) | TextChecks provider、composition、baseline、snapshot；Windows text snapshot tests | 未提交拼音排除、不同编辑器、粘贴/替换/撤销、失焦与大文本需真实支持矩阵；不能声称全系统全文无损还原 |
| 文字加密、密钥和安全字段排除 | **有实现**：独立 AES-GCM 归档与认证元数据；Mac Keychain / Windows 当前用户 DPAPI；安全字段拒绝、正常授权；无剪贴板读取 | TextChecks encryption/AAD/tampering；跨语言公开合成 fixture；Windows text archive tests | 当前 OS 的安全控件、密码/安全桌面及密钥访问失败仍需实测；复制报告只写剪贴板，不能将此误写为采集剪贴板 |
| 关键词查询与全部文字可达 | **有实现**：有界分页、查询/游标/快照绑定、空匹配页续扫；只保留当前页明文；查看端解密搜索 | TextChecks bounded search/byte budget；Runtime paging；`test-private-web.js` | **网页断开/清钥/新会话关键词及旧异步响应清理已通过双浏览器回归**；不把当前页数量当全部命中数 |
| 完整 CSV、文字 TXT 与报告导出 | **有实现**：统计 `exportPage`/`exportValidate`；Mac 临时 0600 文件+快照校验+原子发布；Web 有界分片及最终 SHA 清单；文字明文导出显式提示。[CSV](../Sources/KeyTrailIPC/CSVExport.swift)、[Web CSV](../web/csv.js)、[文字 UI](../Sources/KeyTrailApp/TextHistoryView.swift) | Core export page/large file/snapshot；Runtime CSV；TextChecks；浏览器导出脚本 | 导出过程数据变化需中止并重试，不能静默截断或混版本；Android/iOS 系统下载、取消/后台行为和真实私有 HTTPS 另验；CSV 不承诺恢复导入 |
| 删除指定分钟范围、单条文字、清空 | **有实现**：显式确认；联合统计/文字删除采用 ATTACH 事务；独立文字删除不影响统计；同步有墓碑 | Core delete/atomic rollback/replica；TextChecks atomic deletion；SyncChecks joint delete/clear | **历史看板有界刷新已通过外部删除后的 Runtime 回归**；远端删除是下次成功同步后的最终一致，不是即时远程擦除 |
| 存储上限 | **有实现**：默认不限；用户开启总容量上限，统计+加密文字最旧分钟优先淘汰；保留墓碑并报告 `limitMet=false` | Core retention/tail/metadata lower bound；TextChecks combined retention；Windows text retention tests | 属于清理策略，非硬磁盘配额；超大库、空间耗尽、数据库损坏与容量提示需故障/负载验证；不得在个人库执行开发清理 |

## 趣味与分析：十二项逐项核对

以下为审查归组，避免把同一功能的卡片、报告附录和跨平台视图重复计成新增需求；不是重新编造原 PRD 编号。趣味距离列在 F06。趣味总开关应隐藏所有相关展示，同时保留基础统计和采集。

| 项目 | 当前实现与差异 | 检查来源 | 剩余工作 |
| --- | --- | --- | --- |
| F01 速度与峰值 | 物理按键/键盘活跃分钟、自然分钟峰值；文字页另有已归档字符/归档窗口平均和自然分钟峰值，包含可记录的粘贴 | Models、TextArchive metrics、Fun/Text/Core/Web metrics checks | 原始用户 PRD 要求平均/峰值打字速度，未指定滚动 60 秒；当前明确采用自然分钟口径。物理按键与归档字符速度不能混称，也不承诺全系统字符覆盖 |
| F02 累计成就/徽章 | 累计按键阈值及 pt 里程碑；未知累计数据不评定。[趣味模型](../Sources/KeyTrailCore/FunMetrics.swift) | FunChecks threshold/boundary；Web metrics | 当前 UI、趣味总关以及跨端阈值一致性需整合回归；不是物理公里或硬件寿命 |
| F03 近 7 天同钟比较 | 至少 3 个有记录且时长可比日；缺失日不补零，DST 不等长日排除 | InsightAnalysis、AnalysisChecks | 真实跨午夜/时区变更；明确样本数而非虚构连续覆盖 |
| F04 Top10 常用键 | 所选范围次数排序、同次数稳定排序；Mac 完整 Top10 在展开明细，摘要可只列前三；Web Top10 | DashboardView、web/app.js；Fun/Core/Windows label checks | 更新后键位归一化的跨端整合复查；不可将旧合并记录重分类 |
| F05 1–100 操作能量 | 确定性饱和公式，按键/点击/pt 加权，无数据不评分；明确不代表效率、体力或健康 | FunMetrics、web/metrics.js；FunChecks monotonic/NaN/overflow fixtures | 公式及空状态应保持跨端一致；无需真实人体校准 |
| F06 趣味距离与自定义参照 | 物理按键次数×自选游戏米数，赤道/京广线/自定义参照及保存设置，明确非字符总长度或鼠标物理移动 | FunSettings、FunMetrics、Web metrics；FunChecks 有界值/持久化检查 | **适配实现**：当前数据口径明确是按键游戏映射，不能悄然当成字符或现实移动；当前 UI 与报告口径需整合复查 |
| F07 周×小时热图及月历趋势 | 本地自然周/自然月；回拨小时合并，跳过与未来分开表示；与键盘键位热图是两项功能 | WeeklyRhythm、InsightAnalysis；RhythmChecks、AnalysisChecks、Web metrics/DST | 网页所选长范围趋势已通过真实本机服务与双浏览器回归；真实时区切换待验收 |
| F08 最高连击与纪录分钟 | 大于 750 ms 断开；保留峰值及分钟端点，暂停/重启清连续性；无旧数据证据不补造 | Rust extensions rhythm tests；FunChecks | 真实输入延迟、暂停与重启；不输出逐键精确时间或有序序列 |
| F09 键鼠 CP 配合 | 仅键盘、仅鼠标、窗口重叠三类按秒守恒 | InteractionMix、AnalysisChecks、Web metrics | **适配**：不推断浏览/编码/文档场景；窗口重叠也不证明两只手真实同时动作 |
| F10 本地周/月报告与按日查看 | 分钟聚合模板、复制/TXT、趣味附录；文字仅同范围完成认证后的元数据摘要，报告不自动包含正文 | WeeklyRhythm、InsightAnalysis、AppModel；Rhythm/Analysis/Fun/Web report tests | 同范围、未来周期、清钥/失败撤销摘要与真实导出文件整合复验；不声称 AI 工作总结 |
| F11 按键间隔 BPM | 30–2,000 ms 有效间隔 count/sum，`60,000 ÷ 均值`；不是按键/分钟或字符/分钟 | Rust extensions、FunMetrics、Web metrics；节奏边界测试 | 旧数据无计时证据显示不适用；不同 OS 实际事件时钟需验证 |
| F12 千万次磨损玩法 | 累计 Top10 各键；近 30 个已结束本地日，至少 3 个有记录日；缺直方图/均值则不预测 | FunMetrics、FunChecks per-key/DST/insufficient evidence；Web metrics | 不等于真实单键耐久或未来日历到达日期；物理键误合并影响估算，需使用本轮归一化修复 |

早期内部设计还出现过“滚动 60 秒峰值”和“物理键盘热区图”。这些不能直接视为原始用户 PRD 的硬性要求：原始峰值没有指定滚动窗口，用户原始热图要求是周×小时。当前 Mac 额外具备物理键位热区图，Web/Windows 网页查看器以 Top10/逐键磨损为主，未提供同等键盘布局；这是扩展功能的跨端差异，不据此判定原 PRD 缺交。自然分钟峰值也不声称具备滚动 60 秒语义。

## 同步、手机、Windows 和运行形态

| 需求 | 实现证据 | 检查来源 | 状态和验收条件 |
| --- | --- | --- | --- |
| 私有增量同步、断网重试、删除传播 | 默认关闭、仅用户私有端点；统计/文字独立游标、幂等、持久墓碑、身份变化重放、失败不确认；文字另行开启且只传密文。[Mac 同步](../Sources/KeyTrailRuntime/PrivateSync.swift)、[服务](../rust/keytrail-server/src/lib.rs) | Core replication；SyncChecks 真实临时服务；Windows sync schedule tests | **Mac idle 调度修复已完成模型及实际本机服务检查**：无新数据降低联网频率，同时不破坏 pending 触发、空闲重建检测及失败退避。当前服务已通过本机 nginx 验证 TLS；实际采集端 HTTPS、外部端点和真实输入到手机可见延迟另验 |
| 账号/设备和只读角色 | 采集/查看凭据分离，账号库隔离，每账号绑定一个采集设备；viewer 只读 allowlist；本机 API 认证 | Server tests、HTTP export tests、SyncChecks | 不是多采集设备自动合并或公众云账号系统；远端部署、客户端证书信任、凭据轮换/恢复流程待验收 |
| 手机查看 | 响应式浏览器/PWA shell，范围、统计、趣味、文字解密、报告、完整分页与导出；不采集手机输入 | `test-mobile-web.js`、`test-android-os-web.js`，Web 单元/浏览器脚本 | 当前资源已在 Android 16 OS 模拟器完成原生登录触摸、201 条文字分页与 2010 行 CSV/清单/报告实际下载；HTTPS 正常 CA 安装、TLS 1.3 登录/刷新/下载/断开清理也已通过；iOS OS、PWA 安装、后台恢复、实体设备仍分别验收 |
| Windows 采集与桌面查看 | Raw Input、暂停/锁定/电源通知、UIA、DPAPI、托盘、认证本机 Web viewer、退出保存失败保留 pending | Windows library tests、fault tests、Wine capture/UI 脚本 | Wine 为兼容层；Windows 内核、真实键盘/IME、DPAPI、锁屏/睡眠、认证 native API 和故障 GUI 仍需目标 OS 验收 |
| 显式登录启动 | Mac SMAppService；Windows 用户 Run 项；默认关闭，状态/失败可见 | Preferences/Runtime checks、Windows login tests | 当前正式安装路径下正常开启/关闭、系统审批、登录/重启必须实测；不得隐藏自启动 |
| 当前小时/今日悬浮统计 | 只读 status/summary，按本地 Calendar；独立错误/陈旧状态，不写库、不主动启动采集。[浮窗模型](../Sources/KeyTrailFloatingUI/FloatingStatsModel.swift) | FloatingChecks、Runtime/Windows 当前小时路径 | 当前包跨小时/DST、多屏/缩放、暂停文案与生命周期实测；不能用截图证明持续采集 |
| 桌面猫入口与真实输入响应（后续修订） | Mac 原生独立渲染进程、从代理读取有界当前姿态，双击开看板；资源缺失显示安装提示；暂态按键集合无顺序、不落库。[猫进程](../Sources/KeyTrailPet/PetApplication.swift)、PetAnimationState | PetChecks 的释放/真长按/暂停/失联/键位；模型资源检查路径 | SDK/模型为独立外部资源，源码分发不等于资源齐备；当前精确包需真实交互、丢释放和长时 CPU/GPU 验收，不能仅因有渲染代码宣称完整安装交付 |
| 常驻轻量架构和退出行为 | Mac AppKit 代理独占采集/写库，SwiftUI 看板按需打开；关看板退出看板进程，退代理停止 owned helpers；保存失败可阻止退出 | Agent lifecycle、Runtime fault paths、Floating/Pet checks、SIGPIPE 脚本 | 当前 release 隔离 demo 已通过人工正常关窗、同一后台存活、可见重开及菜单退出带走当前看板的验证；异常断开、保存失败 GUI、猫/浮窗联动与真实采集重启仍需各自证据 |
| 性能与交付 | 查询/分页/队列有界，猫静态姿态避免重复渲染；独立采集、看板、猫和浮窗可分别测量 | Core benchmark examples、`benchmark-core.sh`、`measure-process.py`、发布脚本 | **未达到整体验收声明条件**：当前 release 的后台单独/看板打开/猫浮窗开启、文字同步开关组合、持续高频输入、长历史冷查询、耗电与长期稳定性需测；短时 idle RSS 不代替这些结果 |

## 可以继续用代码推进的工作

1. 本轮已完成四条修复路径的整合验证：Mac idle 同步调度、历史缓存失效、Web 所选全范围趋势、关键词/密钥异步状态撤销。现有新增测试入口包括 `Tests/SyncSchedulingChecks`、`Tests/RuntimeChecks/HistoryRefreshChecks.swift`、`scripts/test-web-range-trend.js`；这些分别覆盖调度模型、实际临时服务、响应 fixture 和真实浏览器，不能混作真实输入验收。
2. 文字“支持哪些应用、哪些控件、哪些编辑方式”的覆盖状态仍可继续改进为可验证支持矩阵，并据目标编辑器反例修复。失败时继续保守跳过；不可把缺样本当作不存在缺陷，也不可为追求记录完整度取消安全/候选检查。
3. 本轮实际服务回归已覆盖双游标、清空、无新数据时的空闲重建恢复，以及趋势首尾范围和统计总数；浏览器检查覆盖文字旧异步响应和密钥撤销。后续源码变化仍需针对受影响边界重跑。

审查未发现可仅凭“尚无实机证据”就断言缺少的额外强制功能。滚动峰值或 Web 物理键位图如需继续扩展，应按新增范围单独决定，不计入本轮原始 PRD 欠项。

## 必须依赖目标环境或用户输入的验收

- 当前签名的 macOS 独立验证包：正常系统授权、实体输入、支持编辑器中的提交/未提交 IME、密码安全字段、实际锁屏/睡眠/唤醒、登录项，以及暂停/退出后的最终数据边界。
- 支持的 Windows OS：Raw Input/实体键盘、小键盘与 Num Lock 模式、UIA/中文 IME、DPAPI 用户隔离、多屏 DPI、电源事件、Run 项、保存失败 GUI 与完整退出。Docker/Wine 通过后仍保留此门槛。
- 用户选择的私有 HTTPS 端点及客户端正常信任：服务认证、断网/重建/删除传播、移动端访问与导出；开发阶段只传合成数据，不上传真实记录。
- Android/iOS：OS 级文件下载、PWA 安装、后台恢复和实际触摸；浏览器 emulation、OS 模拟器、实体设备各自记录。
- 当前 release 的分状态、可复现长时性能结果，以及带来源/版本绑定的 UI 和导出文件核对。构建通过、旧版短时测量、测试数量均不能单独关闭这些验收项。

本表保留实现、自动化和真实验收的区别；没有对应新证据时，剩余项继续处于待核验或待验收状态。

## 当前源码的补充验证（2026-10-27）

- Android 16 / API 36 的独立 OS 模拟器使用当前 8 个网页资源，原生点击登录通过；201 条合成加密文字分两页读取，2010 行统计导出为两个 CSV 分片，清单与 TXT 报告均实际进入 Android 下载目录并核对内容。不是实体手机或 iOS 验收。
- 当前 Linux 服务通过仓库 nginx TLS 配置完成 CA/主机名正向及未知 CA、错误主机名反向检查，验证趋势、角色隔离、幂等、文字密文、删除墓碑和导出失效。本轮又按原样 Dockerfile 从脱敏源码完成服务构建（复用依赖层缓存、实际重新编译当前服务），新镜像的容器重启、同步墓碑与 HTTPS 检查通过；不再只依赖替代镜像打包路径。
- Android HTTPS 流程已通过：安装前拒绝未知 CA，正常系统设置安装后 Chrome 建立 TLS 1.3 连接；登录、固定范围刷新、统计、CSV/TXT 实际下载、断开清理均验证。网页操作为实际 Android Chrome 的 Page locators，证书安装为正常原生界面；没有跳过证书验证或修改宿主信任。
- 当前环境只有 Command Line Tools，没有可用 iOS Simulator；已有 WebKit 手机配置检查仍属于浏览器模拟。
- 发布扫描与打包防覆盖检查共 27 项通过；独立审查后补上自有同步令牌识别及测试目录参数的启动前校验。公开包不含本机验收日志、数据库、SDK/模型、历史 Git 对象或应用构建。
- 当前 macOS release 的 Core 独立检查 14 项、Runtime 合成集成检查 36 项、文字归档检查 34 组及同步检查 11 组/调度模型 5 组通过，Agent/Dashboard 的 20 项错误测试参数启动均按预期拒绝。自动同步的 3 个合成样本从日志提交到本机查看端可见约 1.98、2.57、2.14 秒，未发手动同步请求；不包含采集/落盘、TLS/公网或离线重试，不能作为全链路三秒保证。
- 早期 macOS 采样只记录了看板进程存在，不能证明窗口可见。修正测试启动参数并加入真实主窗口门槛后，两段各 60 秒的空闲采样得到：菜单后台 RSS 中位 42.9 MiB、峰值 85.8 MiB；后台与可见看板合计中位 159.7 MiB、峰值 182.0 MiB。没有开启真实采集、文字、同步、猫或浮窗；后台峰值已超过原始 50 MB 指标。这些短时数据不是持续性能达标证明。

- 本轮修复容量检查截断活动窗口：原路径在未超限、未删除记录时仍结束活动，合成复现把完整 30 秒尾段截成 1 秒。修后未超限不整理数据库、不重置；仅压缩可达标时也不结束活动；确实首次删除前才执行结束回调。回调前 SQLite 读取已完成且无事务，之后重新读取数量/边界，保留联合事务、墓碑和错误回滚。Mac 生产分支与真实临时 Rust/文字库回归通过，Windows 对应代码也按相同规则修订。
- Mac 隔离窗口问题已复现并修复：同一最小 SwiftUI 程序传入分离目录参数时无窗口，改为单参数等号形式时正常显示；实际 KeyTrail 修后已确认正常可见主窗口。测试目录保持演示模式限定，拒绝错误、重复及相对路径；首次打开和重开都要求真实大窗口可见。正常关窗及菜单退出仍须另附实际动作证据，不以进程消失或终止信号代替。

- Windows 容量维护的最终库检查为 38 项；全工作区主机 locked Cargo 122 项通过。在 Docker/Wine 中，当前编译的 Windows PE 实际执行 Core 63、Server 21、Windows library 38 和原生应用 cleanup 3 项，共 125 项通过、0 忽略。原生三项直接构造隔离 App 调用生产 cleanup，覆盖未超限、仅压缩及真实删除时的活动尾段、按住的键、光标锚点和文字状态；没有注册真实输入、创建用户窗口或访问 DPAPI。仍不是 Windows 内核/硬件/IME 实机验收。

- 后续 Mac 同二进制 headless 对照每阶段 60 秒：首次演示 seed 峰值 72.5 MiB，空 SQLite 库初始化与已有 3818 分钟测试库重启均峰值 32.1 MiB。三组均未启用真实监听、菜单、文字、同步、猫或浮窗，且正常 IPC 退出。该结果定位了演示初始化的额外分配，不是实际采集的完整 50 MB 验收。
- 默认 `benchmark-core.sh` 已改为测当前 Rust 核心，移除旧 Swift 存储基准入口。52.56 万分钟行及等量键位直方图的合成年数据通过全年/月/周全部汇总字段、168 小时格与 31 日格的正确性检查；9 次已预热查询中，全年、月、周汇总中位分别约 127、9、2 ms。结果含 Rust FFI/JSON，排除 Swift/socket/UI 和冷文件缓存，不承诺完整界面延迟。
- 较早两轮隔离 Mac 检查因界面工具挂起、人工关窗等待到期而失败，原始记录继续保留。后续独立一轮由用户实际操作：关闭看板后，同一后台仍可读取状态；重新打开的主窗口实际可见；菜单退出后台时，最新的当前看板和后台均退出，socket 与临时目录清理。中途已先关闭的旧看板不作为联动证据；最新 helper 的从属关系、可见窗口、双进程退出观察及本轮人工确认独立记录。通过范围仅为 demo 生命周期；未测关闭后内存、真实输入及猫/浮窗负载。

# KeyTrail · 键迹

本地优先的键盘、鼠标活动统计工具。Rust 负责统计与 SQLite 存储；macOS 使用常驻 AppKit 代理和按需打开的 SwiftUI 看板，Windows 使用原生采集器和本机浏览器看板。可选私有同步服务提供手机只读查看。

> 当前公开内容是源码。桌面小猫的集成代码可选启用，第三方模型、纹理和 Live2D SDK 不包含在本仓库中。不同平台的验证范围见 [测试说明](docs/testing.md)，不把构建成功等同于全部实机功能已验收。

## 功能

- 按本地小时、日期、月份和自定义区间查看按键、三种鼠标点击、光标距离与活跃时长。
- 分钟聚合和逐分钟键位直方图；累计数据不在零点清空，支持查询、删除、保留上限与分页 CSV 导出。
- 物理按键速度、Top 10、徽章、同期对比、热力图、趋势、周/月报告、节奏和趣味距离；趣味面板可关闭。
- 独立数据浮窗，支持当前小时/今日、拖动、精简显示、置顶及透明度。
- 可选文字归档、搜索、删除和 TXT 导出。文字单独加密，支持范围与输入法有明确限制。
- 可选私有服务同步、手机网页查看、断网重试和删除同步；没有内置公共数据服务。
- 可选 macOS 桌面小猫：随当前键鼠状态动作、实际键位高亮、双击打开看板和手动姿态重置。

## 隐私与统计口径

**文字记录、同步和登录启动默认关闭。** 统计库保存分钟聚合，不保存有序物理按键或光标坐标，不读取剪贴板。光标距离的单位是屏幕显示点 `pt`，不是鼠标在桌面上移动的米数。

文字仅在显式开启后尝试采集支持控件中已提交的片段，安全输入时暂停；无法验证的控件会跳过。文字库使用 AES-GCM 认证加密，密钥由 macOS Keychain 或 Windows DPAPI 保护。文字同步是独立开关，只发送密文；明文导出是用户主动操作。详见 [隐私说明](docs/privacy.md)。

活动时长由动作后的有限活动窗口取并集计算，不表示注意力或工作效率。暂停、锁屏和休眠时间不应增加活动时长。趣味指标不用于效率考核、健康判断或硬件寿命预测。

## macOS 构建

需要 macOS 14+、Swift 6 工具链、Rust stable、Python 3.9+ 和系统 SQLite。运行目录均为仓库根目录：

```sh
./scripts/build-rust.sh
swift build -c release
./scripts/package-app.sh
```

普通开发包输出为 `artifacts/KeyTrail-v1.2-candidate.app`。打包使用本地临时签名，不是公证发行包。输入监控需要用户通过 macOS 系统设置正常授予；重新签名或替换程序后，系统可能要求重新授权。采集文字还需要辅助功能权限。不要修改系统权限数据库。

使用独立演示数据库查看界面：

```sh
./scripts/run-demo.sh
```

预览包位于 `artifacts/KeyTrail-preview.app`，不采集真实输入。普通、预览、验证 profile 分开存储；关闭看板退出看板进程，菜单栏代理继续运行，从代理退出才停止它拥有的进程。

macOS 打包脚本默认拒绝覆盖已存在的应用。确需重新打包开发输出时，先确认目标并显式设置 `KEYTRAIL_REPLACE_OUTPUT=1`；现用的保留包路径始终受保护。可用 `KEYTRAIL_APP_OUTPUT` 指定新的绝对 `.app` 路径。不要为了演示而覆盖正在使用的采集程序。

独立看板和数据浮窗可以单独打包，与现有采集代理连接：

```sh
KEYTRAIL_DASHBOARD_PROFILE=normal ./scripts/package-dashboard.sh
KEYTRAIL_FLOAT_PROFILE=normal ./scripts/package-float-app.sh
```

看板输出为 `artifacts/KeyTrail-Dashboard-dev.app`，浮窗输出为 `artifacts/KeyTrail-Float-normal-dev.app`。正常浮窗默认连接上面的 candidate 包及其内嵌看板；`demo` profile 对应 preview 包。默认 `validation` 浮窗连接新生成的 `KeyTrail-Cat-dev.app` 与 `KeyTrail-Dashboard-dev.app`，对应看板默认 validation profile；构建这些包不会启动采集或自动取得系统权限。可用 `KEYTRAIL_DASHBOARD_APP_OUTPUT`、`KEYTRAIL_FLOAT_APP_OUTPUT` 指定独立输出。

若要连接已在使用的采集器或独立看板，可设置 `KEYTRAIL_FLOAT_COLLECTOR_APP` 和 `KEYTRAIL_FLOAT_DASHBOARD_APP` 为对应的绝对 `.app` 路径，并选择相匹配的 `KEYTRAIL_FLOAT_PROFILE`。这两个参数只写入新浮窗包的连接信息，不会修改或重新签名目标应用。例如，正常浮窗连接单独构建的正常看板：

```sh
KEYTRAIL_FLOAT_PROFILE=normal \
KEYTRAIL_FLOAT_DASHBOARD_APP="$PWD/artifacts/KeyTrail-Dashboard-dev.app" \
./scripts/package-float-app.sh
```

[可选桌面小猫接入](docs/bongo-cat-assets.md)需要自行准备适用许可下的 SDK 和模型，基础统计应用不依赖这些资源。源码中的稳定应用标识、IPC 通知名和 Keychain service 是兼容协议，不是凭据；修改这些标识需要设计数据和权限迁移。

## Windows 与私有服务

Windows 原生构建：

```powershell
cargo test --locked --manifest-path rust/Cargo.toml
./scripts/package-windows.ps1
```

输出位于 `artifacts/KeyTrail-Windows-v1.2/`，详见 [Windows 说明](rust/keytrail-windows/README.md)。Docker/Wine 检查用于兼容层验证，不能替代 Windows 内核、驱动、UIA/IME 或实体键盘测试。

手机通过自己配置的私有 HTTPS 服务访问只读网页，不采集手机输入。服务支持用户/设备隔离和只读凭据。初次部署、随机凭据生成及 Docker 配置见 [部署说明](deploy/README.md)。不要把配置、访问令牌或真实数据库放进 Git。

## 测试与贡献

```sh
cargo test --locked --manifest-path rust/Cargo.toml
./scripts/test-core.sh
./scripts/test-runtime.sh
python3 -m unittest discover -s Tests/PublicationChecks -v
python3 scripts/export-source.py --check
```

只安装 Command Line Tools 的环境可运行独立 Core 检查；没有 XCTest 时不要把它写成 `swift test` 通过。跨语言文字、同步、浏览器、Wine、Android 的前置步骤见 [测试说明](docs/testing.md)。

- [架构与数据契约](docs/implementation-contract.md)
- [当前已知限制与待办](docs/known-issues.md)
- [累计 PRD 逐项覆盖与验收边界](docs/prd-coverage.md)
- [贡献约定](CONTRIBUTING.md)
- [安全问题报告](SECURITY.md)
- [源码发布方法](docs/open-source.md)

## 许可证

KeyTrail 自有代码采用 [Apache-2.0](LICENSE)。保留的第三方来源和修改说明见 [NOTICE](NOTICE) 与 [第三方说明](THIRD_PARTY_NOTICES.md)。第三方模型、Live2D SDK 和外部依赖各自遵循原许可，不因本项目开源而被重新授权。本次源码分发不包含 SDK、第三方模型或预构建应用。

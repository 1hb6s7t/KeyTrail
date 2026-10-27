import KeyTrailCore
import SwiftUI

@MainActor
struct FunMetricsView: View {
    let metrics: FunMetrics?
    let isLoading: Bool
    let error: String?
    let settings: FunSettings
    let isDemo: Bool
    let onSettingsChange: (FunSettings) -> Void
    let onRetry: () -> Void
    @State private var draft: FunSettings

    init(metrics: FunMetrics?, isLoading: Bool, error: String?, settings: FunSettings, isDemo: Bool, onSettingsChange: @escaping (FunSettings) -> Void, onRetry: @escaping () -> Void) {
        self.metrics = metrics; self.isLoading = isLoading; self.error = error; self.settings = settings; self.isDemo = isDemo
        self.onSettingsChange = onSettingsChange; self.onRetry = onRetry
        _draft = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if isLoading {
                RhythmCard(title: "正在读取趣味统计", eyebrow: "LOCAL PLAYFUL METRICS") {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("读取节奏聚合与最近 30 个本地日期…") }
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).padding(.vertical, 12)
                }
            } else if let error {
                RhythmCard(title: "趣味统计暂不可用", eyebrow: "LOCAL PLAYFUL METRICS") {
                    Text(error).font(.system(size: 12)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
                    Button("重试") { onRetry() }.controlSize(.small)
                }
            } else if let metrics {
                if isDemo {
                    Label("以下趣味结果基于独立演示数据，不代表真实输入验收。", systemImage: "sparkles")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.orange)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), alignment: .top)], alignment: .leading, spacing: 15) {
                    energyCard(metrics)
                    timingCard(metrics)
                }
                distanceCard(metrics)
                cursorBadgeCard(metrics)
                wearCard(metrics)
            } else {
                RhythmCard(title: "所选时段的趣味统计尚未就绪", eyebrow: "LOCAL PLAYFUL METRICS") {
                    Text("请选择时段后刷新；此处不显示其他范围的旧结果。")
                        .font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
                    Button("读取所选时段") { onRetry() }.controlSize(.small)
                }
            }
        }.onChange(of: settings) { _, value in draft = value }
    }

    private func energyCard(_ metrics: FunMetrics) -> some View {
        RhythmCard(title: "操作能量值", eyebrow: "JUST A GAME  /  1–100") {
            if let score = metrics.energyScore {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score)").font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("/ 100").font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
                }.foregroundStyle(TrailStyle.teal).padding(.top, 5)
                ProgressView(value: Double(score), total: 100).tint(TrailStyle.teal)
            } else {
                Text("暂无分数").font(.system(size: 22, weight: .medium, design: .serif)).padding(.vertical, 10)
                Text("没有可加权的按键、点击或光标计数时不生成分数；无统计记录，不等于没有活动。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            }
            Text(FunMetrics.energyScope).font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            DisclosureGroup("查看玩法公式") {
                Text(FunMetrics.energyFormula).font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4).textSelection(.enabled).padding(.top, 5)
            }.font(.system(size: 11))
        }
    }

    private func timingCard(_ metrics: FunMetrics) -> some View {
        RhythmCard(title: "指尖节奏", eyebrow: "INTERVALS & FAST BURSTS") {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("间隔 BPM").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                    Text(metrics.bpm.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "不适用")
                        .font(.system(size: metrics.bpm == nil ? 19 : 30, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Spacer(minLength: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("最高连击").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                    Text(metrics.burstPeak.map { "\($0) 次" } ?? "无节奏记录")
                        .font(.system(size: metrics.burstPeak == nil ? 16 : 26, weight: .medium, design: .rounded)).monospacedDigit()
                }
            }.padding(.top, 8)
            if let minute = metrics.burstPeakMinute {
                Text("连击记录所在分钟：\(minute.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            Text("有效间隔 \(metrics.intervalSampleCount) 个 · 有节奏聚合的分钟 \(metrics.timingMeasuredMinutes) 个")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            if metrics.bpm == nil {
                Text("没有足够的有效间隔时不显示 BPM；旧分钟数据没有节奏证据，不补造结果。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.orange).lineSpacing(3)
            }
            Text("BPM = 60,000 ÷ 平均间隔毫秒；仅纳入 30–2,000 ms 的按键间隔，不是按键次数/分钟。超过 750 ms 或暂停、休眠、重启会中断连击；仅展示分钟时间。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
        }
    }

    private func distanceCard(_ metrics: FunMetrics) -> some View {
        RhythmCard(title: "按键的游戏旅程", eyebrow: "FICTIONAL DISTANCE  /  NOT PHYSICAL") {
            if let meters = metrics.mappedDistanceMeters, let ratio = metrics.routeCompletions {
                HStack(alignment: .firstTextBaseline) {
                    Text(gameDistance(meters)).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text(referenceProgress(ratio))
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
                }.padding(.top, 8)
                ProgressView(value: min(1, max(0, ratio))).tint(TrailStyle.teal)
                Text("按键次数 × \(scaleLabel(metrics.settings.metersPerPress)) 游戏米/次；当前参照：\(metrics.settings.reference.title)")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            } else if metrics.mappedDistanceMeters != nil {
                Text("参照比例超出可表示范围，请调整自定义参照长度；不显示无穷大的圈数。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.orange)
            }
            if metrics.settings != settings {
                Text("新玩法设置已保存，等待更新计算；上方仍明确使用上一份已生成快照的缩放与参照。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            Text("这是游戏映射，不是真实移动、输入字符数或光标物理距离。赤道与京广线只采用预设玩法基准 40,075 km / 2,300 km，不作为测绘或实际线路长度声明。光标统计仍独立使用 pt。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.orange).lineSpacing(4)
            Divider().padding(.vertical, 5)
            distanceSettings
        }
    }

    private var distanceSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("游戏参照", selection: $draft.reference) {
                ForEach(FunDistanceReference.allCases) { reference in Text(reference.title).tag(reference) }
            }.frame(maxWidth: 400)
            HStack {
                Text("每次按键映射").font(.system(size: 11))
                TextField("游戏米/次", value: $draft.metersPerPress, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                Text("游戏米/次（默认 0.01）").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            if draft.reference == .custom {
                HStack {
                    Text("自定义参照长度").font(.system(size: 11))
                    TextField("参照游戏米", value: $draft.customDistanceMeters, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                    Text("游戏米").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                }
            }
            if let error = draft.validationError { Text(error).font(.system(size: 11)).foregroundStyle(TrailStyle.orange) }
            HStack(spacing: 10) {
                Button("保存玩法设置") { onSettingsChange(draft) }.disabled(draft.validationError != nil || draft == settings)
                Button("填入默认值") { draft = FunSettings() }
            }.controlSize(.small)
        }.font(.system(size: 11))
    }

    private func wearCard(_ metrics: FunMetrics) -> some View {
        RhythmCard(title: "千万次阈值 · 趣味估算", eyebrow: "RECORDED DAYS  /  NOT HARDWARE LIFE") {
            Text("累计按键 \(metrics.wearCumulativePresses.formatted()) / \(FunMetrics.wearThreshold.formatted()) 次")
                .font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit().padding(.top, 6)
            ProgressView(value: min(1, Double(metrics.wearCumulativePresses) / Double(FunMetrics.wearThreshold))).tint(TrailStyle.orange)
            if metrics.wearCumulativePresses >= FunMetrics.wearThreshold {
                Text("已达到这条游戏阈值，不代表键盘损坏。")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TrailStyle.orange)
            } else if let remaining = metrics.wearRemainingRecordedDays {
                Text("按当前样本均值，还需约 \(remaining.formatted(.number.precision(.fractionLength(0...1)))) 个有记录日")
                    .font(.system(size: 14, weight: .medium, design: .serif))
            } else {
                Text(metrics.wearSampleDayCount < 3 ? "样本不足：至少需要 3 个有记录日，暂不预测。" : "样本日的按键均值为 0，暂不能估算到达阈值所需时间。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
            }
            Text("最近 30 个已结束的本地日期：\(metrics.wearSampleDayCount) 个有记录日\(metrics.wearAveragePressesPerRecordedDay.map { " · 均值 \($0.formatted(.number.precision(.fractionLength(0...1)))) 次/有记录日" } ?? "")")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            Text("不含今天的未结束日期；缺失日期不按零补入，有记录但零按键的日期保留在均值中。按全键盘累计次数作假设性游戏估算，不是单键耐久、真实日历到达日期或硬件寿命。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            Divider().padding(.vertical, 5)
            keyWearTable(metrics)
        }
    }

    private func cursorBadgeCard(_ metrics: FunMetrics) -> some View {
        RhythmCard(title: "光标显示点累计徽章", eyebrow: "CURSOR DISPLAY POINTS  /  NOT PHYSICAL KM") {
            if let points = metrics.lifetimeMouseDistancePoints {
                Text("累计 \(points.formatted(.number.precision(.fractionLength(0...0)))) pt")
                    .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit().padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(metrics.cursorBadges) { badge in
                        VStack(alignment: .leading, spacing: 9) {
                            Image(systemName: badge.achieved ? "seal.fill" : "seal")
                                .font(.system(size: 23)).foregroundStyle(badge.achieved ? TrailStyle.orange : TrailStyle.muted.opacity(0.55))
                            Text(badge.title).font(.system(size: 12, weight: .medium))
                            Text("\(badge.thresholdPoints.formatted()) pt").font(.system(size: 10, design: .monospaced)).foregroundStyle(TrailStyle.muted)
                            Text(badge.achieved ? "已解锁" : "尚未达到").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(TrailStyle.paper, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            } else {
                Text("累计光标显示点数据尚未读取，不把未知值当作零，也不评定徽章。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 10)
            }
            Text("阈值为屏幕光标 display points 的累计距离；不是物理米/公里或桌面移动距离，也不使用按键的虚构游戏米数解锁。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
        }
    }

    private func keyWearTable(_ metrics: FunMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("累计 Top 10 按键 · 单键千万次玩法")
                .font(.system(size: 12, weight: .semibold))
            Text("每键均值 = 该键近 30 个已结束本地日期的频次 ÷ \(metrics.wearSampleDayCount) 个有记录日；没有该键直方图证据或不足 3 日时不预测。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            if metrics.keyWear.isEmpty {
                Text("暂无累计按键频次，不能从总次数猜测各键磨损。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 11) {
                    GridRow {
                        Text("物理键位"); Text("累计次数"); Text("次/有记录日"); Text("约还需有记录日")
                    }.font(.system(size: 9)).foregroundStyle(TrailStyle.muted)
                    ForEach(metrics.keyWear) { key in
                        GridRow {
                            Text(key.key).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text(key.cumulativePresses.formatted())
                            Text(key.averagePressesPerRecordedDay.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "缺少频次证据")
                            Text(keyRemainingLabel(key))
                        }.font(.system(size: 10)).monospacedDigit()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("每个物理键分别比较累计频次与 10,000,000 次游戏阈值；这不是按键开关寿命预测。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
        }
    }

    private func keyRemainingLabel(_ value: KeyWearProjection) -> String {
        if value.cumulativePresses >= FunMetrics.wearThreshold { return "已达玩法阈值" }
        if value.sampleDayCount < 3 { return "不足 3 日" }
        return value.remainingRecordedDays.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "暂不估算"
    }

    private func gameDistance(_ meters: Double) -> String {
        if meters > 0 && meters < 0.01 { return "\(meters.formatted(.number.notation(.scientific))) 游戏米" }
        if meters >= 1_000 { return "\((meters / 1_000).formatted(.number.precision(.fractionLength(0...2)))) 游戏公里" }
        return "\(meters.formatted(.number.precision(.fractionLength(0...2)))) 游戏米"
    }

    private func referenceProgress(_ ratio: Double) -> String {
        let percent = ratio * 100
        if percent > 0 && percent < 0.000001 { return "参照长度的 \(percent.formatted(.number.notation(.scientific)))%" }
        if percent.isFinite { return "参照长度的 \(percent.formatted(.number.precision(.fractionLength(0...6))))%" }
        return "参照长度的 \(ratio.formatted(.number.notation(.scientific))) 倍"
    }

    private func scaleLabel(_ value: Double) -> String {
        value > 0 && value < 0.000001 ? value.formatted(.number.notation(.scientific)) : value.formatted(.number.precision(.fractionLength(0...6)))
    }
}

import KeyTrailCore
import SwiftUI

struct DailyComparisonCard: View {
    let comparison: DailyComparison?
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void

    var body: some View {
        RhythmCard(title: (!isLoading && error == nil ? comparison?.title : nil) ?? "近 7 天同时间段对比", eyebrow: "RECENT SEVEN DAYS") {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取可比的历史时段…").font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
                }.padding(.vertical, 15)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                    .foregroundStyle(TrailStyle.orange).lineSpacing(4).textSelection(.enabled).padding(.vertical, 10)
                Button("重试对比") { onRetry() }.controlSize(.small)
            } else if let comparison {
                comparisonContent(comparison)
            } else {
                Text("尚无可用的时段对比。无统计记录，不等于没有活动。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 10)
                Button("读取对比") { onRetry() }.controlSize(.small)
            }
            Text("只比较已记录的活动窗口，不判断好坏或工作效率；空白不代表没有活动。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3).padding(.top, 5)
        }
    }

    private func comparisonContent(_ value: DailyComparison) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(value.headline).font(.system(size: 14, weight: .medium, design: .serif)).padding(.top, 6)
            Text(value.detail).font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4).textSelection(.enabled)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], alignment: .leading, spacing: 12) {
                RhythmMetric(title: "本次记录活跃", value: value.currentActiveSeconds == 0 && value.baselineActiveSeconds == nil ? "暂不比较" : rhythmDuration(value.currentActiveSeconds), unit: "")
                if value.sampleCount >= 3, let baseline = value.baselineActiveSeconds {
                    RhythmMetric(title: "有效历史时段均值", value: comparisonDuration(baseline), unit: "")
                    if let difference = value.differenceSeconds {
                        RhythmMetric(title: "与历史均值相差", value: signedDifference(difference), unit: "")
                    }
                } else {
                    RhythmMetric(title: "历史基线", value: value.sampleCount < 3 ? "样本不足" : "暂不比较", unit: "")
                }
            }
            Text("有效历史样本 \(value.sampleCount) / 7 天 · 至少 3 个有效样本才展示基线")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
        }
    }

    private func comparisonDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "不可用" }
        return rhythmDuration(Int(seconds.rounded()))
    }

    private func signedDifference(_ seconds: Double) -> String {
        guard seconds.isFinite, abs(seconds) < Double(Int.max) else { return "不可用" }
        if abs(seconds) < 0.5 { return "相同" }
        return "\(seconds > 0 ? "+" : "−")\(comparisonDuration(abs(seconds)))"
    }
}

struct InteractionMixCard: View {
    let summary: ActivitySummary

    var body: some View {
        RhythmCard(title: "键鼠配合", eyebrow: "ACTIVITY WINDOW OVERLAP") {
            if let mix = InteractionMix(summary: summary) {
                if mix.totalSeconds > 0 { mixContent(mix) }
                else {
                    Text("所选时段没有记录的活跃时长。无统计记录，不等于没有活动。")
                        .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 15)
                }
            } else {
                Label("当前时长关系无法用于配合统计，请刷新后重试。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.orange).padding(.vertical, 15)
            }
            Text("重叠表示键盘与鼠标各自输入后的 30 秒活动窗口有交集，不代表同一时刻实际操作，更不用于判断工作场景。")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4).padding(.top, 5)
        }
    }

    private func mixContent(_ mix: InteractionMix) -> some View {
        let segments = [
            MixSegment(title: "仅键盘窗口", seconds: mix.keyboardOnlySeconds, color: TrailStyle.teal),
            MixSegment(title: "仅鼠标窗口", seconds: mix.mouseOnlySeconds, color: TrailStyle.orange),
            MixSegment(title: "窗口重叠", seconds: mix.overlapSeconds, color: TrailStyle.ink.opacity(0.65))
        ]
        return VStack(alignment: .leading, spacing: 15) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        segment.color.frame(width: geometry.size.width * Double(segment.seconds) / Double(mix.totalSeconds))
                    }
                }.clipShape(Capsule())
            }.frame(height: 15).padding(.top, 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], alignment: .leading, spacing: 12) {
                ForEach(segments) { segment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(segment.color).frame(width: 6, height: 6)
                            Text(segment.title).font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
                        }
                        Text(preciseDuration(segment.seconds)).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("去重活动窗口合计 \(preciseDuration(mix.totalSeconds))")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
        }
    }

    private func preciseDuration(_ seconds: Int) -> String {
        if seconds >= 3_600 { return "\(seconds / 3_600)时 \((seconds % 3_600) / 60)分 \(seconds % 60)秒" }
        if seconds >= 60 { return "\(seconds / 60)分 \(seconds % 60)秒" }
        return "\(seconds)秒"
    }
}

private struct MixSegment: Identifiable {
    let title: String
    let seconds: Int
    let color: Color
    var id: String { title }
}

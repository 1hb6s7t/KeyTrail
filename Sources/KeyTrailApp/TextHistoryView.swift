import KeyTrailIPC
import SwiftUI

@MainActor
struct TextHistoryView: View {
    @ObservedObject var model: AppModel
    let onOpenSettings: () -> Void
    @State private var actionConfirmation: TextActionConfirmation?
    @State private var confirmExport = false
    @State private var exportContext: ExportContext?
    @State private var localNotice: String?
    @State private var submittedKeyword = ""
    @State private var submittedInterval: DateInterval?
    @State private var loadingMore = false

    private struct ExportContext {
        let interval: DateInterval
        let keyword: String
    }
    private enum TextActionConfirmation: Identifiable {
        case record(id: String, application: String, time: Date)
        case range(DateInterval)
        case viewingKey
        var id: String {
            switch self { case .record(let id, _, _): return id; case .range: return "selected-range"; case .viewingKey: return "viewing-key" }
        }
        var isRange: Bool { if case .range = self { return true }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            recordingStatus
            searchControls
            if let metrics = model.textMetrics, model.textHistoryError == nil, !model.textHistoryLoading || loadingMore {
                archivedCharacterMetrics(metrics)
            }
            if let error = model.textHistoryError {
                RhythmCard(title: "文字操作需要重试", eyebrow: "ENCRYPTED LOCAL ARCHIVE") {
                    Text(error).font(.system(size: 12)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
                    Button("重新搜索当前范围") { search() }.controlSize(.small)
                }
            }
            if model.textHistoryLoading && !loadingMore {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("在本机解密并搜索所选时段…") }
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 15)
            } else if let page = model.textHistory, model.textHistoryError == nil {
                if model.textKeyword != submittedKeyword {
                    Text("新关键词尚未搜索，下面保留上一次已提交搜索的结果；请搜索后再导出或载入更多。")
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.orange)
                }
                results(page)
            } else if !model.textHistoryLoading && model.textHistoryError == nil {
                Text("还未读取所选时段。请使用上方搜索或刷新。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
            }
            if let notice = localNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
            }
            if let notice = model.textExportNotice {
                HStack(alignment: .top, spacing: 10) {
                    if model.textExporting { ProgressView().controlSize(.small) }
                    Text(notice).font(.system(size: 11)).foregroundStyle(TrailStyle.muted).textSelection(.enabled)
                    if model.textExporting { Button("取消导出") { model.cancelTextExport() }.controlSize(.small) }
                }
            }
        }
        .onAppear { search() }
        .onChange(of: model.selectedInterval) { _, _ in search() }
        .onChange(of: model.textHistoryLoading) { _, value in if !value { loadingMore = false } }
        .alert(item: $actionConfirmation) { target in
            if case .viewingKey = target {
                return Alert(title: Text("复制手机文字查看密钥？"),
                             message: Text("此密钥允许解密已同步的文字归档。请仅在你自己的手机查看器中粘贴，不要交给他人；看板不会显示或记录密钥。"),
                             primaryButton: .default(Text("确认复制查看密钥")) { model.copyTextViewingKey() },
                             secondaryButton: .cancel(Text("取消")))
            }
            return Alert(title: Text(target.isRange ? "删除所选范围的全部文字归档？" : "删除这一条文字归档？"),
                  message: Text(confirmationMessage(target)),
                  primaryButton: .destructive(Text("确认删除")) {
                      switch target {
                      case .record(let id, _, _): model.deleteTextRecords([id])
                      case .range(let interval): model.deleteTextHistory(in: interval)
                      case .viewingKey: break
                      }
                  }, secondaryButton: .cancel(Text("取消")))
        }
        .confirmationDialog("导出为未加密的 TXT 文件？", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("继续选择明文导出文件") {
                guard let context = exportContext, context.interval == model.selectedInterval, context.keyword == model.textKeyword else {
                    localNotice = "范围或关键词已改变，请重新确认导出。"; exportContext = nil; return
                }
                model.exportTextHistory(); exportContext = nil
            }
            Button("取消", role: .cancel) { exportContext = nil }
        } message: {
            Text("导出当前时间范围及关键词的匹配内容。TXT 是未加密的文字文件，请自行选择保存位置；当前分页不能当作完整导出。")
        }
    }

    private var recordingStatus: some View {
        RhythmCard(title: "可选文字归档", eyebrow: model.isDemo ? "TEXT HISTORY  /  DEMO" : "TEXT HISTORY  /  OFF BY DEFAULT") {
            if model.isDemo {
                Label("演示归档与真实输入隔离；预览不录制真实文字。", systemImage: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.orange)
            }
            if let status = model.textRecordingStatus {
                Label(status.enabled ? "文字记录已开启" : "文字记录已关闭", systemImage: status.enabled ? "record.circle" : "pause.circle")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(status.enabled ? TrailStyle.orange : TrailStyle.muted)
                Text(status.message).font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
                Text(status.permissionGranted ? "辅助功能访问已允许" : "尚未允许辅助功能访问")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            } else {
                Text("文字采集状态尚未读取，以后台返回状态为准。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            }
            Text("默认关闭；需你在设置中主动开启并通过正常辅助功能授权。安全输入和受保护控件应排除，无法访问的控件不保证记录。不会读取剪贴板。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            HStack(spacing: 10) {
                Button("文字记录设置") { onOpenSettings() }
                Button("复制手机查看密钥…") { actionConfirmation = .viewingKey }
            }.controlSize(.small)
        }
    }

    private var searchControls: some View {
        RhythmCard(title: "搜索本地文字", eyebrow: "EXPLICIT RANGE & KEYWORD") {
            HStack(spacing: 10) {
                TextField("关键词（留空显示所选范围）", text: $model.textKeyword)
                    .textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("搜索") { search() }.disabled(model.textHistoryLoading)
                Button { search() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新文字搜索").accessibilityLabel("刷新文字搜索").disabled(model.textHistoryLoading)
            }.controlSize(.small)
            Text("当前文字范围：\(model.rangeTitle) · 包含起点、不包含终点，历史范围精确到分钟。关键词输入后按回车或搜索；不随每次按键自动查询。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            HStack(spacing: 12) {
                Button("导出文字 TXT…", systemImage: "square.and.arrow.up") {
                    exportContext = ExportContext(interval: model.selectedInterval, keyword: model.textKeyword); confirmExport = true
                }.disabled(model.csvExporting || model.textExporting || model.textHistoryLoading || model.selectedInterval.duration <= 0 || model.textKeyword != submittedKeyword || model.selectedInterval != submittedInterval)
                Spacer()
                Button("删除整个所选文字范围…", role: .destructive) { actionConfirmation = .range(model.selectedInterval) }
                    .disabled(model.textHistoryLoading || model.selectedInterval.duration <= 0)
            }.controlSize(.small)
            Text("TXT 为明文导出，将独立逐页扫描全部匹配记录，不受当前页限制；完整扫描成功后才保存目标文件。范围删除覆盖全部文字记录，不受关键词或分页限制。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.orange).lineSpacing(4)
        }
    }

    private func results(_ page: TextScanPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("第 \(model.textHistoryPageIndex + 1) 页 · 已扫描 \(model.textScannedRecords.formatted()) / \(page.totalRecords.formatted()) 条候选 · 累计匹配 \(model.textMatchedCount.formatted()) 条")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(TrailStyle.muted)
                Spacer(minLength: 3)
                if model.textHistoryLoading { ProgressView().controlSize(.small) }
            }
            Text("本次查询时段归档字符总量：\(page.totalCharacters.formatted())（全部候选记录，不随关键词或分页变化）")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            if !page.coverageComplete {
                Label("还有候选记录尚未扫描；本页没有匹配不代表整个时段无匹配。请继续下一页，也可直接导出完整范围。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.orange).lineSpacing(4)
            }
            if page.entries.isEmpty {
                Text(page.coverageComplete ? "本页没有匹配，范围扫描已到末尾。此前各页可使用“上一页”返回；无记录不代表没有输入。" : "本页已扫描候选中暂无匹配；仍有未扫描记录。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(page.entries) { entry in
                        TextArchiveEntryRow(entry: entry) {
                            actionConfirmation = .record(id: entry.metadata.id, application: entry.metadata.applicationBundleID, time: entry.metadata.timestamp)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button("上一页") { loadingMore = true; model.previousTextHistoryPage() }
                    .disabled(model.textHistoryPageIndex == 0 || model.textHistoryLoading || model.textKeyword != submittedKeyword || model.selectedInterval != submittedInterval)
                Text("本页 \(page.entries.count) 条匹配 · 页面仅保留当前页明文")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                Spacer()
                Button(model.textHistoryLoading ? "正在读取…" : "下一页／继续扫描") { loadingMore = true; model.loadMoreTextHistory() }
                    .disabled(!page.hasMore || model.textHistoryLoading || model.textKeyword != submittedKeyword || model.selectedInterval != submittedInterval)
            }.controlSize(.small)
        }
    }

    private func archivedCharacterMetrics(_ metrics: ArchivedTextMetrics) -> some View {
        RhythmCard(title: "归档字符速度", eyebrow: "ARCHIVED CHARACTERS  /  NOT PHYSICAL KEY SPEED") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 13)], alignment: .leading, spacing: 13) {
                RhythmMetric(title: "已归档字符", value: metrics.totalCharacters.formatted(), unit: "字符")
                RhythmMetric(title: "归档窗口平均", value: characterAverage(metrics), unit: "字符/分钟")
                RhythmMetric(title: "自然分钟归档峰值", value: metrics.peakMinute == nil ? "暂无峰值" : metrics.peakCharactersPerMinute.formatted(), unit: "字符/分")
                RhythmMetric(title: "有归档记录分钟", value: metrics.recordedMinutes.formatted(), unit: "分钟")
            }.padding(.top, 7)
            Text("已归档片段的 30 秒活动窗口并集：\(metrics.archivedActiveSeconds.formatted(.number.precision(.fractionLength(0...3)))) 秒。分母只覆盖这些归档窗口，不是键盘活跃秒或完整应用使用时长。")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            if let peak = metrics.peakMinute, peak.isFinite, peak >= 0 {
                Text("字符峰值所在分钟：\(Date(timeIntervalSince1970: floor(peak / 60) * 60).formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            Text("只统计已保存的提交片段，包含可记录的粘贴/替换字符。平均 = 归档字符数 ÷ 归档窗口并集秒数 × 60；峰值是自然分钟内已归档字符总数，不随搜索关键词或分页改变。没有归档窗口时平均不适用。它不是物理按键次数、间隔 BPM、全系统真实打字速度或效率。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.orange).lineSpacing(4)
        }
    }

    private func characterAverage(_ metrics: ArchivedTextMetrics) -> String {
        guard let average = metrics.averageCharactersPerActiveMinute, average.isFinite, average >= 0,
              metrics.archivedActiveSeconds > 0 else { return "不适用" }
        return average.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func confirmationMessage(_ target: TextActionConfirmation) -> String {
        switch target {
        case .record(_, let application, let time):
            return "删除 \(application) 在 \(time.formatted(.dateTime.year().month().day().hour().minute())) 的这一条文字归档。统计聚合不受影响；如已开启文字同步，删除也将同步到私有端。无法撤销。"
        case .range(let interval):
            return "删除本地时间 \(interval.start.formatted(.dateTime.year().month().day().hour().minute())) 至 \(interval.end.formatted(.dateTime.year().month().day().hour().minute())) 的全部文字归档，包含起点、不包含终点，不受关键词、分页或扫描覆盖限制。统计聚合保持不变；如已开启文字同步，删除也将同步到私有端。无法撤销。"
        case .viewingKey: return "仅在明确确认后复制文字查看密钥。"
        }
    }

    private func search() {
        submittedKeyword = model.textKeyword; submittedInterval = model.selectedInterval; loadingMore = false
        model.refreshTextHistory()
    }
}

private struct TextArchiveEntryRow: View {
    let entry: TextHistoryEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.metadata.timestamp.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text("\(entry.metadata.characterCount.formatted()) 字符").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                Spacer(minLength: 5)
                Button("删除…", role: .destructive) { onDelete() }.controlSize(.small)
            }
            Text(entry.metadata.applicationBundleID).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TrailStyle.muted).textSelection(.enabled)
            Text(String(entry.text.prefix(160)) + (entry.text.count > 160 ? "…" : ""))
                .font(.system(size: 12)).lineSpacing(4).lineLimit(4).textSelection(.enabled)
            DisclosureGroup("查看全文（\(entry.metadata.characterCount.formatted()) 字符）") {
                Text(entry.text).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
            }.font(.system(size: 11))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(TrailStyle.line.opacity(0.65), lineWidth: 1))
    }
}

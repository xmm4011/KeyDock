import SwiftUI

struct AgentProcessView: View {
    @ObservedObject var activity: AgentActivity
    var showFullContent = false
    var onCopy: ((String) -> Void)?
    @State private var expanded = false
    private var steps: [AgentActivityEntry] { activity.keyEntries }
    private var shown: [AgentActivityEntry] { expanded ? steps : (activity.active ? Array(steps.suffix(3)) : []) }
    private var title: String {
        switch activity.record.status {
        case "waiting": return "等待补充资料"
        case "stopping": return "正在停止"
        case "completed": return "整理结束"
        case "stopped": return "已停止"
        case "failed": return "整理遇到问题"
        default: return "整理进展"
        }
    }
    var body: some View {
        if !activity.entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if activity.active && activity.record.status != "waiting" { ProgressView().controlSize(.mini) }
                    else { Image(systemName: activity.record.status == "failed" ? "exclamationmark.circle" : (activity.record.status == "waiting" ? "bubble.left" : (activity.record.status == "stopped" ? "stop.circle" : "checkmark.circle"))).foregroundStyle(Palette.muted) }
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if activity.active { TimelineView(.periodic(from: .now, by: 1)) { _ in Text("\(Int(activity.elapsed)) 秒").font(.system(size: 10)).foregroundStyle(Palette.muted) } }
                }
                if activity.active && steps.isEmpty { Text("正在分析提供的资料…").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                ForEach(shown) { original in
                    let entry = activity.displayEntry(original, showFullContent: showFullContent)
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: entry.state == "failed" ? "exclamationmark.circle" : (entry.state == "running" ? "circle.dotted" : (["stopped", "interrupted"].contains(entry.state) ? "minus.circle" : "checkmark.circle")))
                            .font(.system(size: 11)).foregroundStyle(entry.state == "failed" ? .orange : Palette.muted).frame(width: 14).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title.components(separatedBy: " · ").first ?? entry.title).font(.system(size: 11, weight: .medium))
                            if let summary = entry.summary, !summary.isEmpty { Text(summary).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(entry.state == "failed" ? 4 : 2).textSelection(.enabled) }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button(expanded ? "收起过程" : "查看过程") { expanded.toggle() }.buttonStyle(.link).font(.system(size: 11))
                    Text("\(steps.count) 个关键步骤").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                    if let onCopy { Button("复制全部日志", systemImage: "doc.on.doc") { onCopy(activity.diagnosticText(showFullContent: showFullContent)) }.buttonStyle(.link).font(.system(size: 11)).help("复制当前任务已记录的完整诊断，用于排查问题") }
                }
                if let error = activity.saveError { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            }.padding(14).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border.opacity(0.65)))
        }
    }
}

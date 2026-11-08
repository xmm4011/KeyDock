import SwiftUI

struct ProxyHistoryPanel: View {
    let credentialID: UUID
    @ObservedObject var history: ProxyHistory
    @EnvironmentObject var store: VaultStore
    let onChangeCapture: () -> Void
    let onUse: () -> Void
    @State private var selected: ProxyLogEntry?
    @State private var confirmClear = false
    @State private var showScope = false
    var entries: [ProxyLogEntry] { history.entries.filter { $0.credentialID == credentialID } }
    var totals: ProxyTotals { history.totals[credentialID] ?? ProxyTotals() }
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            SurfaceCard {
                HStack(spacing: 16) {
                    stat("调用次数", "\(totals.calls)")
                    stat("成功次数", "\(totals.successes)")
                    stat("输入 Token", tokenTotal(input: true))
                    stat("输出 Token", tokenTotal(input: false))
                }
                HStack(spacing: 5) {
                    Button { showScope.toggle() } label: {
                        HStack(spacing: 5) { Text("仅统计经 KeyDock 的调用"); Image(systemName: "info.circle") }.font(.system(size: 11))
                    }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("统计与记录范围")
                        .popover(isPresented: $showScope) {
                            Text("不是官方账单。只记录服务返回的 usage，缺失用量不估算，部分用量以 + 标识。\n\n全库保留最近 100 条明细、最多约 8 MB；明细淘汰不影响累计统计。每段正文最多 128 KB，内容仅在本机加密保存，是否显示完整内容由系统设置控制。")
                                .font(.system(size: 12)).lineSpacing(5).padding(20).frame(width: 320)
                        }
                    Spacer(minLength: 0)
                }
            }
            SurfaceCard {
                Toggle("记录请求与响应正文", isOn: Binding(get: { store.recordAllBodies || history.captureBodies.contains(credentialID) }, set: { history.setCapture($0, for: credentialID); onChangeCapture() }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 13, weight: .medium)).disabled(!history.isReadable || store.recordAllBodies)
                Text(store.recordAllBodies ? "已在系统设置中为所有 Key 开启。关闭全局记录后，可在这里单独设置。" : "仅为此 Key 开启；也可在系统设置中为所有 Key 开启。内容在本机加密保存。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            if let error = history.error {
                HStack(alignment: .top, spacing: 12) {
                    Text(store.displayText(error)).font(.system(size: 12)).foregroundStyle(.orange).lineSpacing(4)
                    Spacer(minLength: 0)
                    Button("重试") { history.retryLoading(); onChangeCapture() }.controlSize(.small)
                }
            }
            HStack {
                Text("最近调用").font(.system(size: 14, weight: .semibold))
                if !entries.isEmpty { Text("\(entries.count)").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                Spacer()
                if totals.calls > 0 || !entries.isEmpty {
                    Button("清空记录与统计…") { confirmClear = true }.buttonStyle(.link).font(.system(size: 12))
                }
            }.padding(.top, 4)
            if entries.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 26)).foregroundStyle(Palette.muted.opacity(0.65))
                    Text("还没有调用记录").font(.system(size: 14, weight: .medium))
                    Text("使用本机配置发起请求后，\n会在这里显示状态、用量和耗时。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
                    Button("查看接入配置", action: onUse).controlSize(.regular).padding(.top, 3)
                }.frame(maxWidth: .infinity).padding(.vertical, 26)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in
                        Button { selected = entry } label: { historyRow(entry) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $selected) { entry in ProxyLogView(entry: entry) }
        .alert("清空此 Key 的调用记录与统计？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}; Button("清空", role: .destructive) { history.clear(credentialID) }
        } message: { Text("密钥及其他 Key 的记录不受影响。") }
    }
    private func historyRow(_ entry: ProxyLogEntry) -> some View {
        HStack(spacing: 13) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16)).foregroundStyle(entry.succeeded ? Palette.teal : .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.displayText(entry.model.isEmpty ? entry.method : entry.model)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(entry.startedAt.formatted(date: .omitted, time: .standard) + " · " + entry.method)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text(entry.status.map(String.init) ?? "中断").font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(String(format: "%.2f s", entry.duration)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border.opacity(0.7)))
            .contentShape(Rectangle())
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tokenTotal(input: Bool) -> String {
        let reported = input ? totals.inputReported : totals.outputReported
        guard reported > 0 else { return "—" }
        return String(input ? totals.input : totals.output) + (reported == totals.calls ? "" : "+")
    }
}

struct ProxyLogView: View {
    @EnvironmentObject var store: VaultStore
    let entry: ProxyLogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var response = false
    private var secrets: [String] { store.headerSecrets(entry.requestHeaders + "\n" + entry.responseHeaders) }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "调用详情", subtitle: entry.startedAt.formatted(date: .abbreviated, time: .standard) + " · " + String(format: "%.2f 秒", entry.duration))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(store.displayText(entry.method + " " + entry.requestURL, additionalSecrets: secrets)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Text("状态：" + (entry.status.map(String.init) ?? "未完成"))
                    Text("输入：" + (entry.inputTokens.map(String.init) ?? "未获取"))
                    Text("输出：" + (entry.outputTokens.map(String.init) ?? "未获取"))
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let error = entry.error { Text(store.displayText(error, additionalSecrets: secrets)).font(.system(size: 12)).foregroundStyle(.orange) }
                Picker("内容", selection: $response) { Text("Request").tag(false); Text("Response").tag(true) }.pickerStyle(.segmented)
                if entry.bodiesCaptured {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Header").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            CodePanel(text: store.displayHeaders(response ? entry.responseHeaders : entry.requestHeaders, additionalSecrets: secrets))
                            Text("Body").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            CodePanel(text: store.displayText((response ? entry.responseBody : entry.requestBody).isEmpty ? "（空正文）" : (response ? entry.responseBody : entry.requestBody), additionalSecrets: secrets))
                            if response ? entry.responseTruncated : entry.requestTruncated { Text("内容较大，仅记录前 128 KB。").font(.system(size: 11)).foregroundStyle(.orange) }
                        }
                    }
                } else { ContentUnavailableView("这次未记录正文", systemImage: "doc.text", description: Text("在“记录”页开启“记录请求与响应正文”后，后续调用会保留 Header 和正文。")) }
            }.padding(24)
            Divider()
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(18)
        }.frame(width: 760, height: 650)
    }
}

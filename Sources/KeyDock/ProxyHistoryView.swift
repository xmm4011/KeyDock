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
    @State private var page = 0
    @State private var pageInput = "1"
    private var pageCount: Int { max(1, (entries.count + ProxyHistory.pageSize - 1) / ProxyHistory.pageSize) }
    private var visibleEntries: [ProxyLogEntry] { Array(entries.dropFirst(min(page, pageCount - 1) * ProxyHistory.pageSize).prefix(ProxyHistory.pageSize)) }
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
                            Text("不是官方账单。只记录服务返回的 usage，缺失用量不估算，部分用量以 + 标识。\n\n全库保留最近 5000 条调用，每页 10 条；淘汰不影响累计统计。每段正文最多 2 MB，单独压缩加密保存、按需读取。旧版已截断或未记录的内容无法补回。显示和复制遵循系统设置中的完整内容开关。")
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
                    ForEach(visibleEntries) { entry in
                        Button { selected = entry } label: { historyRow(entry) }.buttonStyle(.plain)
                    }
                }
                pagination
            }
        }
        .onChange(of: credentialID) { page = 0; pageInput = "1" }
        .onChange(of: entries.count) { page = min(page, pageCount - 1) }
        .onChange(of: page) { pageInput = String(page + 1) }
        .sheet(item: $selected) { entry in ProxyLogView(entry: entry) }
        .alert("清空此 Key 的调用记录与统计？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}; Button("清空", role: .destructive) { history.clear(credentialID) }
        } message: { Text("密钥及其他 Key 的记录不受影响。") }
    }
    private var pagination: some View {
        HStack {
            Text("第").font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("页码", text: $pageInput).frame(width: 42).textFieldStyle(.roundedBorder).accessibilityLabel("跳转页码")
                .onSubmit { page = min(pageCount - 1, max(0, (Int(pageInput) ?? (page + 1)) - 1)); pageInput = String(page + 1) }
            Text("/ \(pageCount) 页 · 每页 10 条").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            Button("首页") { page = 0 }.disabled(page == 0)
            Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
            Button("下一页") { page = min(pageCount - 1, page + 1) }.disabled(page + 1 >= pageCount)
            Button("末页") { page = pageCount - 1 }.disabled(page + 1 >= pageCount)
        }
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
    @State private var pretty = true
    @State private var headersExpanded = false
    @StateObject private var presentation = HTTPLogPresentation()
    private var current: ProxyLogEntry { presentation.detail ?? entry }
    private var policy: HTTPLogDisplayPolicy { store.logDisplayPolicy }
    private var ready: Bool { presentation.policy == policy }
    private var variant: HTTPLogVariant { .init(response: response, pretty: pretty) }
    private var document: HTTPTextDocument? { ready ? presentation.documents[variant] : nil }
    private var headers: String { ready ? (presentation.headers[response] ?? "") : "" }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "调用详情", subtitle: entry.startedAt.formatted(date: .abbreviated, time: .standard) + " · " + String(format: "%.2f 秒", entry.duration))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(ready ? presentation.requestLine : entry.method).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                HStack {
                    Text("状态：" + (entry.status.map(String.init) ?? "未完成"))
                    Text("输入：" + (entry.inputTokens.map(String.init) ?? "未获取"))
                    Text("输出：" + (entry.outputTokens.map(String.init) ?? "未获取"))
                    Spacer()
                    if let origin = entry.responseOrigin { Text(origin == "proxy" ? "代理生成响应" : "上游返回响应") }
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                if ready, let error = presentation.failureMessage { Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 16) {
                    Picker("内容", selection: $response) { Text("Request").tag(false); Text("Response").tag(true) }.pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                    Button(response ? "复制响应" : "复制请求") {
                        guard let document else { return }
                        let firstLine = response ? "HTTP " + (entry.status.map(String.init) ?? "未完成") : presentation.requestLine
                        store.copy(firstLine + "\n" + (headers.isEmpty ? "" : headers + "\n\n") + document.text, sensitive: true)
                    }.disabled(document == nil || current.detailsUnavailable != nil || !current.bodiesCaptured)
                }
                if ready, let loadError = presentation.error {
                    ContentUnavailableView("正文暂时无法读取", systemImage: "doc.text", description: Text(loadError))
                } else if let reason = current.detailsUnavailable {
                    ContentUnavailableView("本次仅保留调用摘要", systemImage: "doc.text", description: Text(reason))
                } else if presentation.detail == nil { ProgressView("正在读取正文…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if current.bodiesCaptured {
                    DisclosureGroup(isExpanded: $headersExpanded) {
                        HTTPBodyTextView(text: headers.isEmpty ? "（无 Header）" : headers, onCopy: { store.copy($0, sensitive: true) }).frame(height: 104).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    } label: { Text("Header").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                    HStack {
                        Text("Body").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Picker("正文显示", selection: $pretty) { Text("格式化").tag(true); Text("原文").tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                        Spacer()
                        Button("复制正文") { if let document { store.copy(document.text, sensitive: true) } }.disabled(document == nil)
                    }
                    HTTPBodyViewport(documents: ready ? presentation.documents : [:], selected: variant, onCopy: { store.copy($0, sensitive: true) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
                        .overlay { if document == nil { ProgressView("正在准备正文…") } }
                    if let notice = document?.notice { Text(notice).font(.system(size: 11)).foregroundStyle(.orange) }
                    if response ? current.responseTruncated : current.requestTruncated {
                        let limit = (response ? current.responseBodyLimit : current.requestBodyLimit) ?? RecordedContent.bodyLimit
                        Text("该次正文仅保留前 \(limit / 1024) KB，剩余内容未记录。JSON 片段按现有内容显示。")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                } else { ContentUnavailableView("这次未记录正文", systemImage: "doc.text", description: Text("开启记录请求与响应正文后，后续调用会保留 Header 和正文。")) }
            }.padding(24).frame(maxHeight: .infinity)
            Divider()
            HStack { Text("点击正文后可 ⌘A 全选、⌘C 复制").font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(18)
        }.frame(minWidth: 720, idealWidth: 820, maxWidth: 1100, minHeight: 600, idealHeight: 720, maxHeight: 1000)
            .onChange(of: variant) { presentation.preferred = variant }
            .task(id: policy) { await presentation.load(entry, history: store.history, policy: policy) }
            .onDisappear { presentation.cancel() }
    }
}

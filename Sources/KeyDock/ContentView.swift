import SwiftUI
import AppKit

enum Shelf: String, CaseIterable { case all = "全部", favorites = "收藏", archived = "归档" }

extension Notification.Name {
    static let keydockImport = Notification.Name("keydock.import")
    static let keydockNew = Notification.Name("keydock.new")
    static let keydockSearch = Notification.Name("keydock.search")
}

enum AppSheet: Identifiable {
    case editor(Credential), importer(ImportPaste), backup, cleanup
    var id: String {
        switch self {
        case .editor(let record): return record.id.uuidString
        case .importer: return "import"
        case .backup: return "backup"
        case .cleanup: return "cleanup"
        }
    }
}

struct ContentView: View {
    private enum FocusTarget { case search, list }
    private struct ListState: Equatable {
        var shelf: Shelf
        var ids: [UUID]
    }
    @EnvironmentObject var store: VaultStore
    @State private var shelf: Shelf = .all
    @State private var search = ""
    @FocusState private var focus: FocusTarget?
    @State private var sheet: AppSheet?
    @StateObject private var windowContext = WindowCommandContext()
    private var mainCommandsAvailable: Bool {
        sheet == nil && windowContext.allowsMainCommands
    }
    var visible: [Credential] {
        let results: [(record: Credential, match: CredentialSearchMatch)] = store.credentials.compactMap { item in
            let matches = shelf == .archived ? item.archived : !item.archived && (shelf != .favorites || item.favorite)
            guard matches, let match = item.searchMatch(for: search) else { return nil }
            return (item, match)
        }
        return results.sorted {
            if $0.match.rank != $1.match.rank { return $0.match.rank < $1.match.rank }
            if $0.record.favorite != $1.record.favorite { return $0.record.favorite }
            if $0.record.updatedAt != $1.record.updatedAt { return $0.record.updatedAt > $1.record.updatedAt }
            return $0.record.id.uuidString < $1.record.id.uuidString
        }.map(\.record)
    }
    var body: some View {
        VStack(spacing: 20) {
            header
            if let loadError = store.loadError {
                ContentUnavailableView { Label("暂时无法打开", systemImage: "lock.trianglebadge.exclamationmark") } description: { Text(loadError) } actions: { Button("重试") { store.load() }; Button("恢复备份…") { sheet = .backup } }
            } else {
                HStack(spacing: 0) {
                    credentialList.frame(width: 260)
                    Rectangle().fill(Palette.border).frame(width: 1)
                    if let record = store.selected, visible.contains(where: { $0.id == record.id }) {
                        CredentialDetail(record: record, edit: { sheet = .editor(record) }).id(record.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !store.credentials.isEmpty && visible.isEmpty { emptyResults.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { welcome.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.background(.white, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border))
            }
        }.padding(.horizontal, 24).padding(.top, 38).padding(.bottom, 24).background(Palette.canvas).foregroundStyle(Palette.ink)
            .background(WindowCommandAnchor(context: windowContext).frame(width: 0, height: 0))
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).padding(.horizontal, 18).padding(.vertical, 12).foregroundStyle(.white)
                        .background(Palette.ink, in: Capsule()).padding(.bottom, 25).allowsHitTesting(false)
                }
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .editor(let record): CredentialEditor(record: record, expectedUpdatedAt: store.credentials.contains(where: { $0.id == record.id }) ? record.updatedAt : nil)
                case .importer(let paste): ImportView(initialPaste: paste)
                case .backup: BackupView()
                case .cleanup: CleanupView()
                }
            }
            .alert("操作未完成", isPresented: Binding(get: { store.error != nil && sheet == nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.displayText(store.error ?? "")) }
            .onReceive(NotificationCenter.default.publisher(for: .keydockImport)) { _ in if store.loadError == nil { beginImport() } }
            .onReceive(NotificationCenter.default.publisher(for: .keydockNew)) { _ in if store.loadError == nil && mainCommandsAvailable { sheet = .editor(Credential()) } }
            .onReceive(NotificationCenter.default.publisher(for: .keydockSearch)) { _ in if store.loadError == nil && mainCommandsAvailable { focus = .search } }
            .onChange(of: ListState(shelf: shelf, ids: visible.map(\.id))) { previous, current in
                if !current.ids.contains(store.selectedID ?? UUID()) {
                    if previous.shelf == .archived, current.shelf == .archived,
                       let selected = store.selected, previous.ids.contains(selected.id), !selected.archived { search = ""; shelf = .all }
                    else { store.selectedID = current.ids.first }
                }
            }
            .onChange(of: store.selectedID) { _, id in
                guard let id, let record = store.credentials.first(where: { $0.id == id }) else { return }
                if !visible.contains(where: { $0.id == id }) { search = ""; shelf = record.archived ? .archived : .all }
            }
    }
    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill").font(.system(size: 22)).foregroundStyle(Palette.accent).frame(width: 43, height: 43).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("KeyDock").font(.system(size: 23, weight: .bold, design: .rounded))
                Text("粘贴进来，整理好，随时用。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button(action: beginImport) { Label("粘贴添加", systemImage: "plus").padding(.horizontal, 9).padding(.vertical, 6) }.buttonStyle(.borderedProminent).disabled(store.loadError != nil)
            Menu {
                SettingsLink { Label("系统设置…", systemImage: "gearshape") }
                Button("手动添加…", systemImage: "square.and.pencil") { sheet = .editor(Credential()) }
                Divider()
                Button("检查全部连接", systemImage: "arrow.clockwise") { store.verifyAll() }.disabled(store.active.isEmpty || store.batchRunning)
                Button("清理失效 Key…", systemImage: "archivebox") { sheet = .cleanup }
                Divider()
                Button("加密备份与恢复…", systemImage: "externaldrive") { sheet = .backup }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 21)).foregroundStyle(Palette.muted) }.menuStyle(.borderlessButton).frame(width: 28).disabled(store.loadError != nil)
        }.background(WindowZoomArea())
    }
    var credentialList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索名称、厂商、模型、用途", text: $search).textFieldStyle(.plain).focused($focus, equals: .search).onSubmit { focusResults(selectFirst: true) }
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
            }
                .font(.system(size: 12)).padding(11).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9)).padding(14)
            Picker("列表", selection: $shelf) { ForEach(Shelf.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 13)
            Divider().overlay(Palette.border)
            if visible.isEmpty {
                Spacer()
                Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 25)).foregroundStyle(Palette.muted.opacity(0.45))
                Text(emptyTitle).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 9)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(spacing: 10) {
                        ForEach(visible) { record in
                            Button { store.selectedID = record.id; focusResults() } label: { CredentialCard(record: record, selected: store.selectedID == record.id, checking: store.checking.contains(record.id), searchHint: record.searchMatch(for: search)?.detail) }.buttonStyle(.plain)
                                .id(record.id)
                                .modifier(CredentialContextActions(record: record, edit: { guard sheet == nil else { return }; sheet = .editor(record) }))
                        }
                    }.padding(12) }
                        .focusable().focused($focus, equals: .list).focusEffectDisabled()
                        .onMoveCommand { direction in
                            if direction == .up { moveSelection(by: -1) }
                            else if direction == .down { moveSelection(by: 1) }
                        }
                        .onAppear { if let id = store.selectedID { proxy.scrollTo(id) } }
                        .onChange(of: store.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                        .onChange(of: visible.map(\.id)) { _, ids in
                            if let id = store.selectedID, ids.contains(id) { proxy.scrollTo(id) }
                        }
                        .onChange(of: focus) { _, focused in if focused == .list, let id = store.selectedID { proxy.scrollTo(id) } }
                        .onChange(of: search) { _, _ in if let id = visible.first?.id { proxy.scrollTo(id, anchor: .top) } }
                }
            }
            Divider().overlay(Palette.border)
            HStack {
                if store.batchRunning {
                    ProgressView().controlSize(.mini); Text(store.batchProgress); Spacer(); Button("停止") { store.cancelBatch() }.buttonStyle(.plain)
                } else { Text("\(visible.count) 条记录"); Spacer(); ConnectionIndicator(proxy: store.proxy) }
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(14)
        }
    }
    private func focusResults(selectFirst: Bool = false) {
        guard mainCommandsAvailable, !visible.isEmpty else { return }
        if selectFirst || !visible.contains(where: { $0.id == store.selectedID }) { store.selectedID = visible.first?.id }
        focus = .list
    }
    private func moveSelection(by offset: Int) {
        guard mainCommandsAvailable, focus == .list, !visible.isEmpty else { return }
        let rows = visible
        let index = rows.firstIndex { $0.id == store.selectedID } ?? (offset > 0 ? -1 : rows.count)
        store.selectedID = rows[min(max(index + offset, 0), rows.count - 1)].id
    }
    private var emptyTitle: String {
        if !search.isEmpty { return "没有匹配的 Key" }
        if store.credentials.isEmpty { return "还没有记录" }
        switch shelf {
        case .favorites: return "还没有收藏的 Key"
        case .archived: return "没有已归档的 Key"
        case .all: return "没有未归档的 Key"
        }
    }
    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(Palette.muted)
            Text(emptyTitle).font(.system(size: 23, weight: .semibold))
            Text(!search.isEmpty ? "换个搜索词，或查看已有条目。" : (store.active.isEmpty ? "条目仍保存在归档中，需要时可以恢复。" : (shelf == .favorites ? "在详情顶部点击星标，常用 Key 会显示在这里。" : "归档的条目会显示在这里，可随时恢复。")))
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
            Button(store.active.isEmpty ? "查看归档" : "查看全部") { search = ""; shelf = store.active.isEmpty ? .archived : .all }.buttonStyle(.borderedProminent)
        }.padding(35).frame(maxWidth: 410, alignment: .leading)
    }
    var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(Palette.accent)
            Text(store.credentials.isEmpty ? "发来的 Key，\n粘贴一下就收好了。" : "点选一条 Key，\n复制就能用。").font(.system(size: 26, weight: .bold)).lineSpacing(5)
            Text("聊天文字、curl、配置都可以。\n自动整理，你只需确认一下。").font(.system(size: 12)).lineSpacing(6).foregroundStyle(Palette.muted)
            Button("粘贴添加", action: beginImport).buttonStyle(.borderedProminent).padding(.top, 5)
            Text("本机加密保存 · 复制使用不带真实 Key").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 15)
        }.padding(35).frame(maxWidth: 410, alignment: .leading)
    }
    func beginImport() { guard mainCommandsAvailable else { return }; sheet = .importer(ImportPaste.from(.general)) }
}

struct ConnectionIndicator: View {
    @ObservedObject var proxy: LocalProxy
    var body: some View {
        Button { if !proxy.running { proxy.start() } } label: {
            HStack(spacing: 5) { Circle().fill(proxy.running ? Palette.teal : Color.orange).frame(width: 5, height: 5); Text(proxy.running ? "可直接使用" : "点击恢复连接") }
        }.buttonStyle(.plain).help(proxy.error ?? "保持 KeyDock 运行即可在项目中使用。")
    }
}

struct CredentialCard: View {
    @EnvironmentObject var store: VaultStore
    let record: Credential
    let selected: Bool
    let checking: Bool
    var searchHint: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderIcon(record: record, size: 34)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(store.displayText(record.title)).font(.system(size: 13, weight: .semibold)).lineLimit(1); Spacer(minLength: 0); if record.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange) } }
                Text(store.displayText(searchHint ?? (record.purpose.isEmpty ? record.host : record.purpose))).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                if checking { ProgressView().controlSize(.mini) } else { StatusBadge(record: record) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Palette.accent.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Palette.accent.opacity(0.3) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

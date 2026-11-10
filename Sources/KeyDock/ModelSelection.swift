import SwiftUI
import Combine

@MainActor final class ModelListLoader: ObservableObject {
    @Published private(set) var models: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var selected: Credential?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    func select(_ record: Credential?) {
        if let record, let selected, record.hasSameModelCatalogConfiguration(as: selected) {
            if record.modelCatalog != selected.modelCatalog || record.availableModels != selected.availableModels { models = record.availableModels; error = nil }
            self.selected = record; return
        }
        cancel(); selected = record; models = record?.availableModels ?? []; error = nil
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
    func fetch(session: URLSession = APIClient.session) {
        guard let record = selected else { return }
        cancel(); let requestID = generation; loading = true; error = nil
        task = Task {
            let result = await APIClient.fetchModels(record, session: session)
            guard !Task.isCancelled, generation == requestID else { return }
            loading = false; task = nil
            if result.state == .valid {
                models = result.models
                if models.isEmpty { error = "接口返回了空列表，可以手动填写模型 ID。" }
            } else { error = result.message }
        }
    }
}

struct ModelSelectionField: View {
    @EnvironmentObject var store: VaultStore
    let service: Credential?
    @Binding var model: String
    @StateObject private var loader = ModelListLoader()
    private var modelChoices: [String] {
        Credential.modelChoices(current: model, available: Credential.modelChoices(current: service?.model ?? "", available: (service?.manualModels ?? []) + loader.models))
    }
    var body: some View {
        let choices = modelChoices
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("模型名称", text: $model, prompt: Text("填写模型 ID，或从右侧列表选择"))
                Menu(loader.loading ? "获取中…" : "模型列表") {
                    Button(loader.models.isEmpty ? "获取模型列表" : "刷新模型列表") { loader.fetch() }.disabled(loader.loading)
                    Button("复制模型列表") { store.copy(choices.joined(separator: "\n")) }.disabled(choices.isEmpty)
                    if !choices.isEmpty { Divider() }
                    if loader.models.isEmpty && !choices.isEmpty { Text("当前已配置模型") }
                    ForEach(choices, id: \.self) { name in
                        Button(store.displayText(name)) { model = name }
                            .disabled(service.flatMap { store.modelIssue(name, for: $0) } != nil)
                    }
                }.fixedSize().disabled(service == nil)
            }
            if !model.trimmed.isEmpty, let service, let issue = store.modelIssue(model, for: service) { Text(issue).font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(3) }
            else if let error = loader.error { Text(store.displayText(error)).font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(3).textSelection(.enabled) }
        }
        .onAppear { loader.select(service) }
        .onChange(of: service) { _, value in loader.select(value) }
        .onDisappear { loader.cancel() }
    }
}

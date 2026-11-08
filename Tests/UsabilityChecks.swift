import SwiftUI
import Foundation
import CryptoKit

@MainActor enum UsabilityChecks {
    static func run() async {
        await modelRequests()
        runCheck("Usability.failed-run-retains-reply-unsent-input-and-recovery-through-retry") {
            let interaction = AgentInteraction(), record = DeepChecks.record()
            interaction.lastReply = AgentQuestion(question:"文档已核对，等待网关响应。")
            interaction.document = ImportDocument(ImportPaste(text:"请改用另一个接入点"))
            interaction.fail("连接中断",recovery:AgentImportResult(records:[record],summary:"已有候选",activity:[]))
            expectTrue(interaction.displayedReply?.question.contains("连接中断") == true)
            expectTrue(interaction.displayedReply?.question.contains("文档已核对") == true)
            expectEqual(interaction.document.text,"请改用另一个接入点")
            expectEqual(interaction.recovery?.records.first?.id,record.id)
            interaction.begin(); expectNil(interaction.failure)
            interaction.fail("本次暂时限流")
            expectTrue(interaction.failure?.question.contains("本次暂时限流") == true)
            expectEqual(interaction.recovery?.records.first?.id,record.id)
            expectEqual(interaction.document.text,"请改用另一个接入点")
            interaction.fail("本次暂时限流")
            expectEqual(interaction.failure?.question.components(separatedBy:"本次暂时限流").count,2)
        }
        runCheck("Usability.unfinished-candidates-are-redacted-before-offering-recovery") {
            try NewFeatureChecks.isolated { root in
                let host = ImportAgentHost(original:"Base URL: https://example.com/v1",imageText:"",images:[try NewFeatureChecks.image()],workspace:root,session:APIClient.session)
                let first = "fixture-image-key-first-12345678", second = "fixture-image-key-second-98765432"
                _ = try host.propose(["api_key":first,"base_url":"https://example.com/v1","kind":"compatible","notes":"其他片段 "+second])
                _ = try host.propose(["api_key":second,"base_url":"https://example.com/v1","kind":"compatible"])
                host.activity.append("待核对 "+second)
                let result = host.reviewResult(reply:"尚未完成 "+first)
                expectEqual(result.records.count,2); expectFalse(result.records[0].notes.contains(second))
                expectFalse(result.activity.joined().contains(second)); expectFalse(result.reply.contains(first))
                expectEqual(result.records[0].apiKey,first); expectNil(result.records[0].check)
            }
        }
        runCheck("Usability.copy-eligibility-is-consistent-for-expiry-archive-and-missing-model") {
            var record = DeepChecks.record(); record.model = "fixture"
            expectTrue(record.canCopyUsage)
            record.expiresAt = Date().addingTimeInterval(-10); expectFalse(record.canCopyUsage)
            record.expiresAt = nil; record.archived = true; expectFalse(record.canCopyUsage)
            record.archived = false; record.model = ""; expectFalse(record.canCopyUsage)
            record.kind = .custom; expectTrue(record.canCopyUsage)
            expectFalse(record.safeShareText.contains("curl --request POST")); expectFalse(record.safeShareText.contains("选择或填写实际调用的模型"))
        }
    }
    private static func modelRequests() async {
        let session = MockURLProtocol.session { request in
            let delay:TimeInterval = request.url?.host == "old.example" ? 0.3 : 0.03
            let name = request.url?.host == "old.example" ? "old-model" : "current-model"
            return MockReply(body:Data(("{\"data\":[{\"id\":\""+name+"\"}]}").utf8),delay:delay)
        }
        defer { session.invalidateAndCancel() }
        let loader = ModelListLoader()
        var first = DeepChecks.record(); first.baseURL = "https://old.example/v1"
        var second = first; second.id = UUID(); second.baseURL = "https://new.example/v1"
        loader.select(first); loader.fetch(session:session)
        try? await Task.sleep(for:.milliseconds(25))
        loader.select(second); loader.fetch(session:session)
        await InteractionFlowChecks.wait { !loader.loading }
        expectEqual(loader.models,["current-model"])
        try? await Task.sleep(for:.milliseconds(350))
        expectEqual(loader.models,["current-model"]); expectFalse(loader.loading); expectNil(loader.error)
        checkpoint("Usability.switching-model-service-cancels-old-fetch-and-never-overwrites-current-results")
        loader.select(first); loader.fetch(session:session)
        try? await Task.sleep(for:.milliseconds(20)); loader.select(nil)
        expectFalse(loader.loading); expectEqual(loader.models,[])
        try? await Task.sleep(for:.milliseconds(350))
        expectEqual(loader.models,[]); expectNil(loader.error)
        checkpoint("Usability.clearing-model-service-leaves-no-stale-spinner-or-background-result")
        loader.select(second); loader.fetch(session:session); await InteractionFlowChecks.wait { !loader.loading }
        var metadata = second; metadata.notes = "new notes"; loader.select(metadata)
        expectEqual(loader.models,["current-model"])
        metadata.modelCatalog = ModelCatalog(models:["updated-store-model"]); loader.select(metadata)
        expectEqual(loader.models,["updated-store-model"])
        checkpoint("Usability.model-selector-keeps-fetched-results-on-note-edit-and-accepts-newer-store-catalogs")
        second.modelCatalog = ModelCatalog(models:["cached-model"]); loader.select(second)
        expectEqual(loader.models,["cached-model"])
        let failing = MockURLProtocol.session { _ in MockReply(status:404,body:Data(#"{"error":{"message":"not supported"}}"#.utf8)) }
        defer { failing.invalidateAndCancel() }
        loader.fetch(session:failing); await InteractionFlowChecks.wait { !loader.loading }
        expectEqual(loader.models,["cached-model"]); expectTrue(loader.error != nil)
        loader.cancel(); expectFalse(loader.loading)
        checkpoint("Usability.failed-model-refresh-keeps-existing-list-and-reports-the-reason")
    }
}

import Foundation
import CryptoKit

@MainActor enum CapabilityAvailabilityChecks {
    static func run() async {
        runCheck("Availability.balance-disabled-until-native-or-complete-custom-query-is-configured") {
            var record = DeepChecks.record(); record.baseURL = "https://relay.invalid/v1"; record.balanceURL = ""; record.balancePath = ""
            expectTrue(APIClient.balanceIssue(record)?.contains("未配置") == true)
            record.balanceURL = "https://relay.invalid/balance"
            expectTrue(APIClient.balanceIssue(record)?.contains("字段路径") == true)
            record.balancePath = "data.balance"; expectNil(APIClient.balanceIssue(record))
            record.apiKey = ""; expectTrue(APIClient.balanceIssue(record) != nil)
            record.apiKey = "fixture-api-key"; record.balanceURL = "file:///tmp/balance"
            expectTrue(APIClient.balanceIssue(record) != nil)
            record.baseURL = "https://api.deepseek.com"; record.balanceURL = ""; record.balancePath = ""
            expectNil(APIClient.balanceIssue(record))
            record.baseURL = "https://api.baichuan-ai.com/v1"; expectTrue(APIClient.balanceIssue(record) != nil)
        }
        runCheck("Availability.catalog-and-verification-use-configuration-and-observed-capabilities") {
            var record = DeepChecks.record(); record.baseURL = "https://relay.invalid/v1"; record.model = "fixture-model"
            expectNil(APIClient.catalogIssue(record)); expectNil(APIClient.verificationIssue(record, testModel: true))
            record.model = ""; expectTrue(APIClient.verificationIssue(record, testModel: true) != nil)
            record.kind = .custom; record.verificationURL = ""
            expectTrue(APIClient.catalogIssue(record) != nil); expectTrue(APIClient.verificationIssue(record, testModel: false) != nil)
            record.verificationURL = "https://relay.invalid/status"; expectNil(APIClient.verificationIssue(record, testModel: false))
            record.kind = .compatible; record.verificationURL = ""; record.baseURL = "https://api.baichuan-ai.com/v1"
            expectTrue(APIClient.catalogIssue(record) != nil)
            record.modelCatalog = ModelCatalog(models: ["observed-model"])
            expectNil(APIClient.catalogIssue(record))
            record.archived = true
            expectTrue(APIClient.catalogIssue(record) != nil); expectTrue(APIClient.verificationIssue(record, testModel: false) != nil); expectTrue(APIClient.balanceIssue(record) != nil)
        }
        runCheck("Availability.import-notes-keep-only-short-unique-facts-without-empty-headings") {
            let notes = ImportAgentHost.structuredNotes(["access": ["仅供测试环境", "仅供测试环境。", ""], "limits": ["仅供测试环境。"], "pending": []])
            expectEqual(notes, "仅供测试环境")
            expectEqual(ImportAgentHost.structuredNotes([:]), "")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Availability-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = CapabilityRequestCounter()
        let session = MockURLProtocol.session { _ in counter.increment(); return MockReply(body: Data(#"{"data":{"balance":7}}"#.utf8)) }
        defer { session.invalidateAndCancel() }
        do {
            let key = SymmetricKey(size: .bits256), store = VaultStore(disk: EncryptedVault(directory: root, keyProvider: { key }), automaticProxy: false)
            var record = DeepChecks.record(); record.baseURL = "https://relay.invalid/v1"; record.balanceURL = ""; record.balancePath = ""
            expectTrue(store.save(record)); record = try unwrap(store.selected)
            await store.queryBalance(record, session: session)
            expectEqual(counter.count, 0); expectNil(store.error); expectTrue(store.balanceChecking.isEmpty)
            record.balanceURL = "https://relay.invalid/balance"; record.balancePath = "data.balance"; record.balanceUnit = "CNY"
            expectTrue(store.save(record)); record = try unwrap(store.selected)
            await store.queryBalance(record, session: session)
            expectEqual(counter.count, 1); expectEqual(store.selected?.balanceSummary, "7 CNY"); expectNil(store.error)
            store.archive([record.id]); record = try unwrap(store.credentials.first { $0.id == record.id })
            await store.queryBalance(record, session: session)
            expectEqual(counter.count, 1); expectNil(store.error)
            checkpoint("Availability.unavailable-balance-does-not-send-or-open-an-error-and-configuring-it-enables-query")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("Availability.balance-store-regression-completes") }
    }
}
private final class CapabilityRequestCounter: @unchecked Sendable {
    let lock = NSLock(); private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

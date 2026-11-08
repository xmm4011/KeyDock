import Foundation
import CryptoKit

@main
enum CheckRunner {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-directory"), CommandLine.arguments.indices.contains(index + 1) { LayoutChecks.outputDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1]) }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--instance-lock-hold" {
            do {
                let file = URL(fileURLWithPath: CommandLine.arguments[2])
                let lock = try FileInstanceLock(file: file)
                try Data().write(to: URL(fileURLWithPath: file.path + ".ready-\(getpid())"))
                guard let lock else { exit(42) }
                withExtendedLifetime(lock) {
                    let deadline = Date().addingTimeInterval(15)
                    while !FileManager.default.fileExists(atPath: file.path + ".release") && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                }; return
            } catch { exit(43) }
        }
        if CommandLine.arguments.contains("--live-deepseek") { await LiveChecks.run(); return }
        if CommandLine.arguments.contains("--sdk-fixture") { await SDKFixture.run(); return }
        if CommandLine.arguments.contains("--raw-display-checks") {
            RawDisplayChecks.run()
            await GlobalSettingsChecks.run()
            await ModelProtocolMemoryChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL RAW DISPLAY AND MODEL PROTOCOL CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--output-limit-checks") {
            await OutputLimitChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL OUTPUT LIMIT CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--deep-retest-checks") {
            await DeepRetestChecks.run()
            ListNavigationChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL DEEP RETEST CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--capability-audit-checks") {
            await CapabilityAuditChecks.run()
            LayoutChecks.audit()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL CAPABILITY AUDIT CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--preset-reference-json") {
            print(String(decoding: try! JSONSerialization.data(withJSONObject: ProviderPreset.all.map(\.reference), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)); return
        }
        if CommandLine.arguments.contains("--preset-checks") {
            await PresetProtocolChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL PRESET CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--editor-checks") {
            EditorInteractionChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL EDITOR CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--workflow-checks") {
            await WorkflowChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL WORKFLOW CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--catalog-checks") {
            await CatalogChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL CATALOG CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--usability-checks") {
            await UsabilityChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL USABILITY CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--interaction-checks") {
            await InteractionFlowChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL INTERACTION CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--agent-checks") {
            await AgentChecks.run()
            await AgentConversationChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL AGENT CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--system-environment-checks") { await SystemChecks.environment(); return }
        if CommandLine.arguments.contains("--clipboard-timer-checks") { await SystemChecks.clipboardTimer(); return }
        if CommandLine.arguments.contains("--lifecycle-checks") {
            await LifecycleChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL LIFECYCLE CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--layout-checks") {
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot-directory"), CommandLine.arguments.indices.contains(index + 1) {
                LayoutChecks.outputDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            }
            LayoutChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL LAYOUT CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--navigation-checks") {
            ListNavigationChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL NAVIGATION CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--validation-checks") {
            await ValidationChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL VALIDATION CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--manual-model-checks") {
            await ManualModelChecks.run()
            ManualModelChecks.native()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL MANUAL MODEL CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--cleanup-checks") {
            CleanupChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL CLEANUP CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        if CommandLine.arguments.contains("--soak") { await SoakChecks.run(); return }
        if CommandLine.arguments.contains("--proxy-checks") {
            await AdvancedProxyChecks.run()
            if !checkFailures.isEmpty { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
            print("ALL PROXY CHECKS PASSED (\(checkCount) scenarios)"); return
        }
        let suites: [(String, () throws -> Void)] = [
            ("ParserTests.testCurlImportPreservesEndpointModelAndHeaders", { try ParserTests().testCurlImportPreservesEndpointModelAndHeaders() }),
            ("ParserTests.testMultipleKeysForSameVendorRemainSeparate", { ParserTests().testMultipleKeysForSameVendorRemainSeparate() }),
            ("ParserTests.testJSONAndNestedConfig", { ParserTests().testJSONAndNestedConfig() }),
            ("ParserTests.testEnvironmentVariablesAndNoShellExecution", { ParserTests().testEnvironmentVariablesAndNoShellExecution() }),
            ("ParserTests.testAmbiguousMultiEndpointBlockDoesNotGuess", { ParserTests().testAmbiguousMultiEndpointBlockDoesNotGuess() }),
            ("ParserTests.testDuplicatesAreRemovedByKeyAndURL", { ParserTests().testDuplicatesAreRemovedByKeyAndURL() }),
            ("ParserTests.testRedactionReplacesEveryOccurrenceAndJSONKey", { ParserTests().testRedactionReplacesEveryOccurrenceAndJSONKey() }),
            ("ParserTests.testProviderAndExpiry", { ParserTests().testProviderAndExpiry() }),
            ("RequestTests.testEndpointPreservesGatewayPrefix", { try RequestTests().testEndpointPreservesGatewayPrefix() }),
            ("RequestTests.testDefaultVersionAndGemini", { try RequestTests().testDefaultVersionAndGemini() }),
            ("RequestTests.testRejectsInsecureRemoteAndHeaderInjection", { RequestTests().testRejectsInsecureRemoteAndHeaderInjection() }),
            ("RequestTests.testQueryURLMustBeExplicitCustomVerification", { try RequestTests().testQueryURLMustBeExplicitCustomVerification() }),
            ("RequestTests.testStatusNeverConfusesNetworkQuotaOrPermissionsWithInvalidKey", { RequestTests().testStatusNeverConfusesNetworkQuotaOrPermissionsWithInvalidKey() }),
            ("RequestTests.testSafeConfigurationHasNoRealSecretAndDifferentAliases", { RequestTests().testSafeConfigurationHasNoRealSecretAndDifferentAliases() }),
            ("RequestTests.testOnlyOfficialDeepSeekHostGetsAutomaticBalanceRequest", { try RequestTests().testOnlyOfficialDeepSeekHostGetsAutomaticBalanceRequest() }),
            ("VaultTests.testEncryptedPersistenceAndTamperDetection", { try VaultTests().testEncryptedPersistenceAndTamperDetection() }),
            ("VaultTests.testPortableBackupRoundtripWrongPasswordAndTampering", { try VaultTests().testPortableBackupRoundtripWrongPasswordAndTampering() }),
            ("ProxyTests.testAliasMapsToExactKeyAndPreservesPathBodyQuery", { try ProxyTests().testAliasMapsToExactKeyAndPreservesPathBodyQuery() }),
            ("ProxyTests.testMultipleKeysOnOneVendorRouteSeparately", { try ProxyTests().testMultipleKeysOnOneVendorRouteSeparately() }),
            ("ProxyTests.testBrowserArchivedExpiredTraversalAndUnknownAliasesAreDenied", { ProxyTests().testBrowserArchivedExpiredTraversalAndUnknownAliasesAreDenied() }),
            ("ProxyTests.testHTTPFramingAndChunkedUploadRejection", { try ProxyTests().testHTTPFramingAndChunkedUploadRejection() }),
        ]
        for (name, run) in suites {
            do { try run() } catch { checkFailures.append(name + ": " + error.localizedDescription) }
            checkpoint(name)
        }
        DeepChecks.run()
        await DeepNetworkChecks.run()
        await NewFeatureChecks.run()
        await AgentChecks.run()
        await AgentConversationChecks.run()
        await InteractionFlowChecks.run()
        await UsabilityChecks.run()
        await WorkflowChecks.run()
        await LifecycleChecks.run()
        EditorInteractionChecks.run()
        await DomesticProviderChecks.run()
        await PresetProtocolChecks.run()
        await CapabilityAuditChecks.run()
        await DeepRetestChecks.run()
        await OutputLimitChecks.run()
        RawDisplayChecks.run()
        await GlobalSettingsChecks.run()
        await ModelProtocolMemoryChecks.run()
        await AdvancedProxyChecks.run()
        DeepStoreChecks.run()
        PersistenceRegressionChecks.run()
        StoreChecks.run()
        await IntegrationChecks.run()
        await ValidationChecks.run()
        await ManualModelChecks.run()
        await CatalogChecks.run()
        ListNavigationChecks.run()
        CleanupChecks.run()
        ManualModelChecks.native()
        // Finish asynchronous service fixtures before the native window suite;
        // AppKit can otherwise end the command-line host on the next idle turn.
        LayoutChecks.run()
        if checkFailures.isEmpty { print("ALL CHECKS PASSED (\(checkCount) scenarios)") }
        else { checkFailures.forEach { print("FAIL " + $0) }; exit(1) }
    }
}

import Foundation
import AppKit

@MainActor enum TaskLifecycleChecks {
    static func run() async {
        runCheck("TaskLifecycle.keyboard-autorepeat-is-consumed-without-repeating-stop-or-close") {
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var stopped = 0, closed = 0
            let anchor = SheetShortcuts.Anchor(close: { closed += 1 }, cancel: { stopped += 1 })
            window.contentView = anchor
            defer { window.close() }
            for repeatKey in [false, true, true, true] {
                let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: repeatKey, keyCode: 53))
                expectTrue(anchor.consume(event))
            }
            expectEqual(stopped, 1); expectEqual(closed, 0)
            let close = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
            expectTrue(anchor.consume(close)); expectEqual(closed, 1); expectEqual(stopped, 1)
        }
        runCheck("TaskLifecycle.stop-is-idempotent-preserves-data-and-rejects-late-errors-and-completion") {
            let interaction = AgentInteraction(), service = DeepChecks.record()
            interaction.postUser(ImportPaste(text: "retain these materials"))
            let id = interaction.begin()
            interaction.activity.begin(raw: "fixture materials", service: service, model: "fixture")
            interaction.activity.update(id: "probe", title: "验证调用", detail: "fixture request", state: "running", summary: "正在验证")
            expectTrue(interaction.requestStop()); expectTrue(interaction.isBusy); expectTrue(interaction.isStopping)
            for _ in 0..<8 { expectFalse(interaction.requestStop()) }
            interaction.fail("late transport error", runID: id)
            interaction.postReply("late narration", runID: id)
            interaction.postCompletion(summary: "late success", reply: "late narration", runID: id)
            expectNil(interaction.failure); expectNil(interaction.error); expectEqual(interaction.messages.count, 1)
            interaction.finishRun(id, cancelled: true)
            let count = interaction.activity.entries.count
            interaction.finishRun(id, cancelled: true)
            expectEqual(interaction.activity.entries.count, count)
            expectEqual(interaction.taskState, .stopped); expectFalse(interaction.isBusy)
            expectEqual(interaction.messages.first?.text, "retain these materials")
            expectEqual(interaction.activity.record.status, "stopped")
        }
        runCheck("TaskLifecycle.new-run-rejects-old-generation-callbacks-and-completes-local-work") {
            let interaction = AgentInteraction()
            let old = interaction.begin(); _ = interaction.requestStop(); interaction.finishRun(old, cancelled: true)
            let current = interaction.begin()
            expectTrue(current != old); expectEqual(interaction.begin(), current)
            interaction.activity.beginLocal(raw: "fixture local source")
            interaction.finishRun(old, cancelled: true)
            interaction.fail("old error", runID: old); interaction.postReply("old message", runID: old)
            expectEqual(interaction.taskState, .running); expectTrue(interaction.messages.isEmpty)
            interaction.finishRun(current)
            expectEqual(interaction.taskState, .completed); expectEqual(interaction.activity.record.status, "completed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Stop-" + UUID().uuidString)
        let server = FixtureServer { _ in
            let args = #"{"command":"node -e \"console.log('stop-fixture-started');setTimeout(()=>console.log('unexpected-late-output'),30000)\"","timeout":40}"#
            let delta: [String: Any] = ["role": "assistant", "tool_calls": [["index": 0, "id": "stop-call", "type": "function", "function": ["name": "bash", "arguments": args]]]]
            let choices: [[String: Any]] = [["index": 0, "delta": delta, "finish_reason": NSNull()], ["index": 0, "delta": [:], "finish_reason": "tool_calls"]]
            let stream = choices.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: ["id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture", "choices": [$0]]), as: UTF8.self) + "\n\n" }.joined() + "data: [DONE]\n\n"
            return FixtureResponse(headers: ["Content-Type": "text/event-stream"], chunks: [Data(stream.utf8)])
        }
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        do {
            try server.start(); await InteractionFlowChecks.wait { server.port != nil }
            let interaction = AgentInteraction(); interaction.activity.directory = root
            interaction.postUser(ImportPaste(text: "source is preserved"))
            var service = DeepChecks.record(); service.baseURL = "http://127.0.0.1:\(try unwrap(server.port))/organizer/v1"
            let task = Task { try await ImportAgent.run(raw: "API Key: fixture-target-key\nBase URL: https://fixture.invalid/v1", service: service, model: "fixture", images: [], promptConfiguration: .init(directory: root.appendingPathComponent("prompts")), interaction: interaction, progress: { _ in }) }
            for _ in 0..<400 {
                if interaction.activity.text.contains("输出：\nstop-fixture-started") { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            expectTrue(interaction.activity.text.contains("输出：\nstop-fixture-started"))
            expectTrue(interaction.requestStop()); task.cancel()
            for _ in 0..<6 { expectFalse(interaction.requestStop()) }
            do { _ = try await task.value; checkFailures.append("Stopped Agent returned a result") } catch {}
            expectEqual(interaction.taskState, .stopped); expectEqual(interaction.activity.record.status, "stopped")
            expectNil(interaction.failure); expectNil(interaction.error); expectNil(interaction.supplement)
            expectEqual(interaction.messages.count, 1)
            expectFalse(interaction.activity.text.contains("输出：\nunexpected-late-output"))
            checkpoint("TaskLifecycle.real-SDK-stop-during-bash-finishes-once-without-error-replies-or-extra-prompts")
        } catch { checkFailures.append(error.localizedDescription); checkpoint("TaskLifecycle.real-stop-regression-completes") }
    }
}

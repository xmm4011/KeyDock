import Foundation

// Explicit live check only. Credentials arrive on stdin and are never saved.
@MainActor enum HTTPGatewayChecks {
    static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-HTTP-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            guard let line = readLine(), let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let base = input["base_url"], let key = input["api_key"], let model = input["model"] else {
                throw KeyDockError.message("Provide base_url, api_key and model as JSON on stdin.")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let host = ImportAgentHost(original: "Base URL: " + base + "\napi-key: " + key, imageText: "", images: [], workspace: root, session: APIClient.session)
            let draft = try host.propose(["base_url": base, "api_key": "KEYDOCK_SECRET_1", "kind": "compatible", "auth": "bearer"])
            let id = draft["id"] as! String
            let catalog = await host.call("list_models", args: ["id": id])
            guard catalog["ok"] as? Bool == true, let models = catalog["models"] as? [String], models.contains(model) else {
                throw KeyDockError.message("Catalog failed: " + (catalog["message"] as? String ?? "model absent"))
            }
            print("PASS live host catalog: HTTP \(catalog["status"] ?? "unknown"), \(models.count) models")
            _ = try host.propose(["id": id, "base_url": base, "api_key": "KEYDOCK_SECRET_1", "kind": "compatible", "auth": "bearer", "model": model])
            let body = String(decoding: try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": "Reply only OK."]], "max_tokens": 16, "stream": false]), as: UTF8.self)
            let result = await host.call("verify_credential", args: ["id": id, "method": "POST", "path": "chat/completions", "body": body])
            guard result["ok"] as? Bool == true else {
                throw KeyDockError.message("Inference failed: " + (result["message"] as? String ?? result["error"] as? String ?? "unknown"))
            }
            print("PASS live host inference: HTTP \(result["status"] ?? "unknown"), model \(model)")
            print("LIVE HTTP GATEWAY CHECKS PASSED; no vault or log file written")
        } catch { print("FAIL " + APIClient.failureMessage(error)); exit(1) }
    }
}

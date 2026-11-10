import Foundation

enum ImportFileLoader {
    static func load(_ urls: [URL], images: Bool) async throws -> ImportPaste {
        let worker = Task.detached(priority: .userInitiated) { () throws -> ImportPaste in
            try Task.checkCancellation()
            if images {
                guard urls.count <= 6 else { throw KeyDockError.message("一次最多添加 6 张图片。") }
                var paste = ImportPaste()
                for url in urls {
                    try Task.checkCancellation()
                    let image: ImportImage
                    do { image = try ImportImage.fromFile(url) } catch { paste.errors.append(error.localizedDescription); continue }
                    try ImportImage.validate(paste.images + [image]); paste.images.append(image)
                }
                return paste
            }
            guard let url = urls.first, url.isFileURL else { throw KeyDockError.message("请选择本机文本文件。") }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_000_000 else { throw KeyDockError.message("请使用小于 1 MB 的文本文件。") }
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else { throw KeyDockError.message("请使用小于 1 MB 的文本文件。") }
            guard let text = String(data: data, encoding: .utf8) else { throw KeyDockError.message("文本文件不是有效的 UTF-8 编码。") }
            var paste = ImportPaste(text: text); try Task.checkCancellation(); paste.absorbPaths(); try Task.checkCancellation(); return paste
        }
        return try await withTaskCancellationHandler(operation: { let value = try await worker.value; try Task.checkCancellation(); return value }, onCancel: { worker.cancel() })
    }
}

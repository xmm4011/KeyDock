import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CryptoKit

struct ImportImage: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let name: String
    let data: Data
    let mimeType: String
    let fingerprint: Data
    var preview: NSImage? { ImagePreviewCache.image(self, size: 2560) }
    var thumbnail: NSImage? { ImagePreviewCache.image(self, size: 640) }
    private enum CodingKeys: String, CodingKey { case id, name, data }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(restoring: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name), normalizedJPEG: values.decode(Data.self, forKey: .data))
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name); try values.encode(data, forKey: .data)
    }
    init(restoring id: UUID, name: String, normalizedJPEG: Data) throws {
        guard normalizedJPEG.count <= 5 * 1024 * 1024, name.utf8.count <= 2048,
              let source = CGImageSourceCreateWithData(normalizedJPEG as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2560).contains(width), (1...2560).contains(height) else { throw KeyDockError.message("无法恢复图片附件。") }
        self.id = id; self.name = name; data = normalizedJPEG; mimeType = "image/jpeg"; fingerprint = Data(SHA256.hash(data: normalizedJPEG))
    }
    init(data: Data, name: String = "粘贴的图片") throws {
        guard data.count <= 32 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560] as CFDictionary) else {
            throw KeyDockError.message("无法读取图片，或图片过大。请选择小于 32 MB 的普通图片。")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let encoded = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]), encoded.count <= 5 * 1024 * 1024 else { throw KeyDockError.message("图片处理后仍过大，请缩小后添加。") }
        self.id = UUID(); self.name = name; self.data = encoded; self.mimeType = "image/jpeg"; fingerprint = Data(SHA256.hash(data: encoded))
    }
    static func fromFile(_ url: URL) throws -> Self {
        guard url.isFileURL, isImagePath(url.path) else { throw KeyDockError.message("请选择图片文件。") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32 * 1024 * 1024 else { throw KeyDockError.message("单张原图不能超过 32 MB。") }
        return try Self(data: Data(contentsOf: url), name: url.lastPathComponent)
    }
    static func isImagePath(_ path: String) -> Bool { ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    static func validate(_ images: [Self]) throws {
        guard images.count <= 6, images.reduce(0, { $0 + $1.data.count }) <= 10 * 1024 * 1024 else { throw KeyDockError.message("一次最多添加 6 张图片，处理后总大小不能超过 10 MB。") }
    }
    static func recognizedText(in images: [Self]) async throws -> String {
        guard !images.isEmpty else { return "" }
        let task = Task.detached(priority: .userInitiated) {
            var texts: [String] = []
            for (index, image) in images.enumerated() {
                try Task.checkCancellation()
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
                if (try? VNImageRequestHandler(data: image.data).perform([request])) != nil {
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    texts.append("图片 \(index + 1)：\n" + text)
                }
            }
            return texts.joined(separator: "\n\n")
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

enum ImagePreviewCache {
    private static let cache: NSCache<NSString, CGImage> = { let value = NSCache<NSString, CGImage>(); value.countLimit = 48; value.totalCostLimit = 64 * 1024 * 1024; return value }()
    static func image(_ image: ImportImage, size: Int) -> NSImage? {
        let key = (image.fingerprint.base64EncodedString() + ":" + String(size)) as NSString
        let pixels: CGImage
        if let value = cache.object(forKey: key) { pixels = value }
        else {
            guard let source = CGImageSourceCreateWithData(image.data as CFData, nil), let value = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else { return nil }
            pixels = value; cache.setObject(value, forKey: key, cost: value.bytesPerRow * value.height)
        }
        // Views and attachment cells may resize their own wrapper. Never share
        // a mutable NSImage between a thumbnail and the full-size preview.
        return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
    }
}

struct ImportPaste {
    var text = ""
    var images: [ImportImage] = []
    var errors: [String] = []
    static func from(_ board: NSPasteboard) -> Self {
        var result = Self(text: board.string(forType: .string) ?? "")
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter { ImportImage.isImagePath($0.path) }
        for file in files { do { result.images.append(try .fromFile(file)) } catch { result.errors.append(error.localizedDescription) } }
        if files.isEmpty {
            let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic"), .init("org.webmproject.webp")]
            for item in board.pasteboardItems ?? [] {
                guard let bytes = types.compactMap({ item.data(forType: $0) }).first else { continue }
                do {
                    let image = try ImportImage(data: bytes)
                    if !result.images.contains(where: { $0.fingerprint == image.fingerprint }) { result.images.append(image) }
                } catch { result.errors.append(error.localizedDescription) }
            }
        }
        result.absorbPaths()
        return result
    }
    mutating func absorbPaths() {
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let url = value.hasPrefix("file://") ? URL(string: value) : (value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil)
            if let url, url.isFileURL, ImportImage.isImagePath(url.path) {
                guard images.count < 6 else { kept.append(line); errors.append("一次最多添加 6 张图片；超出部分未读取。"); continue }
                do {
                    let image = try ImportImage.fromFile(url)
                    if !images.contains(where: { $0.fingerprint == image.fingerprint }) { try ImportImage.validate(images + [image]); images.append(image) }
                } catch { kept.append(line); errors.append("有图片路径无法读取，请重新粘贴图片或点击“添加图片”。") }
            } else { kept.append(line) }
        }
        text = kept.joined(separator: "\n")
    }
}

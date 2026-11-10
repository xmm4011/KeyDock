import SwiftUI

struct CredentialSourceView: View {
    @EnvironmentObject var store: VaultStore
    let record: Credential
    @State private var preview: ImportImage?
    var body: some View {
        let raw = record.source.isEmpty ? record.curl : record.source
        return VStack(alignment: .leading, spacing: 16) {
            if raw.utf8.count > 16384 {
                PreparedCodePanel(contents: [.source(raw)], policy: store.logDisplayPolicy, onCopy: { store.copy($0, sensitive: true) })
            } else { CodePanel(text: raw.isEmpty ? "此条记录为手动创建，没有导入原文。" : (store.showFullContent ? raw : store.displayText(RedactedImport(raw).text))) }
            if let images = record.sourceImages, !images.isEmpty {
                Text("原始图片 · 双击放大").font(.system(size: 11)).foregroundStyle(Palette.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(images) { image in
                        if let preview = image.thumbnail {
                            Image(nsImage: preview).resizable().scaledToFit().frame(height: 110)
                                .frame(maxWidth: .infinity).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle()).onTapGesture(count: 2) { self.preview = image }
                                .accessibilityLabel("原始图片：" + image.name)
                        }
                    }
                }
            } else if raw.contains("[图片 ") || raw.contains("[图片文字索引") {
                Text("此旧记录只保存了图片标记或识别文字，没有保留原图。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.sheet(item: $preview) { ImportImagePreview(image: $0) }
    }
}

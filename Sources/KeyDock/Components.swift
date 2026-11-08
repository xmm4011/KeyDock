import SwiftUI

struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            if configuration.isExpanded { configuration.content.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 4) }
        }
    }
}

enum Palette {
    static let accent = Color(red: 0.32, green: 0.31, blue: 0.82)
    static let ink = Color(red: 0.12, green: 0.15, blue: 0.23)
    static let muted = Color(red: 0.48, green: 0.51, blue: 0.59)
    static let canvas = Color(red: 0.965, green: 0.969, blue: 0.985)
    static let border = Color(red: 0.89, green: 0.91, blue: 0.95)
    static let teal = Color(red: 0.08, green: 0.58, blue: 0.48)
}

enum Layout {
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 20
    static let contentWidth: CGFloat = 720
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(Layout.cardPadding)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border.opacity(0.7)))
    }
}

struct ProviderIcon: View {
    let record: Credential
    var size: CGFloat = 40
    var color: Color {
        if record.provider.lowercased().contains("deepseek") { return Color(red: 0.25, green: 0.42, blue: 0.93) }
        if record.kind == .anthropic { return Color(red: 0.76, green: 0.45, blue: 0.31) }
        if record.kind == .gemini { return Color(red: 0.36, green: 0.42, blue: 0.82) }
        return record.kind == .custom ? Palette.teal : Palette.accent
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27).fill(color.opacity(0.11))
            if record.provider.isEmpty { Image(systemName: record.kind.symbol).font(.system(size: size * 0.44, weight: .semibold)) }
            else { Text(String(record.provider.prefix(1))).font(.system(size: size * 0.49, weight: .bold, design: .rounded)) }
        }.foregroundStyle(color).frame(width: size, height: size)
    }
}

struct StatusBadge: View {
    let record: Credential
    var color: Color {
        if record.archived { return Palette.muted }
        if record.expired { return .orange }
        switch record.check?.state ?? .unchecked {
        case .valid: return Palette.teal
        case .invalid: return .red
        case .restricted, .quota, .uncertain: return .orange
        case .unchecked: return Palette.muted
        }
    }
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(record.stateTitle).font(.system(size: 11, weight: .medium)) }
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.08), in: Capsule())
    }
}

struct CodePanel: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(size: 12, design: .monospaced)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.background(Color(red: 0.955, green: 0.959, blue: 0.98), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.border, lineWidth: 1))
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Pill: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(Palette.accent).padding(.horizontal, 9).padding(.vertical, 5).background(Palette.accent.opacity(0.07), in: Capsule()) }
}

struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    var onCancel: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 23, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).sheetShortcuts(cancel: onCancel) { dismiss() }
    }
}

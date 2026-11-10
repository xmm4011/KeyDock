import SwiftUI

private struct ConversationBottom: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct AgentConversationScroll<Content: View>: View {
    @ObservedObject var activity: AgentActivity
    var revision: String
    var scrollRequest = 0
    @ViewBuilder var content: () -> Content
    @State private var following = true
    @State private var appeared = false
    var body: some View {
        ScrollViewReader { reader in
            GeometryReader { viewport in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(spacing: 0) {
                            content()
                            GeometryReader { geometry in
                                Color.clear.preference(key: ConversationBottom.self, value: geometry.frame(in: .named("agent-conversation")).maxY)
                            }.frame(height: 1).id("conversation-bottom")
                        }
                    }.coordinateSpace(name: "agent-conversation")
                        .onPreferenceChange(ConversationBottom.self) { bottom in
                            if appeared { following = bottom <= viewport.size.height + 28 }
                        }
                        .onAppear {
                            RunLoop.main.perform(inModes: [.common]) {
                                MainActor.assumeIsolated { reader.scrollTo("conversation-bottom", anchor: .bottom); appeared = true }
                            }
                        }
                        .onChange(of: revision) { _, _ in if following { reader.scrollTo("conversation-bottom", anchor: .bottom) } }
                        .onChange(of: activity.record.updatedAt) { _, _ in if following { reader.scrollTo("conversation-bottom", anchor: .bottom) } }
                        .onChange(of: scrollRequest) { _, _ in following = true; reader.scrollTo("conversation-bottom", anchor: .bottom) }
                    if !following {
                        Button("回到最新消息", systemImage: "arrow.down") { following = true; reader.scrollTo("conversation-bottom", anchor: .bottom) }
                            .controlSize(.small).buttonStyle(.bordered).padding(12)
                    }
                }
            }
        }
    }
}

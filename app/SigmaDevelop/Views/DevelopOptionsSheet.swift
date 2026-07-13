import SwiftUI

struct DevelopOptionsSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var entryKey: DevelopSettings.GlobalKey?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 4) {
            DevelopHeaderBar(onDone: { dismiss() })
            ScrollView {
                DevelopDefaultsForm(settings: $store.defaults)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        .onAppear { entryKey = store.defaults.globalKey }
        .onDisappear {
            if store.defaults.globalKey != entryKey { store.applyGlobalDefaults() }
        }
        .presentationBackground(SigmaTheme.paper)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #elseif os(macOS)
        .frame(minWidth: 380, minHeight: 520)
        #endif
    }
}

import SwiftUI

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.developRailActive) private var developRailActive
    @Environment(\.toggleDevelopRail) private var toggleDevelopRail
    #if os(macOS)
    @Environment(WindowCommands.self) private var menuBar
    @State private var ownsMenuBar = false
    #endif

    @State private var isImporting = false
    @State private var showOptions = false
    @State private var shareItems: [URL] = []
    @State private var isSharing = false
    @State private var isExportingAll = false
    @State private var exportingItemID: UUID?
    @State private var errorText: String?
    #if os(iOS)
    private enum PhonePage: Hashable { case cover, gallery }
    /// Native paging position; the gallery is the initial trailing page.
    @State private var phonePage: PhonePage? = .gallery
    @State private var viewport: CGSize = .zero
    private var showCover: Bool { phonePage == .cover }
    #endif

    /// Phone compact chrome (cover pager + floating import). Wide layouts use the rail.
    private var usesPhoneChrome: Bool {
        #if os(iOS)
        !viewport.prefersDevelopRail
        #else
        false
        #endif
    }

    private let phoneColumns = [
        GridItem(.flexible(minimum: 0), spacing: 0),
        GridItem(.flexible(minimum: 0), spacing: 0),
    ]
    private let wideColumns = [GridItem(.adaptive(minimum: 160), spacing: 0)]

    var body: some View {
        content
            #if os(iOS)
            .sigmaBackground()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(SigmaTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #else
            .navigationTitle("Library")
            #endif
            #if os(iOS)
            .toolbar { libraryToolbar }
            #endif
            .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: ImportTypes.content,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task {
                        await store.importPicked(urls)
                        #if os(iOS)
                        phonePage = .gallery
                        #endif
                    }
                }
            }
            .sheet(isPresented: $showOptions) { DevelopOptionsSheet().environment(store) }
            .exportPresenter(isPresented: $isSharing, items: shareItems) { error in
                errorText = error.localizedDescription
            }
            .alert("Export Failed", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            #if os(macOS)
            .onAppear { ownsMenuBar = true; publishMenuBar() }
            .onDisappear { ownsMenuBar = false }
            .onChange(of: store.items.isEmpty) { publishMenuBar() }
            .onChange(of: store.isImporting) { publishMenuBar() }
            #endif
            #if os(iOS)
            .overlay(alignment: .bottom) {
                if !store.items.isEmpty && usesPhoneChrome {
                    let hidden = showCover || store.isImporting
                    importButton
                        .opacity(hidden ? 0 : 1)
                        .allowsHitTesting(!hidden)
                        .animation(.easeInOut(duration: 0.2), value: hidden)
                }
            }
            #endif
            // Imports stream in live — a passive chip, never a modal lock.
            .overlay(alignment: .bottom) {
                if store.isImporting {
                    ImportProgressChip()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay { if isExporting { progressOverlay } }
    }

    // MARK: - Pages

    @ViewBuilder private var content: some View {
        #if os(macOS)
        if store.items.isEmpty {
            emptyGallery
        } else {
            gallery
        }
        #else
        if store.items.isEmpty {
            LandingView(hasItems: false) { isImporting = true }
        } else if usesPhoneChrome {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    LandingView(hasItems: true) { isImporting = true }
                        .containerRelativeFrame(.horizontal)
                        .id(PhonePage.cover)

                gallery
                        .containerRelativeFrame(.horizontal)
                        .id(PhonePage.gallery)
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $phonePage)
            .defaultScrollAnchor(.trailing)
        } else {
            gallery
        }
        #endif
    }

    #if os(macOS)
    private var emptyGallery: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Import X3F or RAW files to begin.")
        } actions: {
            Button("Import…") { isImporting = true }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.isImporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: usesPhoneChrome ? phoneColumns : wideColumns, spacing: 0) {
                ForEach(store.items) { item in
                    GalleryCell(item: item, isExporting: isExporting) { item, format in
                        Task { await export(item, as: format) }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(iOS)
        .background(SigmaTheme.paper)
        .contentMargins(.top, SigmaTheme.contentTopInset, for: .scrollContent)
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button { isImporting = true } label: {
                Label("Import", systemImage: "plus")
            }
            .disabled(store.isImporting)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggleDevelopRail) {
                // Stable Label identity — do not swap SF Symbol with state.
                Label("Develop", systemImage: "sidebar.trailing")
            }
            .help(developRailActive ? "Hide Develop" : "Show Develop")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { Task { await runExportAll() } } label: {
                    Label("Export All", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(store.items.isEmpty || isExporting)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(store.items.isEmpty || isExporting)
        }
        #else
        if usesPhoneChrome {
            ToolbarItem(placement: .principal) { SigmaWordmark() }
            if !store.items.isEmpty {
                ToolbarItem(placement: .topBarLeading) { coverToggle }
                if !showCover {
                    ToolbarItem(placement: .topBarTrailing) { menu }
                }
            }
        } else if !store.items.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button { isImporting = true } label: {
                    Label("Import", systemImage: "plus")
                }
                .tint(SigmaTheme.ink)
                .disabled(store.isImporting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleDevelopRail) {
                    Label("Develop", systemImage: "sidebar.trailing")
                }
                .tint(SigmaTheme.ink)
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        #endif
    }

    // MARK: - Phone chrome

    #if os(iOS)
    /// Jumps between the cover and the gallery in one tap; the count doubles
    /// as the library badge.
    private var coverToggle: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                phonePage = showCover ? .gallery : .cover
            }
        } label: {
            Text("\(store.items.count)")
                .sigmaLabel(size: 11, color: SigmaTheme.ink, tracking: 1.1)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showCover ? "Show library" : "Show cover")
    }

    private var menu: some View {
        Menu {
            if usesPhoneChrome {
                Button { showOptions = true } label: {
                    Label("Develop Options", systemImage: "slider.horizontal.3")
                }
            }
            Button { Task { await runExportAll() } } label: {
                Label("Export All", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(store.items.isEmpty || isExporting)
        } label: {
            Image(systemName: "ellipsis")
        }
        .tint(SigmaTheme.ink)
    }

    private var importButton: some View {
        Button { isImporting = true } label: {
            Label("Import", systemImage: "plus")
                .font(.body.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(SigmaTheme.ink)
        .disabled(store.isImporting)
        .padding(.bottom, 12)
    }
    #endif

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            ProgressCard(verb: "Developing")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private var isExporting: Bool { isExportingAll || exportingItemID != nil }

    #if os(macOS)
    /// The arriving screen owns the whole menu bar (see `WindowCommands`).
    private func publishMenuBar() {
        guard ownsMenuBar else { return }
        menuBar.backAction = nil
        menuBar.exportActions = store.items.isEmpty ? [] : [
            MenuCommand(
                id: "exportAll",
                title: "Export All",
                shortcut: KeyboardShortcut("e", modifiers: [.command, .shift])
            ) {
                Task { await runExportAll() }
            }
        ]
    }
    #endif

    // MARK: - Export

    private func runExportAll() async {
        guard !isExporting else { return }
        isExportingAll = true
        defer { isExportingAll = false }
        do {
            shareItems = try await store.exportAll()
            isSharing = !shareItems.isEmpty
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func export(_ item: LibraryItem, as format: ExportFormat) async {
        guard !isExporting else { return }
        exportingItemID = item.id
        defer { exportingItemID = nil }
        do {
            shareItems = [try await store.export(item, settings: item.settings, as: format)]
            isSharing = true
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Progress

/// Read per-file progress counts in their own body; each tick re-evaluates alone.
private struct ProgressCard: View {
    @Environment(LibraryStore.self) private var store
    let verb: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .sigmaText(.subheadline)
                .monospacedDigit()
        }
        .padding(28)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var title: String {
        guard let progress = store.exportProgress else { return verb }
        return "\(verb) \(progress.done) of \(progress.total)"
    }
}

/// Passive import progress; the grid stays scrollable and tappable while
/// copies land and thumbnails stream in behind it.
private struct ImportProgressChip: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .sigmaText(.subheadline)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
        .padding(.bottom, 12)
    }

    private var title: String {
        guard let progress = store.importProgress else { return "Importing" }
        return "Importing \(progress.done) of \(progress.total)"
    }
}

// MARK: - Gallery cell

/// One grid cell. Reading `store.thumbnails` here scopes redraws to visible cells.
private struct GalleryCell: View {
    @Environment(LibraryStore.self) private var store
    let item: LibraryItem
    let isExporting: Bool
    let onExport: (LibraryItem, ExportFormat) -> Void

    private struct ThumbnailTaskKey: Equatable {
        var missing: Bool
        var importing: Bool
    }

    var body: some View {
        NavigationLink(value: item) {
            LibraryCard(item: item, thumbnail: store.thumbnails[item.id])
        }
        .buttonStyle(.plain)
        .task(id: ThumbnailTaskKey(
            missing: store.thumbnails[item.id] == nil,
            importing: store.isImporting
        )) {
            store.ensureThumbnail(item)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(SigmaTheme.hairline).frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(SigmaTheme.hairline).frame(height: 1)
        }
        .contextMenu {
            Button { store.rotate(item, quarterTurns: 1) } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            Button { store.rotate(item, quarterTurns: -1) } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }

            Divider()

            ForEach(item.availableFormats) { format in
                Button { onExport(item, format) } label: {
                    Label("Export \(format.label)", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
            }

            Divider()

            Button(role: .destructive) { store.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(store.isBeingEdited(item.id))
        } preview: {
            if let thumb = store.thumbnails[item.id] {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 320)
            }
        }
    }
}

// MARK: - Landing (iPhone cover / empty)

#if os(iOS)
private struct LandingView: View {
    var hasItems: Bool
    var onImport: () -> Void

    var body: some View {
        ZStack {
            SigmaTheme.paper.ignoresSafeArea()
            GeometryReader { proxy in
                VStack(spacing: 22) {
                    SigmaMark(size: 70)
                    VStack(spacing: 6) {
                        Text("Developer")
                            .sigmaText(.title, weight: .regular)
                            .foregroundStyle(SigmaTheme.ink)
                        Text("X3F / RAW")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(1.4)
                            .foregroundStyle(SigmaTheme.secondary)
                    }
                    Button(action: onImport) {
                        Text(hasItems ? "+ Import" : "Import")
                            .font(.system(size: 12, weight: .medium))
                            .textCase(.uppercase)
                            .foregroundStyle(SigmaTheme.ink)
                            .padding(.vertical, 13)
                            .padding(.horizontal, 30)
                            .background(SigmaTheme.surface)
                            .overlay(Rectangle().stroke(SigmaTheme.ink, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(40)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}
#endif

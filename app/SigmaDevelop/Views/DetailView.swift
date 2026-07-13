import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DetailView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DevelopSession.self) private var session
    @Environment(\.developRailActive) private var developRailActive
    @Environment(\.toggleDevelopRail) private var toggleDevelopRail
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(WindowCommands.self) private var menuBar
    #endif
    let item: LibraryItem

    @State private var preview: CGImage?
    @State private var previewIsHDR = false
    /// Long edge of the base preview in device pixels; 0 until first layout.
    @State private var previewLongEdge = 0
    @State private var isExporting = false
    @State private var isRendering = false
    @State private var errorTitle = "Render Failed"
    @State private var errorText: String?
    @State private var shareItems: [URL] = []
    @State private var isSharing = false
    @State private var activationGeneration = 0
    /// Until a render says otherwise, assume native res — never tile blindly.
    @State private var previewIsNativeRes = true
    @State private var isTileRendering = false
    @State private var zoomTile: ZoomTile?
    @State private var tileTask: Task<Void, Never>?
    #if os(iOS)
    @State private var trayDetent: TrayDetent = .collapsed
    @State private var trayHeaderHeight: CGFloat = 53
    @State private var viewport: CGSize = .zero
    #endif

    /// Immersive landscape (phone).
    private var isLandscape: Bool {
        #if os(iOS)
        vSizeClass == .compact
        #else
        false
        #endif
    }

    /// Phone tray when the persistent rail is not hosting develop controls.
    private var usesPhoneTray: Bool {
        #if os(iOS)
        !viewport.prefersDevelopRail
        #else
        false
        #endif
    }

    private var settings: DevelopSettings {
        session.activeItemID == item.id ? session.settings : item.settings
    }

    var body: some View {
        stage
            #if os(iOS)
            .background(SigmaTheme.paper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isLandscape && usesPhoneTray ? .hidden : .automatic, for: .navigationBar)
            .toolbarBackground(SigmaTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .statusBarHidden(isLandscape && usesPhoneTray)
            .persistentSystemOverlays(isLandscape && usesPhoneTray ? .hidden : .automatic)
            #else
            .navigationTitle(item.fileName)
            .onAppear { publishMenuBar() }
            #endif
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                #if os(iOS)
                viewport = size
                #endif
                let target = PreviewPixels.target(size, scale: displayScale)
                if target > previewLongEdge { previewLongEdge = target }
            }
            #if os(iOS)
            .toolbar { editorToolbar }
            #endif
            .exportPresenter(isPresented: $isSharing, items: shareItems) { error in
                errorTitle = "Save Failed"
                errorText = error.localizedDescription
            }
            .alert(errorTitle, isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .task(id: renderTaskKey) {
                #if DEBUG
                print("SIGMA DetailView task: \(item.fileName)")
                #endif
                // Attach here, not in onAppear: the task body can run first on
                // macOS, and a failed guard would leave the editor stuck on the
                // blurred placeholder until an edit changed the task id.
                if session.activeItemID != item.id {
                    guard store.beginEditing(item.id) else {
                        errorTitle = "Already Open"
                        errorText = "This photo is already being edited in another window."
                        dismiss()
                        return
                    }
                    session.attach(item)
                }
                await renderPreview()
            }
            // Renders that raced backgrounding come back black (no GPU off
            // foreground); repaint — tiles re-request off the fresh image.
            // iOS-only: macOS keeps the GPU across app switches, and reacting
            // here would re-render on every activation.
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                if phase == .active { activationGeneration &+= 1 }
                #endif
            }
            #if os(iOS)
            .onAppear { OrientationLock.allowsRotation = true }
            #endif
            .onDisappear {
                cancelTileTask()
                #if os(iOS)
                OrientationLock.allowsRotation = false
                #endif
                guard session.activeItemID == item.id else { return }
                let final = session.settings
                if final != item.settings {
                    if let preview {
                        store.adoptThumbnail(from: preview, for: item.id)
                    } else {
                        store.refreshThumbnail(item.id)
                    }
                    store.updateSettings(final, for: item)
                }
                session.detach(item.id)
                store.endEditing(item.id)
                session.engine.releaseTransient()
            }
    }

    /// Equatable value, not an interpolated string: this is recomputed on every
    /// body evaluation of the editor, and reflection-based interpolation of the
    /// render key was measurable churn on the slider-drag hot path.
    private struct RenderTaskKey: Equatable {
        var itemID: UUID
        var render: DevelopSettings.RenderKey
        var longEdge: Int
        var activation: Int
    }

    private var renderTaskKey: RenderTaskKey {
        RenderTaskKey(itemID: item.id, render: settings.renderKey,
                  longEdge: previewLongEdge, activation: activationGeneration)
    }

    // MARK: - Stage

    @ViewBuilder private var stage: some View {
        #if os(iOS)
        if usesPhoneTray {
            phoneStack
        } else {
            imageStage
        }
        #else
        imageStage
        #endif
    }

    private var imageStage: some View {
        ZStack {
            if let preview {
                // Tiles engage only when the base preview undersells the file's
                // native grid — resolution-driven, so it holds for RAW and X3F
                // alike. Film sim tiles too: grain is seeded deterministically
                // on the full-res pixel grid, so tiles agree with the base.
                ZoomableImage(
                    image: preview,
                    isHDR: previewIsHDR,
                    tile: zoomTile,
                    insetH: SigmaTheme.stageInsetH,
                    insetV: SigmaTheme.stageInsetV,
                    onTileNeeded: previewIsNativeRes ? nil : handleTileRequest,
                    onBackSwipe: {
                        #if os(macOS)
                        dismiss()
                        #endif
                    }
                )
            } else if let thumb = store.thumbnails[item.id] {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, SigmaTheme.stageInsetH)
                    .padding(.vertical, SigmaTheme.stageInsetV)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 8)
                    .opacity(0.5)
            }

            busyIndicator
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(SigmaTheme.surface)
        #endif
        .clipped()
        .padding(.top, (isLandscape || !usesPhoneTray) ? 0 : SigmaTheme.contentTopInset)
        #if os(iOS)
        .contextMenu {
            rotateActions
            Divider()
            exportActions
        } preview: {
            liftPreview
        }
        #else
        .contextMenu {
            rotateActions
            Divider()
            exportActions
        }
        #endif
    }

    /// Always in the hierarchy — inserting/removing an indicator mid-edit reads
    /// as the stage popping (user-rejected, twice).
    @ViewBuilder private var busyIndicator: some View {
        #if os(iOS)
        ActivitySpinner(animating: isBusy)
        #else
        ProgressView()
            .controlSize(.large)
            // White spokes + shadow so it reads over any photo, like iOS.
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .opacity(isBusy ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isBusy)
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggleDevelopRail) {
                // Stable label identity — swapping SF Symbol with state thrashs the toolbar.
                Label("Develop", systemImage: "sidebar.trailing")
            }
            .help(developRailActive ? "Hide Develop" : "Show Develop")
        }
        ToolbarItem(placement: .primaryAction) { exportMenu }
        #else
        if usesPhoneTray {
            ToolbarItem(placement: .principal) { SigmaWordmark(height: 15) }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleDevelopRail) {
                    Label("Develop", systemImage: "sidebar.trailing")
                }
                .tint(SigmaTheme.ink)
            }
        }
        ToolbarItem(placement: .topBarTrailing) { exportMenu }
        #endif
    }

    // MARK: - Tray (phone)

    #if os(iOS)
    private enum TrayDetent: Int, CaseIterable {
        case hidden, collapsed, expanded
    }

    private var phoneStack: some View {
        GeometryReader { proxy in
            let bottomInset = isLandscape ? 0 : proxy.safeAreaInsets.bottom
            let trayH = trayHeight(total: proxy.size.height, bottomInset: bottomInset)
            VStack(spacing: 0) {
                imageStage
                    .frame(height: isLandscape ? nil : max(proxy.size.height + bottomInset - trayH, 0))

                if !isLandscape {
                    tray(bottomInset: bottomInset)
                        .frame(height: trayH, alignment: .top)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: isLandscape ? .all : .bottom)
        }
    }

    private var trayHeader: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(SigmaTheme.ink.opacity(0.85))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
            DevelopHeaderBar(onReset: {
                session.settings = .init()
            })
        }
        .contentShape(Rectangle())
        .gesture(trayDrag)
    }

    // Detents switch on release: live tracking would resize the stage per frame
    // (fighting the zoom re-base) and move the header under the finger.
    private var trayDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let projected = value.predictedEndTranslation.height
                guard abs(projected) > 40 else { return }
                let step = projected < 0 ? 1 : -1
                let next = TrayDetent(rawValue: trayDetent.rawValue + step) ?? trayDetent
                withAnimation(SigmaTheme.panelSpring) { trayDetent = next }
            }
    }

    private func tray(bottomInset: CGFloat) -> some View {
        @Bindable var session = session
        return VStack(spacing: 12) {
            trayHeader
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trayHeaderHeight = $0 }
                .padding(.bottom, trayDetent == .hidden ? bottomInset : 0)
            ScrollView {
                DevelopControls(
                    settings: $session.settings,
                    isX3F: item.isX3F,
                    autoExposureEV: session.autoExposureEV,
                    lensCorrectionAvailable: session.lensProfileAvailable
                )
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.never)
            .scrollEdgeEffectHidden(true, for: .all)
            .contentMargins(.bottom, bottomInset + 8, for: .scrollContent)
            .accessibilityHidden(trayDetent == .hidden)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        .background(SigmaTheme.paper)
        .overlay(alignment: .top) {
            Divider().overlay(SigmaTheme.hairline)
        }
    }

    private func trayHeight(total: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let collapsed = min(max(total * 0.55, 340), 560)
        let visible: CGFloat = switch trayDetent {
        case .hidden: trayHeaderHeight + 8
        case .collapsed: collapsed
        case .expanded: max(collapsed, total * 0.9)
        }
        return visible + bottomInset
    }

    /// The lift platter hugs the photo — no mat, no letterboxing.
    @ViewBuilder private var liftPreview: some View {
        if let image = preview ?? store.thumbnails[item.id] {
            let h = (320 * CGFloat(image.height) / CGFloat(max(image.width, 1))).rounded()
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: 320, height: h)
        }
    }

    #endif

    // MARK: - Actions

    @ViewBuilder private var rotateActions: some View {
        Button { rotate(by: 1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
        Button { rotate(by: -1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
    }

    private func rotate(by turns: Int) {
        session.settings.rotate(by: turns)
    }

    private var exportMenu: some View {
        Menu {
            exportActions
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(isExporting)
        #if os(iOS)
        .tint(SigmaTheme.ink)
        #endif
    }

    @ViewBuilder private var exportActions: some View {
        ForEach(item.availableFormats) { format in
            Button { Task { await exportAndShare(format) } } label: {
                Label("Export \(format.label)", systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting)
        }
    }

    #if os(macOS)
    /// The arriving screen owns the whole menu bar (see `WindowCommands`).
    private func publishMenuBar() {
        menuBar.backAction = { dismiss() }
        menuBar.exportActions = item.availableFormats.enumerated().map { index, format in
            MenuCommand(
                id: "export-\(format.id)",
                title: "Export \(format.label)",
                shortcut: index == 0 ? KeyboardShortcut("e", modifiers: .command) : nil
            ) {
                Task { await exportAndShare(format) }
            }
        }
    }
    #endif

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private var isBusy: Bool {
        isRendering || isExporting || isTileRendering
    }

    // MARK: - Rendering

    private func renderPreview() async {
        guard session.activeItemID == item.id else { return }
        // 0 = layout hasn't run yet; the first geometry pass bumps the task id
        // and re-enters here with a real pixel budget.
        let maxDimension = previewLongEdge
        guard maxDimension > 0 else { return }
        let current = session.settings
        if !current.hdr { previewIsHDR = false }
        let taskKey = renderTaskKey
        isRendering = true
        // An in-flight tile was rendered for the previous settings.
        cancelTileTask()
        defer {
            // Full task key, not just the render key: a pixel-budget bump
            // restarts this task with identical settings, and the cancelled
            // run must not clear the flag out from under its successor.
            if renderTaskKey == taskKey { isRendering = false }
        }
        do {
            // X3F first paint comes from the cached proxy decode.
            for try await rendered in session.engine.previewUpdates(
                url: item.url, settings: current, maxDimension: maxDimension
            ) {
                guard !Task.isCancelled, session.activeItemID == item.id else { return }
                preview = rendered.cgImage
                previewIsHDR = rendered.isHDR
                session.autoExposureEV = rendered.autoExposureEV
                if item.isX3F { session.lensProfileAvailable = rendered.lensProfileAvailable }
                previewIsNativeRes = rendered.isAtNativeSize
                // Stale for the new pixels; the zoom view re-requests as needed.
                if zoomTile != nil { zoomTile = nil }
                errorText = nil
            }
        } catch {
            if !Task.isCancelled {
                errorTitle = "Render Failed"
                errorText = error.localizedDescription
            }
        }
    }

    /// Deep-zoom tile flow.
    private func handleTileRequest(_ request: ZoomTileRequest?) {
        guard let request else {
            cancelTileTask()
            if zoomTile != nil { zoomTile = nil }
            return
        }
        // A capped tile re-emits its own request on settle; it's already applied.
        guard zoomTile?.request != request else { return }
        // Never race an in-flight preview render; the fresh image re-emits the
        // request once it lands.
        guard !isRendering else { return }
        tileTask?.cancel()
        tileTask = Task {
            isTileRendering = true
            // A superseding task owns the flag from the moment it cancels this
            // one; only a task that ran to completion may clear it.
            defer { if !Task.isCancelled { isTileRendering = false } }
            guard session.activeItemID == item.id,
                  let (rendered, actual) = try? await session.engine.regionPreview(
                    url: item.url, settings: session.settings,
                    region: request.region, maxDimension: request.longEdge),
                  !Task.isCancelled else { return }
            zoomTile = ZoomTile(
                image: rendered.cgImage,
                region: actual,
                isHDR: rendered.isHDR,
                request: request
            )
        }
    }

    private func cancelTileTask() {
        tileTask?.cancel()
        tileTask = nil
        session.engine.cancelTiles()
        isTileRendering = false
    }

    private func exportAndShare(_ format: ExportFormat) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await store.export(item, settings: session.settings, as: format)
            shareItems = [url]
            isSharing = true
        } catch {
            errorTitle = "Export Failed"
            errorText = error.localizedDescription
        }
    }
}

/// Pixel budget for the base preview: the stage's long edge in device pixels
/// (points × native scale). On desktop Retina panels (218 ppi class, 2×) that
/// is exactly pixel-perfect; iPhone/iPad native scale is denser still and is
/// the correct ceiling there — 218 ppi equivalent would under-resolve the
/// panel, and deep-zoom tiles cover everything past 1:1. Quantised up in
/// coarse steps and grown monotonically per visit so window resizes and tray
/// detents never thrash full re-renders; the engine still caps at the file's
/// native size.
private enum PreviewPixels {
    /// Coarse enough that live window resizes cross a boundary rarely; fine
    /// enough that the overshoot past true device pixels stays under 10%.
    static let step: CGFloat = 256
    /// Small windows still render enough for the adopted thumbnail and the
    /// context-menu platter to stay sharp.
    static let floor: CGFloat = 1280

    static func target(_ stage: CGSize, scale: CGFloat) -> Int {
        let longEdge = max(stage.width, stage.height) * max(scale, 1)
        guard longEdge > 0 else { return 0 }
        return Int(max((longEdge / step).rounded(.up) * step, floor))
    }
}

#if os(iOS)
/// Classic springboard spinner :D
private struct ActivitySpinner: UIViewRepresentable {
    var animating: Bool

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.hidesWhenStopped = true
        spinner.color = .white
        spinner.layer.shadowColor = UIColor.black.cgColor
        spinner.layer.shadowOpacity = 0.4
        spinner.layer.shadowRadius = 2
        spinner.layer.shadowOffset = .zero
        return spinner
    }

    func updateUIView(_ spinner: UIActivityIndicatorView, context: Context) {
        if animating, !spinner.isAnimating {
            spinner.startAnimating()
        } else if !animating, spinner.isAnimating {
            spinner.stopAnimating()
        }
    }
}
#endif

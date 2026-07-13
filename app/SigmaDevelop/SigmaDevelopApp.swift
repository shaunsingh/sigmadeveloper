import SwiftUI
import SigmaFoveon

#if os(iOS)
import UIKit

/// Constrain view rotation (iPhone portrait library; free in the editor).
@MainActor
enum OrientationLock {
    static var allowsRotation = false {
        didSet {
            guard allowsRotation != oldValue else { return }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      windowScene.traitCollection.userInterfaceIdiom == .phone else { continue }
                windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                if !allowsRotation {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
            }
        }
    }
}

final class SigmaDevelopAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard window?.traitCollection.userInterfaceIdiom == .phone else { return .all }
        return OrientationLock.allowsRotation ? .all : .portrait
    }
}
#endif

/// Live develop state for the focused editor, shared with the persistent
/// develop rail (macOS / wide iPad) and the macOS menu bar. Keeping settings
/// here instead of only inside `DetailView` lets the panel survive navigation
/// transitions without remounting.
@MainActor
@Observable
final class DevelopSession {
    private(set) var activeItemID: UUID?
    var settings = DevelopSettings()
    var isX3F = true
    var autoExposureEV: Float?
    var lensProfileAvailable = true
    /// Interactive work is isolated per window. Thumbnail and export work can
    /// remain shared by the library without cancelling another window's edits.
    let engine = RenderEngine()

    var isEditing: Bool { activeItemID != nil }

    func attach(_ item: LibraryItem) {
        activeItemID = item.id
        settings = item.settings
        settings.repairInvariants(isX3F: item.isX3F)
        isX3F = item.isX3F
        autoExposureEV = nil
        lensProfileAvailable = true
    }

    func detach(_ id: UUID) {
        guard activeItemID == id else { return }
        activeItemID = nil
        autoExposureEV = nil
        lensProfileAvailable = true
    }

    func setHDREnabled(_ enabled: Bool) {
        settings.setHDREnabled(enabled)
    }

    func selectFilm(_ index: Int) {
        settings.selectFilm(index)
    }
}

@main
struct SigmaDevelopApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(SigmaDevelopAppDelegate.self) private var appDelegate
    #endif
    @State private var store = LibraryStore()
    @State private var autoOpened: LibraryItem?

    var body: some Scene {
        WindowGroup {
            AppRoot(autoOpened: autoOpened)
                .environment(store)
                .preferredColorScheme(.light)
                .task { await autoDrive() }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { SigmaCommands() }
        #endif
    }

    /// Headless-verification hook (debug builds only): `SIGMA_AUTO_IMPORT=<dir>`
    /// imports a folder on launch and `SIGMA_AUTO_OPEN=1` opens the first item,
    /// so headless runs can exercise the full pipeline without a file picker.
    /// The editor is mounted as the stack root instead of pushed: headless
    /// simulators never tick the push animation to completion, wedging the
    /// stack mid-transition with the destination mounted but never presented.
    /// Once per process: a scene reconnect recreates the content view and would
    /// rerun the task, double-importing.
    @MainActor private static var didAutoDrive = false

    private func autoDrive() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SIGMA_AUTO_IMPORT"], !Self.didAutoDrive else { return }
        Self.didAutoDrive = true
        await store.importPicked([URL(fileURLWithPath: dir)])
        if env["SIGMA_AUTO_OPEN"] == "1", let first = store.items.first {
            autoOpened = first
            print("SIGMA autoDrive: opened \(first.fileName) as root")
        }
        #endif
    }
}

// MARK: - Root chrome

/// Hosts `NavigationStack` with the develop panel alongside.
///
/// The panel lives *outside* navigation destinations so push/pop only animates
/// the stage. One owned rail on every platform: macOS and wide iOS layouts
/// host the same fixed trailing column; compact phones fall back to the
/// in-editor tray. (macOS deliberately does NOT use `.inspector` — presenting
/// it split the unified toolbar, overlapped it in fullscreen, and snapped
/// mid-animation. The plain column below the window toolbar is stable and
/// matches the Photos info-panel shape.)
private struct AppRoot: View {
    var autoOpened: LibraryItem?
    @Environment(LibraryStore.self) private var store
    // Per-window, not app-level: on macOS every window needs its own
    // navigation stack and its own focused-editor session, or a second
    // window (⌘N) would navigate and edit in lockstep with the first.
    @State private var path = NavigationPath()
    @State private var session = DevelopSession()
    @State private var showDevelop = true
    @State private var defaultsDidLoad = false

    #if os(iOS)
    @State private var viewport: CGSize = .zero
    private var railAvailable: Bool { viewport.prefersDevelopRail }
    #else
    @State private var menuBar = WindowCommands()
    @State private var isImporting = false
    private var railAvailable: Bool { true }
    #endif

    private var railPresented: Bool { railAvailable && showDevelop }

    var body: some View {
        HStack(spacing: 0) {
            navigationCore
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if railPresented {
                #if os(iOS)
                DevelopColumnDivider()
                #endif
                DevelopRail()
                    .frame(width: SigmaTheme.developSidebarWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(SigmaTheme.panelSpring, value: showDevelop)
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        // Stable object identities, published once — menu updates flow
        // through Observation, never through focused-value republish.
        .focusedSceneValue(\.windowCommands, menuBar)
        .focusedSceneValue(\.developSession, session)
        .focusedSceneValue(\.toggleDevelopRail, toggleRail)
        .environment(menuBar)
        #else
        .background(SigmaTheme.paper.ignoresSafeArea())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .onChange(of: railAvailable) { _, available in
            // Opening a wide window reveals the rail; shrinking hides it without fighting the user.
            if available, !store.items.isEmpty {
                withAnimation(SigmaTheme.panelSpring) { showDevelop = true }
            }
        }
        .onChange(of: store.items.count) { old, new in
            guard railAvailable else { return }
            if old == 0, new > 0 {
                withAnimation(SigmaTheme.panelSpring) { showDevelop = true }
            } else if new == 0 {
                withAnimation(SigmaTheme.panelSpring) { showDevelop = false }
            }
        }
        #endif
        .environment(session)
        .environment(\.developRailActive, railPresented)
        .environment(\.toggleDevelopRail, toggleRail)
        #if os(macOS)
        // The window owns one stable native toolbar. Destination-level
        // toolbars caused SwiftUI to tear down and recreate the NSToolbar on
        // every push/pop, temporarily overriding the scene's unified style.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isImporting = true } label: {
                    Label("Import", systemImage: "plus")
                }
                .disabled(store.isImporting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleRail) {
                    Label("Develop", systemImage: "sidebar.trailing")
                }
                .help(railPresented ? "Hide Develop" : "Show Develop")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if menuBar.exportActions.isEmpty {
                        Button("Export") {}.disabled(true)
                    } else {
                        ForEach(menuBar.exportActions) { command in
                            Button(command.title, action: command.action)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(menuBar.exportActions.isEmpty)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: ImportTypes.content,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await store.importPicked(urls) }
            }
        }
        .onAppear {
            menuBar.importAction = { isImporting = true }
        }
        #endif
        // Root-owned so hiding the rail cannot cancel and lose a pending
        // defaults update.
        .task(id: store.defaults.globalKey) {
            guard defaultsDidLoad else { defaultsDidLoad = true; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.applyGlobalDefaults()
        }
    }

    private func toggleRail() {
        guard railAvailable else { return }
        withAnimation(SigmaTheme.panelSpring) { showDevelop.toggle() }
    }

    private var navigationCore: some View {
        NavigationStack(path: $path) {
            if let autoOpened {
                DetailView(item: autoOpened)
            } else {
                LibraryGridView()
            }
        }
    }
}

// MARK: - Menu bar

// The menu bar reads two stable per-window objects — `WindowCommands` and
// `DevelopSession` — published ONCE by `AppRoot` via `focusedSceneValue` and
// mutated in place by the screens. Updates flow through Observation, so a
// slider drag never republishes the focused-value graph. (Republishing fresh
// closure/array identities per render is exactly what watchdog-killed the
// iOS build; nothing here compiles on iOS at all.)
#if os(macOS)
/// One menu-bar entry (export variants).
struct MenuCommand: Identifiable {
    let id: String
    let title: String
    var shortcut: KeyboardShortcut?
    let action: () -> Void

    init(id: String, title: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }
}

/// Menu-bar surface for one window. The screen currently on top owns the
/// fields: each publishes ALL of them on appear and clears nothing on
/// disappear, so push/pop appear-ordering can never race a sibling.
@MainActor @Observable
final class WindowCommands {
    var importAction: (() -> Void)?
    var backAction: (() -> Void)?
    var exportActions: [MenuCommand] = []
}

private struct WindowCommandsKey: FocusedValueKey { typealias Value = WindowCommands }
private struct DevelopSessionKey: FocusedValueKey { typealias Value = DevelopSession }
private struct ToggleDevelopRailKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var windowCommands: WindowCommands? {
        get { self[WindowCommandsKey.self] }
        set { self[WindowCommandsKey.self] = newValue }
    }
    /// The focused window's live develop session, for the Develop menu.
    var developSession: DevelopSession? {
        get { self[DevelopSessionKey.self] }
        set { self[DevelopSessionKey.self] = newValue }
    }
    var toggleDevelopRail: (() -> Void)? {
        get { self[ToggleDevelopRailKey.self] }
        set { self[ToggleDevelopRailKey.self] = newValue }
    }
}

/// Native File / View / Develop menu bar.
struct SigmaCommands: Commands {
    @FocusedValue(\.windowCommands) private var commands
    @FocusedValue(\.developSession) private var session
    @FocusedValue(\.toggleDevelopRail) private var toggleDevelopRail

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") { commands?.importAction?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(commands?.importAction == nil)
            if let exports = commands?.exportActions, !exports.isEmpty {
                Divider()
                ForEach(exports) { commandButton($0) }
            } else {
                Button("Export") {}
                    .disabled(true)
            }
        }

        CommandGroup(after: .sidebar) {
            if toggleDevelopRail != nil || commands?.backAction != nil || session?.isEditing == true {
                Divider()
            }
            if let toggleDevelopRail {
                Button("Toggle Develop Panel", action: toggleDevelopRail)
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
            if let back = commands?.backAction {
                Button("Back to Library", action: back)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            if let session, session.isEditing {
                Button("Rotate Left") { session.settings.rotate(by: -1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Rotate Right") { session.settings.rotate(by: 1) }
                    .keyboardShortcut("]", modifiers: .command)
            }
        }

        CommandMenu("Develop") {
            if let session, session.isEditing {
                developItems(Bindable(session).settings)
            } else {
                Text("No Active Document").disabled(true)
            }
        }
    }

    @ViewBuilder private func developItems(_ settings: Binding<DevelopSettings>) -> some View {
        Picker("White Balance", selection: settings.whiteBalance) {
            ForEach(WhiteBalance.allCases) { Text($0.label).tag($0) }
        }
        Picker("Denoise", selection: settings.denoise) {
            ForEach(DenoiseMode.allCases, id: \.self) { Text($0.menuLabel).tag($0) }
        }
        .disabled(session?.isX3F != true)

        Divider()

        Toggle("HDR / EDR", isOn: Binding(
            get: { settings.wrappedValue.hdr },
            set: { session?.setHDREnabled($0) }
        ))
        Toggle("Auto Exposure", isOn: settings.autoTone)
            .disabled(settings.wrappedValue.hdr)
        Toggle("Monochrome", isOn: settings.monochrome)
        Toggle("Lens Correction", isOn: settings.lensCorrection)
            .disabled(session?.isX3F != true || session?.lensProfileAvailable != true)

        Divider()

        Menu("Film Simulation") {
            Toggle("Enabled", isOn: settings.filmEnabled)
            Divider()
            // Inline sections, not nested submenus: stocks are pickable
            // directly under their header.
            Picker("Stock", selection: Binding(
                get: { settings.wrappedValue.film.film },
                set: { session?.selectFilm($0) }
            )) {
                ForEach(FilmSimData.films) { Text($0.name).tag($0.index) }
            }
            .pickerStyle(.inline)
            Picker("Paper", selection: settings.film.paper) {
                ForEach(FilmSimData.papers) { Text($0.name).tag($0.index) }
            }
            .pickerStyle(.inline)
            Toggle("Scan Negative / Slide", isOn: settings.film.negative)
            Divider()
            Toggle("Halation", isOn: settings.film.halation)
            Toggle("Grain", isOn: settings.film.grain)
        }

        Divider()

        Button("Reset Adjustments") { settings.wrappedValue = DevelopSettings() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    @ViewBuilder private func commandButton(_ command: MenuCommand) -> some View {
        if let shortcut = command.shortcut {
            Button(command.title, action: command.action).keyboardShortcut(shortcut)
        } else {
            Button(command.title, action: command.action)
        }
    }
}

private extension DenoiseMode {
    /// Longer menu-bar labels (the segmented control uses shorter ones).
    var menuLabel: String {
        switch self {
        case .off: "Off"
        case .wavelet: "Profiled"
        case .neural: "Neural"
        }
    }
}
#endif

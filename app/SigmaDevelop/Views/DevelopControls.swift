import SwiftUI
import SigmaFoveon

private let disclosureAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)
private func revealAnimation(forHeight distance: CGFloat) -> Animation {
    .spring(response: min(0.5, 0.3 + distance / 3800), dampingFraction: 0.86)
}

private struct Disclosure<Content: View>: View {
    var shown: Bool
    @ViewBuilder var content: Content

    @State private var measured: CGFloat = 0
    @State private var height: CGFloat?

    init(shown: Bool, @ViewBuilder content: () -> Content) {
        self.shown = shown
        self.content = content()
        _height = State(initialValue: shown ? nil : 0) // adopt initial state, no opening animation
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .fixedSize(horizontal: false, vertical: true)
            // Pin to the proposed width so hidden rows (long stock-menu labels) can't
            // inflate the panel sideways.
            .frame(minWidth: 0, maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
            .frame(height: height, alignment: .top)
            // Clip the *height* only. `.clipped()` also trims the horizontal bounds,
            // shaving the trailing edge of flush controls (Toggle switch, segmented
            // track) — visible on these clipped rows but not the unclipped top-level
            // ones. The over-hanging mask keeps the height clip (an opening menu still
            // can't draw over its neighbours) while leaving the sides untouched.
            .mask(alignment: .top) { Rectangle().padding(.horizontal, -40) }
            // Reveal purely by unmasking height (like a native List/Form insertion).
            // No opacity cross-fade: fading the already-unclipped rows makes them
            // ghost in from the top instead of unrolling solid.
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .onChange(of: shown) { _, nowShown in
                if nowShown {
                    // Unroll 0 → content height, then hand sizing back to the content.
                    withAnimation(revealAnimation(forHeight: measured)) { height = measured } completion: {
                        if shown { height = nil }
                    }
                } else {
                    // A frame can't animate away from `nil`, so pin the live height for
                    // one pass (no visible change — it equals the natural height), then
                    // roll it up to 0.
                    withAnimation(.linear(duration: 0)) { height = measured } completion: {
                        withAnimation(revealAnimation(forHeight: measured)) { height = 0 }
                    }
                }
            }
    }
}

/// Disabled rows dim like native controls
/// Applied per leaf row so nested containers never double-dim
private struct DisabledRowStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.4)
            .animation(disclosureAnimation, value: isEnabled)
    }
}

private extension View {
    func disabledRowStyle() -> some View { modifier(DisabledRowStyle()) }
}

struct DevelopControls: View {
    @Binding var settings: DevelopSettings
    var isX3F: Bool = true
    var autoExposureEV: Float? = nil
    /// A correction profile matched lens via X3F
    var lensCorrectionAvailable: Bool = true

    @State private var hdrEnabledAutoTone = false

    var body: some View {
        VStack(spacing: 0) {
            WhiteBalanceControl(whiteBalance: $settings.whiteBalance)

            Divider()

            DenoiseControl(mode: $settings.denoise,
                           strength: $settings.denoiseStrength,
                           chroma: $settings.denoiseChroma,
                           time: $settings.denoiseTime,
                           supported: isX3F)
                .disabled(!isX3F)

            Divider()

            SettingRow {
                Toggle("HDR/EDR", isOn: hdrBinding)
            }

            Divider()

            SettingRow {
                Toggle("Auto exposure", isOn: $settings.autoTone)
            }
            .disabled(settings.hdr)

            Disclosure(shown: settings.autoTone) {
                Divider()
                AutoExposureModeControl(mode: $settings.autoExposureMode)
            }

            Divider()

            LabeledSlider("Exposure", value: $settings.exposure, in: -3...3, step: 1 / 3,
                          accessory: autoToneAccessory) {
                String(format: "%+.1f EV", $0)
            }

            Disclosure(shown: settings.hdr) {
                Divider()
                LabeledSlider("HDR headroom", value: $settings.hdrEV, in: 0...3, step: 1 / 3) {
                    String(format: "%+.1f EV", $0)
                }
            }

            Divider()

            LabeledSlider("Contrast", value: contrastBinding, in: -0.5...0.5) {
                abs($0) < 0.01 ? "Off" : String(format: "%+.2f", $0)
            }

            Divider()

            LabeledSlider("Sharpness", value: $settings.sharpness, in: 0...2) {
                String(format: "%.2f", $0)
            }

            Divider()

            SettingRow {
                Toggle("Monochrome", isOn: $settings.monochrome)
            }

            Divider()

            FilmControl(enabled: $settings.filmEnabled, film: $settings.film)

            Divider()

            SettingRow {
                Toggle(isOn: $settings.lensCorrection) {
                    Text("Lens correction")
                        .strikethrough(!isX3F || !lensCorrectionAvailable)
                }
            }
            .disabled(!isX3F || !lensCorrectionAvailable)
        }
        .font(.body)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        .onAppear {
            if settings.hdr && !settings.autoTone {
                settings.setHDREnabled(true)
                hdrEnabledAutoTone = true
            }
        }
    }

    private var hdrBinding: Binding<Bool> {
        Binding(
            get: { settings.hdr },
            set: { enabled in
                if enabled {
                    hdrEnabledAutoTone = !settings.autoTone
                    settings.setHDREnabled(true)
                } else if hdrEnabledAutoTone {
                    settings.setHDREnabled(false)
                    settings.autoTone = false
                    hdrEnabledAutoTone = false
                } else {
                    settings.setHDREnabled(false)
                }
            }
        )
    }

    private var autoToneAccessory: Text? {
        guard settings.autoTone, let autoExposureEV else { return nil }
        return Text(String(format: "%+.1f", autoExposureEV))
            .font(.system(.body, design: .serif).italic())
            .monospacedDigit()
    }

    private var contrastBinding: Binding<Float> {
        Binding(
            get: { settings.contrast ?? 0 },
            set: { settings.contrast = abs($0) < 0.01 ? nil : $0 }
        )
    }
}

private struct WhiteBalanceControl: View {
    @Binding var whiteBalance: WhiteBalance

    private enum Mode: Hashable, CaseIterable {
        case asShot, auto, custom
        var label: String {
            switch self {
            case .asShot: "As Shot"
            case .auto: "Auto"
            case .custom: "Custom"
            }
        }
    }

    private var mode: Mode {
        switch whiteBalance {
        case .asShot: .asShot
        case .auto: .auto
        default: .custom
        }
    }

    private var modeSelection: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .asShot: whiteBalance = .asShot
                case .auto: whiteBalance = .auto
                case .custom: if whiteBalance.kelvin == nil { whiteBalance = .sunlight }
                }
            }
        )
    }

    private var rampPosition: Binding<Double> {
        Binding(
            get: { Double(WhiteBalance.temperatureRamp.firstIndex(of: whiteBalance) ?? 0) },
            set: { whiteBalance = WhiteBalance.temperatureRamp[Int($0.rounded())] }
        )
    }

    var body: some View {
        let ramp = WhiteBalance.temperatureRamp
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("White balance")
                    Spacer()
                    Text(valueLabel)
                        .foregroundStyle(.secondary)
                }

                Picker("White balance", selection: modeSelection) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Disclosure(shown: mode == .custom) {
                VStack(spacing: 6) {
                    Slider(value: rampPosition, in: 0...Double(ramp.count - 1), step: 1)
                    HStack {
                        Text(ramp.first?.kelvinLabel ?? "")
                        Spacer()
                        Text(ramp.last?.kelvinLabel ?? "")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                }
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 13)
    }

    private var valueLabel: AttributedString {
        guard let kelvin = whiteBalance.kelvinLabel else { return AttributedString() }
        var name = AttributedString(whiteBalance.label)
        name.font = .system(.body, design: .serif).italic()
        var suffix = AttributedString(" · \(kelvin)")
        suffix.font = .body.monospacedDigit()
        return name + suffix
    }
}

/// Auto-exposure metering
private struct AutoExposureModeControl: View {
    @Binding var mode: AutoExposureMode

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Metering")
                Spacer()
                Text(caption)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.secondary)
            }
            Picker("Metering", selection: $mode) {
                ForEach(AutoExposureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 13)
        .disabledRowStyle()
    }

    private var caption: String {
        switch mode {
        case .ettr: "{ETTR}"
        case .key: "{Key}"
        }
    }
}

private extension AutoExposureMode {
    var label: String {
        switch self {
        case .ettr: "Highlights"
        case .key: "Mid-Grey"
        }
    }
}

/// Denoise mode + per-mode knobs (wavelet: strength/chroma, neural: strength/t)
private struct DenoiseControl: View {
    @Binding var mode: DenoiseMode
    @Binding var strength: Float
    @Binding var chroma: Float
    @Binding var time: Float
    /// Profiled for Foveon only
    var supported = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("Denoise")
                        .strikethrough(!supported)
                    Spacer()
                    Text(caption)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.secondary)
                }
                Picker("Denoise", selection: $mode) {
                    ForEach(DenoiseMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 13)
            .disabledRowStyle()

            Disclosure(shown: mode != .off) {
                Divider()
                LabeledSlider("Strength", value: $strength, in: 0...2) {
                    String(format: "%.2f", $0)
                }
            }
            Disclosure(shown: mode == .wavelet) {
                Divider()
                LabeledSlider("Chroma", value: $chroma, in: 0...4) {
                    String(format: "%.1f×", $0)
                }
            }
            Disclosure(shown: mode == .neural) {
                Divider()
                LabeledSlider("JiT signal level", value: $time, in: 0.05...0.98) {
                    String(format: "t=%.2f", $0)
                }
            }
        }
        // Strength means different things per algorithm; re-baseline on switch.
        .onChange(of: mode) { _, new in
            if new != .off { strength = new.defaultStrength }
        }
    }

    private var caption: String {
        switch mode {
        case .off: ""
        case .wavelet: "{Wavelet}"
        case .neural: "{CoreML}"
        }
    }
}

private extension DenoiseMode {
    /// Short labels so the middle segmented-control cell stays legible
    var label: String {
        switch self {
        case .off: "Off"
        case .wavelet: "Profile"
        case .neural: "Neural"
        }
    }
}

private struct SettingRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabledRowStyle()
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float?
    let accessory: Text?
    let format: (Float) -> String

    init(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>,
         step: Float? = nil, accessory: Text? = nil, format: @escaping (Float) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.accessory = accessory
        self.format = format
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if let accessory {
                    accessory
                        .foregroundStyle(.tertiary)
                        // Lands only after the disclosure rows have settled, and
                        // dips immediately when its setting is switched off.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.32)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                }
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: $value, in: range, step: step)
                    .padding(.horizontal, 14)
            } else {
                Slider(value: $value, in: range)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 13)
        .disabledRowStyle()
    }
}

private struct FilmControl: View {
    @Binding var enabled: Bool
    @Binding var film: FilmSimSettings

    var body: some View {
        VStack(spacing: 0) {
            SettingRow {
                Toggle("Film simulation", isOn: $enabled)
            }

            Disclosure(shown: enabled) {
                Divider()
                StockPicker(title: "Film", selection: filmSelection, stocks: FilmSimData.films)

                Divider()
                StockPicker(title: "Paper", selection: $film.paper, stocks: FilmSimData.papers)
                    .disabled(film.negative)

                Divider()
                SettingRow {
                    Toggle("Scan negative / slide", isOn: $film.negative)
                }

                Divider()
                LabeledSlider("Film exposure", value: $film.evFilm, in: -3...3, step: 1 / 3) {
                    String(format: "%+.1f EV", $0)
                }

                Divider()
                LabeledSlider("Couplers", value: $film.couplers, in: 0...1) {
                    abs($0) < 0.01 ? "Off" : String(format: "%.2f", $0)
                }

                Divider()
                LabeledSlider("Coupler radius", value: $film.couplersRadius, in: 0...0.05) {
                    $0 < 0.001 ? "Off" : String(format: "%.1f%%", $0 * 100)
                }

                Divider()
                SettingRow {
                    Toggle("Halation", isOn: $film.halation)
                }

                Disclosure(shown: film.halation) {
                    Divider()
                    LabeledSlider("Halation glow", value: $film.halationStrength, in: 0...2) {
                        String(format: "%.2f", $0)
                    }

                    Divider()
                    LabeledSlider("Halation radius", value: $film.halationRadius, in: 0.0005...0.006) {
                        String(format: "%.2f%%", $0 * 100)
                    }

                    Divider()
                    LabeledSlider("Halation midtones", value: $film.halationMidtones, in: 0...1) {
                        abs($0) < 0.01 ? "Off" : String(format: "%.2f", $0)
                    }
                }

                Divider()
                SettingRow {
                    Toggle("Grain", isOn: $film.grain)
                }

                Disclosure(shown: film.grain) {
                    Divider()
                    LabeledSlider("Grain size", value: $film.grainSize, in: 0.25...4) {
                        String(format: "%.2f×", $0)
                    }

                    Divider()
                    LabeledSlider("Grain amount", value: $film.grainAmount, in: 0...2) {
                        String(format: "%.2f×", $0)
                    }

                    Divider()
                    LabeledSlider("Grain color", value: $film.grainSaturation, in: 0...1) {
                        abs($0) < 0.01 ? "Mono" : String(format: "%.2f", $0)
                    }
                }
            }
        }
    }

    /// Apply a stock and its companion process in one transaction. An
    /// `onChange` performed this rewrite one layout pass later, allowing the
    /// menu-dismiss animation to briefly lay out several intermediate values.
    private var filmSelection: Binding<Int> {
        Binding(
            get: { film.film },
            set: { film = film.selecting(film: $0) }
        )
    }
}

private struct StockPicker: View {
    let title: String
    @Binding var selection: Int
    let stocks: [FilmStock]

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .layoutPriority(1)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Menu {
                ForEach(stocks) { stock in
                    Button {
                        steadySelection.wrappedValue = stock.index
                    } label: {
                        if stock.index == selection {
                            Label(stock.name, systemImage: "checkmark")
                        } else {
                            Text(stock.name)
                        }
                    }
                }
            } label: {
                Text(stocks.first { $0.index == selection }?.name ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
            .tint(SigmaTheme.ink)
            .menuIndicator(.visible)
            #if os(iOS)
            // Stable outer geometry prevents UIKit's menu-dismiss transition
            // from remeasuring every differently-sized stock name.
            .frame(width: 220, alignment: .trailing)
            #else
            // On macOS retain the native intrinsic popup width; forcing the
            // iOS width leaves an unnatural empty run before the indicator.
            .fixedSize(horizontal: true, vertical: false)
            #endif
            .transaction { $0.disablesAnimations = true }
        }
        .padding(.vertical, 13)
        .disabledRowStyle()
    }

    /// Writes the selection inside a no-animation transaction. A menu
    /// selection otherwise lands inside the menu-dismiss transaction, whose
    /// implicit animation rides every dependent relayout — a film switch
    /// rewrites paper/negative/halation, and the panel wobbles until it
    /// settles. Structural reveals still animate: `Disclosure` drives its own
    /// explicit springs.
    private var steadySelection: Binding<Int> {
        Binding(
            get: { selection },
            set: { new in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selection = new }
            }
        )
    }
}

// MARK: - Develop panel chrome

private struct DevelopRailActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ToggleDevelopRailActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// True when the develop panel (inspector / rail) is on-screen.
    var developRailActive: Bool {
        get { self[DevelopRailActiveKey.self] }
        set { self[DevelopRailActiveKey.self] = newValue }
    }

    /// Shows or hides the develop panel; no-op where it is unavailable.
    var toggleDevelopRail: () -> Void {
        get { self[ToggleDevelopRailActionKey.self] }
        set { self[ToggleDevelopRailActionKey.self] = newValue }
    }
}

/// Shared “Develop” title row — sheet, rail, and phone tray.
struct DevelopHeaderBar: View {
    var onReset: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            Text("Develop")
                .font(.headline)
                .foregroundStyle(SigmaTheme.ink)
            Spacer(minLength: 0)
            if let onReset {
                // Bare ink glyph — no chip behind the arrow.
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .tint(SigmaTheme.ink)
                .accessibilityLabel("Reset")
            }
            if let onDone {
                Button("Done", action: onDone)
                    .buttonStyle(.glass)
                    .tint(SigmaTheme.ink)
            }
        }
    }
}

/// Global defaults body (controls + export format).
struct DevelopDefaultsForm: View {
    @Binding var settings: DevelopSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DevelopControls(settings: $settings, isX3F: true)

            Divider()

            HStack {
                Text("Default format")
                Spacer()
                Picker("Default format", selection: $settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .font(.body)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 4)
    }
}

/// Vertical rule between the stage and the rail — run up through the toolbar
/// band on iOS; on macOS it stays below the window toolbar like a standard
/// panel separator.
struct DevelopColumnDivider: View {
    var body: some View {
        #if os(iOS)
        Rectangle()
            .fill(SigmaTheme.hairline)
            .frame(width: 1)
            .ignoresSafeArea(edges: .top)
        #else
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
        #endif
    }
}

/// The persistent develop panel: live editor controls while editing, global
/// defaults otherwise. Only this panel carries the paper/ink theme — window
/// chrome stays native.
struct DevelopRail: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DevelopSession.self) private var session

    var body: some View {
        @Bindable var store = store
        @Bindable var session = session

        VStack(spacing: 0) {
            #if os(iOS)
            SigmaWordmark(height: 16)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 10)
            #endif
            VStack(spacing: 10) {
                DevelopHeaderBar(onReset: session.isEditing
                    ? { session.settings = .init() }
                    : { store.defaults = DevelopSettings() })
                ScrollView {
                    if session.isEditing {
                        DevelopControls(
                            settings: $session.settings,
                            isX3F: session.isX3F,
                            autoExposureEV: session.autoExposureEV,
                            lensCorrectionAvailable: session.lensProfileAvailable
                        )
                        .padding(.horizontal, 4)
                    } else {
                        DevelopDefaultsForm(settings: $store.defaults)
                    }
                }
                .scrollIndicators(.never)
                #if os(iOS)
                .scrollEdgeEffectHidden(true, for: .all)
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        #if os(macOS)
        .background(SigmaTheme.paper)
        #else
        .background(SigmaTheme.paper.ignoresSafeArea(edges: .top))
        #endif
        // Stable identity across library ↔ editor so SwiftUI does not rebuild
        // the paper surface (the classic “sidebar loses color” remount glitch).
        .id("develop-rail")
    }
}

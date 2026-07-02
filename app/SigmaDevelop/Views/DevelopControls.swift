import SwiftUI
import SigmaFoveon

struct DevelopControls: View {
    @Binding var settings: DevelopSettings
    var isX3F: Bool = true
    var autoExposureEV: Float? = nil

    @State private var hdrEnabledAutoTone = false

    var body: some View {
        VStack(spacing: 0) {
            WhiteBalanceControl(whiteBalance: $settings.whiteBalance)

            Divider()

            DenoiseControl(mode: $settings.denoise,
                           strength: $settings.denoiseStrength,
                           chroma: $settings.denoiseChroma,
                           time: $settings.denoiseTime)
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

            if settings.autoTone {
                Divider()

                AutoExposureModeControl(mode: $settings.autoExposureMode)
            }

            Divider()

            LabeledSlider("Exposure", value: $settings.exposure, in: -3...3, step: 1 / 3,
                          accessory: autoToneAccessory) {
                String(format: "%+.1f EV", $0)
            }
            .animation(.snappy(duration: 0.28), value: settings.autoTone)

            Divider()

            LabeledSlider("HDR headroom", value: $settings.hdrEV, in: 0...3, step: 1 / 3) {
                String(format: "%+.1f EV", $0)
            }
            .disabled(!settings.hdr)

            Divider()

            SettingRow {
                Toggle("Monochrome", isOn: $settings.monochrome)
            }

            Divider()

            FilmControl(enabled: $settings.filmEnabled, film: $settings.film)

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
                Toggle("Lens correction", isOn: $settings.lensCorrection)
            }
            .disabled(!isX3F)
        }
        .font(.body)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        .onAppear {
            if settings.hdr && !settings.autoTone {
                settings.autoTone = true
                hdrEnabledAutoTone = true
            }
        }
    }

    private var hdrBinding: Binding<Bool> {
        Binding(
            get: { settings.hdr },
            set: { enabled in
                settings.hdr = enabled
                if enabled {
                    hdrEnabledAutoTone = !settings.autoTone
                    settings.autoTone = true
                } else if hdrEnabledAutoTone {
                    settings.autoTone = false
                    hdrEnabledAutoTone = false
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
        let mode = mode
        let ramp = WhiteBalance.temperatureRamp
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

            if mode == .custom {
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
                .transition(.opacity)
            }
        }
        .padding(.vertical, 13)
        .animation(.snappy(duration: 0.28), value: mode)
        .clipped()   // outermost
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
        .animation(.snappy(duration: 0.28), value: mode)
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("Denoise")
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

            if mode != .off {
                Divider()
                LabeledSlider("Strength", value: $strength, in: 0...2) {
                    String(format: "%.2f", $0)
                }
            }
            if mode == .wavelet {
                Divider()
                LabeledSlider("Chroma", value: $chroma, in: 0...4) {
                    String(format: "%.1f×", $0)
                }
            }
            if mode == .neural {
                Divider()
                LabeledSlider("JiT signal level", value: $time, in: 0.05...0.98) {
                    String(format: "t=%.2f", $0)
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: mode)
        // Strength means different things per algorithm; re-baseline on switch.
        .onChange(of: mode) { _, new in
            if new != .off { strength = new.defaultStrength }
        }
    }

    private var caption: String {
        switch mode {
        case .off: ""
        case .wavelet: "Profiled"
        case .neural: "Core ML"
        }
    }
}

private extension DenoiseMode {
    var label: String {
        switch self {
        case .off: "Off"
        case .wavelet: "Wavelet"
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
                        .transition(.opacity)
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

            if enabled {
                Divider()
                StockPicker(title: "Film", selection: $film.film, stocks: FilmSimData.films)

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

                if film.halation {
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

                Divider()
                LabeledSlider("Grain size", value: $film.grainSize, in: 0.25...4) {
                    String(format: "%.2f×", $0)
                }
                .disabled(!film.grain)
            }
        }
        .animation(.snappy(duration: 0.28), value: enabled)
        .animation(.snappy(duration: 0.28), value: film.negative)
        .animation(.snappy(duration: 0.28), value: film.halation)
        .onChange(of: film.film) { _, new in
            // A stock implies its process: companion paper (or scanned positive),
            // halation character, and a fresh neutral enlarger balance.
            film = film.selecting(film: new)
        }
    }

}

private struct StockPicker: View {
    let title: String
    @Binding var selection: Int
    let stocks: [FilmStock]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // stock menu will overrun
        let name = stocks.first { $0.index == selection }?.name ?? ""
        HStack(spacing: 12) {
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(stocks) { Text($0.name).tag($0.index) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(SigmaTheme.ink)
        }
        .padding(.vertical, 13)
        // disable paper for slides etc.
        .opacity(isEnabled ? 1 : 0.4)
    }
}

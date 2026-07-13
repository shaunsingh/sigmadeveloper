import Foundation
import SigmaFoveon

enum WhiteBalance: String, CaseIterable, Codable, Identifiable, Sendable {
    case asShot, auto, sunlight, shade, overcast, cloudy, incandescent, fluorescent, flash

    var id: String { rawValue }

    /// Post-decode white-balance WB
    var foveonMode: WhiteBalanceMode {
        switch self {
        case .asShot: .asShot
        case .auto: .auto
        default: .temperature(kelvin: Float(kelvin ?? 5500), tint: 0)
        }
    }

    var label: String { self == .asShot ? "As Shot" : rawValue.capitalized }

    /// Nominal correlated colour temp
    var kelvin: Int? {
        switch self {
        case .asShot, .auto: nil
        case .incandescent: 2850
        case .fluorescent: 3800
        case .sunlight: 5500
        case .flash: 5600
        case .cloudy: 6000
        case .overcast: 6500
        case .shade: 7500
        }
    }

    var kelvinLabel: String? { kelvin.map { "\($0)K" } }
    static let temperatureRamp: [WhiteBalance] =
        allCases.filter { $0.kelvin != nil }.sorted(using: KeyPathComparator(\.kelvin))
}

enum ExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case heic, jpeg, dng, tiff

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var requiresX3F: Bool { self == .dng || self == .tiff }

    var outputFormat: OutputFormat {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        case .dng: .dng
        case .tiff: .tiff
        }
    }

    var fileExtension: String { outputFormat.fileExtension }
}

struct DevelopSettings: Codable, Equatable, Hashable, Sendable {
    var whiteBalance: WhiteBalance = .asShot
    /// Quarter-turns clockwise (0…3), Per-image
    var rotation: Int = 0
    var exposure: Float = 0
    var autoTone: Bool = false
    var autoExposureMode: AutoExposureMode = .ettr
    var monochrome: Bool = false
    var contrast: Float? = nil
    var sharpness: Float = 0.5
    var lensCorrection: Bool = true
    var denoise: DenoiseMode = .off
    var denoiseStrength: Float = DenoiseMode.wavelet.defaultStrength
    var denoiseChroma: Float = 2
    var denoiseTime: Float = 0.85
    var hdr: Bool = false
    var hdrEV: Float = 2.3
    var filmEnabled: Bool = false
    var film: FilmSimSettings = FilmSimSettings()
    var quality: Double = 0.92
    var exportFormat: ExportFormat = .heic

    /// Turn the image by quarter-turns clockwise, normalised to 0…3.
    mutating func rotate(by quarterTurns: Int) {
        rotation = (((rotation + quarterTurns) % 4) + 4) % 4
    }

    /// Keep render combinations valid regardless of whether a change comes
    /// from an inspector control, keyboard command, or decoded saved state.
    mutating func setHDREnabled(_ enabled: Bool) {
        hdr = enabled
        if enabled { autoTone = true }
    }

    mutating func selectFilm(_ index: Int) {
        film = film.selecting(film: index)
    }

    mutating func repairInvariants(isX3F: Bool) {
        if hdr { autoTone = true }
        if !isX3F {
            denoise = .off
            lensCorrection = false
        }
    }

    /// Properties that affect pixels. Export-only fields (`quality`,
    /// `exportFormat`) are intentionally excluded from preview invalidation.
    struct RenderKey: Equatable, Hashable, Sendable {
        var whiteBalance: WhiteBalance
        var rotation: Int
        var exposure: Float
        var autoTone: Bool
        var autoExposureMode: AutoExposureMode?
        var monochrome: Bool
        var contrast: Float?
        var sharpness: Float
        var lensCorrection: Bool
        var denoise: DenoiseMode
        var denoiseStrength: Float?
        var denoiseChroma: Float?
        var denoiseTime: Float?
        var hdr: Bool
        var hdrEV: Float?
        var film: FilmSimSettings?
    }

    var renderKey: RenderKey {
        RenderKey(whiteBalance: whiteBalance, rotation: rotation, exposure: exposure, autoTone: autoTone,
                  autoExposureMode: autoTone ? autoExposureMode : nil,
                  monochrome: monochrome, contrast: contrast, sharpness: sharpness,
                  lensCorrection: lensCorrection,
                  denoise: denoise,
                  denoiseStrength: denoise != .off ? denoiseStrength : nil,
                  denoiseChroma: denoise == .wavelet ? denoiseChroma : nil,
                  denoiseTime: denoise == .neural ? denoiseTime : nil,
                  hdr: hdr, hdrEV: hdr ? hdrEV : nil,
                  film: filmEnabled ? film : nil)
    }

    struct GlobalKey: Equatable, Hashable, Sendable {
        var whiteBalance: WhiteBalance
        var exposure: Float
        var autoTone: Bool
        var autoExposureMode: AutoExposureMode
        var monochrome: Bool
        var contrast: Float?
        var sharpness: Float
        var lensCorrection: Bool
        var denoise: DenoiseMode
        var denoiseStrength: Float
        var denoiseChroma: Float
        var denoiseTime: Float
        var hdr: Bool
        var hdrEV: Float
        var filmEnabled: Bool
        var film: FilmSimSettings
    }

    var globalKey: GlobalKey {
        get {
            GlobalKey(whiteBalance: whiteBalance, exposure: exposure, autoTone: autoTone,
                      autoExposureMode: autoExposureMode,
                      monochrome: monochrome, contrast: contrast, sharpness: sharpness,
                      lensCorrection: lensCorrection,
                      denoise: denoise, denoiseStrength: denoiseStrength,
                      denoiseChroma: denoiseChroma, denoiseTime: denoiseTime,
                      hdr: hdr, hdrEV: hdrEV,
                      filmEnabled: filmEnabled, film: film)
        }
        set {
            whiteBalance = newValue.whiteBalance
            exposure = newValue.exposure
            autoTone = newValue.autoTone
            autoExposureMode = newValue.autoExposureMode
            monochrome = newValue.monochrome
            contrast = newValue.contrast
            sharpness = newValue.sharpness
            lensCorrection = newValue.lensCorrection
            denoise = newValue.denoise
            denoiseStrength = newValue.denoiseStrength
            denoiseChroma = newValue.denoiseChroma
            denoiseTime = newValue.denoiseTime
            hdr = newValue.hdr
            hdrEV = newValue.hdrEV
            filmEnabled = newValue.filmEnabled
            film = newValue.film
        }
    }

    func foveonOptions() -> FoveonOptions {
        var o = FoveonOptions()
        o.wb = whiteBalance.foveonMode
        o.rotate = rotation
        o.exposure = exposure
        o.autoTone = autoTone
        o.autoExposureMode = autoExposureMode
        o.monochrome = monochrome
        o.contrast = contrast
        o.sharpness = sharpness
        o.lensCorrection = lensCorrection
        o.denoise = denoise
        o.denoiseStrength = denoiseStrength
        o.denoiseChroma = denoiseChroma
        o.denoiseTime = denoiseTime
        o.hdr = hdr
        o.hdrEV = hdrEV
        o.film = filmEnabled ? film : nil
        o.quality = quality
        return o
    }
}

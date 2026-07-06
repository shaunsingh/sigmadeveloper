import CoreImage
import Foundation
import ImageIO
import Metal
import os

// MARK: - Public configuration

/// `dng`/`tiff` are decode targets;
/// `jpeg`/`heic` additionally run the Core Image render
public enum OutputFormat: String, Sendable, CaseIterable {
    case dng, tiff, jpeg, heic

    public var fileExtension: String {
        switch self {
        case .dng: "dng"
        case .tiff: "tif"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

/// Auto-exposure metering w/ ETTR (highlight-percentile) & Key (log-average mid-grey).
public enum AutoExposureMode: String, Sendable, CaseIterable, Codable, Hashable {
    case ettr, key
}

/// Post-Decode White balance
public enum WhiteBalanceMode: Sendable, Equatable {
    case asShot
    case auto
    case temperature(kelvin: Float, tint: Float)
}

/// edge-avoiding à-trous denoising + neural coreML
public enum DenoiseMode: String, Sendable, CaseIterable, Codable, Hashable {
    case off, wavelet, neural
    public var defaultStrength: Float {
        self == .wavelet ? 0.67 : 1
    }
}

/// knobs
public struct FoveonOptions: Sendable {
    public var quality: Double = 0.92
    public var sharpness: Float = 0.5
    public var contrast: Float? = nil        // nil → none
    public var exposure: Float = 0           // EV, on top of auto-tone
    public var autoTone = true               // auto-expose (see `autoExposureMode`)
    public var autoExposureMode: AutoExposureMode = .ettr
    public var toneKey: Float = 0.07         // `key` mode target
    public var monochrome = false            // black & white
    public var hdr = true                    // embed an ISO HDR gain map
    public var hdrEV: Float = 2.3            // highlight headroom in stops @ white
    public var wb: WhiteBalanceMode = .asShot // post-decode white balance
    public var rotate = 0                    // quarter-turns clockwise
    public var lensCorrection = true         // profile-driven distortion/CA/vignette (x3f)
    public var film: FilmSimSettings? = nil  // spectral film simulation (nil → off)
    public var denoise: DenoiseMode = .off   // wavelet (profiled) or neural (Core ML)
    /// wavelet: threshold scale; neural: 0…1 blend. nil → the mode's `defaultStrength`.
    public var denoiseStrength: Float? = nil
    public var denoiseChroma: Float = 2      // wavelet: extra chroma shrink multiplier
    public var denoiseModels: [URL] = []     // neural: empty → auto-discover; >1 → cascade
    public var denoiseTime: Float = 0.85     // neural JiT t: 1≈clean/input, 0≈pure noise
    public var denoiseEnsemble = false       // neural 8-way D4 self-ensemble (8× cost)

    public init() {}
}

public struct FoveonTarget: Sendable {
    public var format: OutputFormat
    public var url: URL
    public init(_ format: OutputFormat, _ url: URL) {
        self.format = format
        self.url = url
    }
}

public struct FoveonJob: Sendable {
    public var input: URL
    public var targets: [FoveonTarget]
    public var options: FoveonOptions

    public init(input: URL, targets: [FoveonTarget], options: FoveonOptions = .init()) {
        self.input = input
        self.targets = targets
        self.options = options
    }
}

// MARK: - Developer

/// Embeddable Foveon X3F developer for iOS/macOS
public final class FoveonDeveloper: @unchecked Sendable {
    let context: CIContext
    private let denoiserState = OSAllocatedUnfairLock(initialState: DenoiserCache())

    private struct DenoiserCache {
        var denoisers: [String: FoveonDenoiser] = [:]
        var badKeys: Set<String> = []
        var warnedNoModel = false
        /// can 'foveondenoiser.discover``
        var discovered: [URL]? = nil
    }

    public init() {
        self.context = FoveonDeveloper.makeContext()
    }

    /// Lazily load (and cache) the neural denoiser for these options, or nil when
    /// denoising is off or no model is available. Shared across concurrent jobs.
    func denoiser(for o: FoveonOptions) -> FoveonDenoiser? {
        guard o.denoise == .neural else { return nil }
        let urls: [URL]
        if o.denoiseModels.isEmpty {
            urls = denoiserState.withLock { state in
                if let cached = state.discovered { return cached }
                let found = FoveonDenoiser.discover()
                state.discovered = found
                return found
            }
        } else {
            urls = o.denoiseModels
        }
        guard !urls.isEmpty else {
            denoiserState.withLock { state in
                if !state.warnedNoModel {
                    state.warnedNoModel = true
                    warnStderr("--denoise set but no Core ML model found (pass --denoise-model, or place FoveonJiT.mlpackage beside the binary / in the app bundle)")
                }
            }
            return nil
        }
        let key = urls.map(\.path).joined(separator: "|")
        return denoiserState.withLock { state in
            if let cached = state.denoisers[key] { return cached }
            guard !state.badKeys.contains(key) else { return nil }
            do {
                let made = try FoveonDenoiser(modelURLs: urls)
                state.denoisers[key] = made
                return made
            } catch {
                state.badKeys.insert(key)
                warnStderr("failed to load denoise model(s): \(key): \(error)")
                return nil
            }
        }
    }

    /// Free transient GPU working sets (the wavelet denoiser's pooled pyramid
    /// textures). Call when an interactive viewer goes away; steady-state
    /// rendering re-warms the pool on first use.
    public func releaseTransientResources() {
        WaveletDenoise.shared?.drain()
    }

    public func render(x3f: Data, to format: OutputFormat, options: FoveonOptions = .init()) throws -> Data {
        // The Rust decode always renders the authentic as-shot baseline (nil WB);
        // white balance is a post-decode finishing adjustment (see `options.wb`).
        switch format {
        case .dng:
            return try renderX3F(x3f, mode: .dng).data
        case .tiff:
            return try renderX3F(x3f, mode: .tiffLinearF16).data
        case .jpeg, .heic:
            return try encode(finish(decode(x3f: x3f), options: options), as: format, quality: options.quality)
        }
    }

    /// Render an already-decoded image file (RAW, DNG, TIFF, JPEG, …)
    public func render(file url: URL, to format: OutputFormat, options: FoveonOptions = .init()) throws -> Data {
        switch format {
        case .jpeg, .heic:
            return try encode(render(loadLinear(url), options, isX3F: false), as: format, quality: options.quality)
        case .dng, .tiff:
            throw FoveonError.badInput("\(format.rawValue) output requires an .x3f input")
        }
    }

    /// overlap for compute saturation
    @discardableResult
    public func process(_ jobs: [FoveonJob], maxConcurrent: Int? = nil,
                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Result<Void, Error>] {
        let defaultLimit: Int
        if jobs.contains(where: { $0.options.denoise == .neural }) {
            defaultLimit = 1
        } else if jobs.contains(where: { FoveonDeveloper.isRAW($0.input) }) {
            // CIRAW is GPU/ANE/Mem bound so 2-wide is fine
            defaultLimit = 2
        } else if jobs.contains(where: { $0.input.pathExtension.lowercased() == "x3f" }) {
            // GPU bound again, measured for top throughput
            defaultLimit = 4
        } else {
            defaultLimit = ProcessInfo.processInfo.activeProcessorCount
        }
        let limit = max(1, maxConcurrent ?? defaultLimit)
        var results = [Result<Void, Error>?](repeating: nil, count: jobs.count)

        await withTaskGroup(of: (Int, Result<Void, Error>).self) { group in
            var next = 0
            func submit() {
                guard next < jobs.count else { return }
                let i = next
                let job = jobs[i]
                next += 1
                group.addTask {
                    do {
                        try await self.runBlocking { try self.processOne(job) }
                        return (i, .success(()))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            for _ in 0..<min(limit, jobs.count) { submit() }
            var completed = 0
            while let (i, r) = await group.next() {
                results[i] = r
                completed += 1
                onProgress?(completed, jobs.count)
                submit()
            }
        }
        return results.map { $0 ?? .failure(FoveonError.render("job not run")) }
    }

    // MARK: - Internals

    private func processOne(_ job: FoveonJob) throws {
        if job.input.pathExtension.lowercased() == "x3f" {
            try processX3F(job)
        } else {
            try processImage(job)
        }
    }

    private func processX3F(_ job: FoveonJob) throws {
        let x3f = try Data(contentsOf: job.input)
        // only one decode
        var decoder: RawDecoder?
        func prepared() throws -> RawDecoder {
            if let decoder { return decoder }
            let d = try RawDecoder(x3f: x3f)
            decoder = d
            return d
        }
        var rendered: (sdr: CIImage, hdr: CIImage?)?
        func renderedImage() throws -> (sdr: CIImage, hdr: CIImage?) {
            if let f = rendered { return f }
            // Rendered targets take the RGBA bitmap decode
            let f = finish(decodedRaw(try prepared().render(mode: .rgbaLinearF16), proxy: false),
                           options: job.options)
            rendered = f
            return f
        }

        for target in job.targets {
            let data: Data
            switch target.format {
            case .dng:  data = try prepared().render(mode: .dng).data
            case .tiff: data = try prepared().render(mode: .tiffLinearF16).data
            case .jpeg, .heic: data = try encode(renderedImage(), as: target.format, quality: job.options.quality)
            }
            try data.write(to: target.url, options: .atomic)
        }
    }

    /// Render a non-X3F input (RAW/DNG/TIFF/JPEG/…) to the requested image format(s)
    private func processImage(_ job: FoveonJob) throws {
        var rendered: (sdr: CIImage, hdr: CIImage?)?
        func renderedImage() throws -> (sdr: CIImage, hdr: CIImage?) {
            if let r = rendered { return r }
            let r = render(try loadLinear(job.input), job.options, isX3F: false)
            rendered = r
            return r
        }
        for target in job.targets {
            switch target.format {
            case .jpeg, .heic:
                let data = try encode(renderedImage(), as: target.format, quality: job.options.quality)
                try data.write(to: target.url, options: .atomic)
            case .dng, .tiff:
                throw FoveonError.badInput("\(target.format.rawValue) output requires an .x3f input")
            }
        }
    }

    /// Numeric rank of a `CIRAWDecoderVersion` ("version8" → 8); unversioned
    /// entries (e.g. `.none`) rank lowest so they are never auto-selected.
    private func decoderRank(_ v: CIRAWDecoderVersion) -> Int {
        Int(v.rawValue.filter(\.isNumber)) ?? -1
    }

    /// Camera RAW containers Core Image can demosaic via `CIRAWFilter`.
    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf",
        "raf", "rw2", "orf", "pef", "raw", "rwl", "dcr", "kdc", "mrw", "3fr", "fff",
    ]

    static func isRAW(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// A configured RAW9 demosaic filter for `url`.
    private func rawFilter(_ url: URL) throws -> CIRAWFilter {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw FoveonError.badInput("could not decode RAW: \(url.lastPathComponent)")
        }
        // Use Raw9
        if let newest = filter.supportedDecoderVersions
            .max(by: { decoderRank($0) < decoderRank($1) }) {
            filter.decoderVersion = newest
        }
        // Embedded DNG opcode / maker profiles (distortion, CA, vignette)
        if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = true }
        // Decode with full highlight headroom
        filter.extendedDynamicRangeAmount = 2
        return filter
    }

    /// MARK - Fable

    /// Demosaic `url` capped to `maxDimension` and rasterise the result once.
    /// A lazy `CIRAWFilter` graph re-runs the whole RAW9 pipeline on every render
    /// (hundreds of ms to seconds); the concrete scene-linear bitmap this returns
    /// makes scene analysis and every finishing pass a milliseconds-scale read.
    /// - Returns: the bitmap-backed image and its scale relative to the native decode.
    func rawProxy(_ url: URL, maxDimension: CGFloat) throws -> (image: CIImage, nativeScale: Float) {
        let filter = try rawFilter(url)
        // `scaleFactor` constraints on the RAW9 pipeline:
        //  * it must be set before anything materialises the filter's decode graph —
        //    even reading `nativeSize` freezes it, after which a scale change only
        //    reshapes the extent and the render comes back as a crop;
        //  * only power-of-two factors decode correctly (arbitrary ones crop too).
        // So the native size comes from ImageIO metadata, and we halve down to the
        // smallest size that still covers `maxDimension`.
        let longest = nativeLongEdge(url)
        var scale: CGFloat = 1
        while let longest, longest * scale * 0.5 >= maxDimension { scale *= 0.5 }
        if scale < 1 { filter.scaleFactor = Float(scale) }
        guard let image = filter.outputImage else {
            throw FoveonError.badInput("could not decode RAW: \(url.lastPathComponent)")
        }
        // Fold the remaining pow2→target downscale into the same render.
        let (bitmap, extra) = try rasterizedProxy(image, maxDimension: maxDimension)
        return (bitmap, Float(scale) * extra)
    }

    /// Downscale (when needed) and rasterise a decodable image in one render, so
    /// interactive passes read a concrete bitmap instead of re-decoding the source.
    /// - Returns: the bitmap-backed image and its scale relative to the input.
    func rasterizedProxy(_ image: CIImage, maxDimension: CGFloat) throws -> (image: CIImage, nativeScale: Float) {
        var scaled = image
        var scale: CGFloat = 1
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxDimension {
            scale = maxDimension / longest
            // Integral per-axis scale: no partially-covered edge row (the faint
            // bar), and the proxy covers the full frame exactly, keeping
            // deep-zoom tile placement registered (see integralScaleTransform).
            scaled = image.transformed(by: integralScaleTransform(image.extent, scale: scale))
        }
        // `deferred: false` forces the decode now; the default overload sometimes
        // hands back a lazily-backed CGImage that would re-decode on first use.
        guard let bitmap = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh,
                                                 colorSpace: extendedLinearSRGB, deferred: false) else {
            throw FoveonError.render("proxy rasterise failed")
        }
        return (CIImage(cgImage: bitmap), Float(scale))
    }

    /// Native long-edge pixel count from ImageIO metadata (primary image), read
    /// without constructing a decode graph. nil when the container hides it.
    private func nativeLongEdge(_ url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGFloat(max(w, h))
    }

    /// Load any decoded image into a scene-linear `CIImage` for the finishing graph.
    /// RAW/DNG demosaic through `CIRAWFilter`; other files honour their embedded
    /// profile, falling back to scene-linear for our untagged f16 TIFF intermediate.
    func loadLinear(_ url: URL) throws -> CIImage {
        if FoveonDeveloper.isRAW(url) {
            guard let image = try rawFilter(url).outputImage else {
                throw FoveonError.badInput("could not decode RAW: \(url.lastPathComponent)")
            }
            return image
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw FoveonError.badInput("could not load image: \(url.lastPathComponent)")
        }
        guard image.colorSpace != nil else {
            return CIImage(contentsOf: url, options: [
                .applyOrientationProperty: true, .colorSpace: extendedLinearSRGB,
            ]) ?? image
        }
        return image
    }

    /// Encode the rendered SDR image (with an optional HDR gain-map sibling).
    public func encode(_ rendered: (sdr: CIImage, hdr: CIImage?), as format: OutputFormat, quality: Double = 0.92) throws -> Data {
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        var options: [CIImageRepresentationOption: Any] = [qualityKey: quality]
        if let hdr = rendered.hdr { options[.hdrImage] = hdr }

        switch format {
        case .jpeg:
            guard let data = context.jpegRepresentation(of: rendered.sdr, colorSpace: sRGBColorSpace, options: options) else {
                throw FoveonError.render("JPEG encode returned nil")
            }
            return data
        case .heic:
            return try context.heif10Representation(of: rendered.sdr, colorSpace: displayP3ColorSpace, options: options)
        case .dng, .tiff:
            throw FoveonError.render("\(format.rawValue) is not a rendered image format")
        }
    }

    /// Run blocking decode/render work on a GCD thread so the Swift cooperative
    /// pool is never starved while many images are processed at once.
    private func runBlocking(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .default).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: extendedLinearSRGB,
            .workingFormat: CIFormat.RGBAh,
            // Renders yield the GPU to UI animation instead of starving it
            .priorityRequestLow: true,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }
}

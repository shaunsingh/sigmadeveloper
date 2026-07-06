import CoreGraphics
import CoreImage
import Foundation

// Two-stage developing for interactive viewers: decode once, finish many times.
// White balance is baked in at decode time, while exposure, tone, monochrome,
// lens correction, sharpening and HDR remain cheap finishing passes over a cached
// `DecodedRaw`/`DevelopedImage`.

/// A decoded scene-linear image, reusable across many finishing passes.
public struct DecodedRaw: @unchecked Sendable {
    /// Scene-linear input to the finishing graph.
    public let image: CIImage
    public let width: Int
    public let height: Int
    /// `.x3f` inputs can also be exported as DNG/TIFF; others cannot.
    public let isX3F: Bool
    /// Scene metering
    let stats: SceneStats?
    /// Top Foveon layer (blue) monochrome weights; nil for non-Foveon inputs (→ luma).
    let monoWeights: SIMD3<Float>?
    /// Resolved lens-correction profile
    let lens: LensCorrection?
    /// image iso
    public let iso: Float
    /// Decoded pixels per native pixel
    public let nativeScale: Float
    /// self explanatory
    public var hasLensProfile: Bool { lens != nil }
}

public struct DevelopedImage: @unchecked Sendable {
    public let image: CIImage
    public let width: Int
    public let height: Int
    /// EV applied by auto-exposure (0 when `autoTone` was off).
    public let autoExposureEV: Float
    /// Estimated scene neutral
    let wbNeutral: SIMD3<Float>?
    let monoWeights: SIMD3<Float>?
    let lens: LensCorrection?
    let nativeScale: Float
    /// also self explanatory
    public var hasLensProfile: Bool { lens != nil }
    /// Long edge of the file's native pixel grid backing this develop
    public var nativeLongEdge: Int {
        nativeScale > 0 ? Int((Float(max(width, height)) / nativeScale).rounded()) : max(width, height)
    }
}

/// Proxy cap for interactive decodes
let proxyMaxDimension: CGFloat = 2560

/// Snap a uniform downscale of `extent` to per-axis factors that land exactly on
/// integral pixel sizes (≤0.5px aspect skew). A fractional scaled size leaves a
/// partially-covered edge row — `CIImage` rounds its extent outward — that
/// rasterises as a faint dark bar; cropping the row away instead misregisters
/// deep-zoom tiles, which are placed as if the preview covers the full frame.
func integralScaleTransform(_ extent: CGRect, scale s: CGFloat) -> CGAffineTransform {
    CGAffineTransform(scaleX: (extent.width * s).rounded() / extent.width,
                      y: (extent.height * s).rounded() / extent.height)
}

extension FoveonDeveloper {

    /// Decode `.x3f` bytes to a reusable scene-linear image
    /// Rust core now delivers a bare RGBA16F bitmap & donor supplies cached scene analysis
    public func decode(x3f data: Data, proxy: Bool = false, reusing donor: DecodedRaw? = nil) throws -> DecodedRaw {
        decodedRaw(try renderX3F(data, mode: proxy ? .rgbaProxyHalf : .rgbaLinearF16),
                   proxy: proxy, donor: donor)
    }

    /// Wrap a Rust RGBA16F bitmap render as a reusable scene-linear image
    func decodedRaw(_ raw: RawRender, proxy: Bool, donor: DecodedRaw? = nil) -> DecodedRaw {
        var image = CIImage(bitmapData: raw.data, bytesPerRow: raw.width * 8,
                            size: CGSize(width: raw.width, height: raw.height),
                            format: .RGBAh, colorSpace: extendedLinearSRGB)
        if raw.orientation != 1 {
            image = image.oriented(forExifOrientation: Int32(raw.orientation))
        }
        let e = image.extent.integral
        return DecodedRaw(image: image, width: Int(e.width), height: Int(e.height), isX3F: true,
                          stats: donor?.stats ?? analyzeScene(of: image),
                          monoWeights: raw.monoWeights, lens: LensCorrection(raw.lens), iso: raw.iso,
                          nativeScale: proxy ? 0.5 : 1)
    }

    /// Decode supported input (x3f / RAW / DNG / TIFF / image) to a reusable scene-linear img
    /// vars; proxy: decode at reduced size for previews etc, reuseing: an earlier decode of the
    /// same file w/ cached scene analysis
    public func decode(file url: URL, proxy: Bool = false, reusing donor: DecodedRaw? = nil) throws -> DecodedRaw {
        if url.pathExtension.lowercased() == "x3f" {
            return try decode(x3f: try Data(contentsOf: url), proxy: proxy, reusing: donor)
        }
        if proxy, FoveonDeveloper.isRAW(url) {
            let (image, nativeScale) = try rawProxy(url, maxDimension: proxyMaxDimension)
            let e = image.extent.integral
            return DecodedRaw(image: image, width: Int(e.width), height: Int(e.height),
                              isX3F: false, stats: donor?.stats ?? analyzeScene(of: image),
                              monoWeights: nil, lens: nil, iso: 0, nativeScale: nativeScale)
        }
        let image = try loadLinear(url)
        let e = image.extent.integral
        return DecodedRaw(image: image, width: Int(e.width), height: Int(e.height), isX3F: false,
                          stats: donor?.stats ?? analyzeScene(of: image),
                          monoWeights: nil, lens: nil, iso: 0, nativeScale: 1)
    }

    public func develop(_ decoded: DecodedRaw, options: FoveonOptions = .init()) -> DevelopedImage {
        // upfront rotation everything downstream is adially/isotropically symmetric
        let turns = ((options.rotate % 4) + 4) % 4
        var image = decoded.image
        var (width, height) = (decoded.width, decoded.height)
        if turns != 0 {
            image = image.oriented(forExifOrientation: [1, 6, 3, 8][turns])
            if turns % 2 == 1 { swap(&width, &height) }
        }
        // Reuse the decode's cached analysis
        let developed = developLinear(image, options, isX3F: decoded.isX3F, stats: decoded.stats)
        return DevelopedImage(image: developed.image, width: width, height: height,
                              autoExposureEV: developed.autoEV, wbNeutral: decoded.stats?.wbNeutral,
                              monoWeights: decoded.monoWeights, lens: decoded.lens,
                              nativeScale: decoded.nativeScale)
    }

    public func finish(_ decoded: DecodedRaw, options: FoveonOptions = .init()) -> (sdr: CIImage, hdr: CIImage?) {
        finish(develop(decoded, options: options), options: options)
    }

    public func finish(_ developed: DevelopedImage, options: FoveonOptions = .init()) -> (sdr: CIImage, hdr: CIImage?) {
        tone(developed.image, options, monoWeights: developed.monoWeights,
             wbNeutral: developed.wbNeutral, scale: developed.nativeScale, lens: developed.lens)
    }

    /// Finish + rasterise to a display `CGImage`, optionally downscaled so the
    /// longest edge is `maxDimension` (thumbnails and fast slider previews).
    public func previewImage(_ decoded: DecodedRaw, options: FoveonOptions = .init(), maxDimension: Int? = nil) -> CGImage? {
        previewImage(develop(decoded, options: options), options: options, maxDimension: maxDimension)
    }

    public func previewImage(_ developed: DevelopedImage, options: FoveonOptions = .init(), maxDimension: Int? = nil) -> CGImage? {
        previewImage(developed, options: options,
                     region: CGRect(x: 0, y: 0, width: 1, height: 1),
                     maxDimension: maxDimension)?.image
    }

    /// rasterize a unit rect over the displayed image, through the same graph, @ decode res
    /// capped at max dimension on long edge w/ new high res tiled placed overlay
    public func previewImage(_ developed: DevelopedImage, options: FoveonOptions = .init(),
                             region: CGRect, maxDimension: Int? = nil) -> (image: CGImage, region: CGRect)? {
        // Downscale before tone-mapping so sharpen/grain track the output scale
        var image = developed.image
        var scale = developed.nativeScale
        if let maxDimension {
            let longest = max(CGFloat(developed.width) * region.width,
                              CGFloat(developed.height) * region.height)
            // The cap is a pixel budget, not an exact size: within 25% of it the
            // native grid beats a softening resample (X3F's 2640 renders native
            // under the 2560 preview cap, so zoom magnifies real pixels).
            if longest > CGFloat(maxDimension) * 5 / 4 {
                let s = CGFloat(maxDimension) / longest
                image = image.transformed(by: integralScaleTransform(image.extent, scale: s))
                scale *= Float(s)
            }
        }
        let extent = image.extent
        // top-left-origin unit rect == CI bottom left origins
        let crop = CGRect(x: extent.minX + region.minX * extent.width,
                          y: extent.minY + (1 - region.maxY) * extent.height,
                          width: region.width * extent.width,
                          height: region.height * extent.height)
            .intersection(extent).integral
        guard !crop.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        let actual = CGRect(x: (crop.minX - extent.minX) / extent.width,
                            y: 1 - (crop.maxY - extent.minY) / extent.height,
                            width: crop.width / extent.width,
                            height: crop.height / extent.height)
        let result = tone(image, options, monoWeights: developed.monoWeights,
                          wbNeutral: developed.wbNeutral, scale: scale,
                          lens: developed.lens)
        if options.hdr, let hdr = result.hdr {
            return context.createCGImage(hdr, from: crop, format: .RGBAh,
                                         colorSpace: extendedLinearDisplayP3ColorSpace, deferred: false).map { ($0, actual) }
        }
        return context.createCGImage(result.sdr, from: crop, format: .RGBA8,
                                     colorSpace: displayP3ColorSpace, deferred: false).map { ($0, actual) }
    }

    /// Encode a decoded image straight to the requested format's bytes. JPEG/HEIC
    /// run the finishing graph; DNG/TIFF require the original `.x3f` bytes, which
    /// a `DecodedRaw` does not hold — pass them via `x3f`.
    public func encode(_ decoded: DecodedRaw, as format: OutputFormat, options: FoveonOptions, x3f: Data? = nil) throws -> Data {
        switch format {
        case .jpeg, .heic:
            return try encode(finish(decoded, options: options), as: format, quality: options.quality)
        case .dng, .tiff:
            guard decoded.isX3F, let x3f else {
                throw FoveonError.badInput("\(format.rawValue) output requires the original .x3f")
            }
            let mode: RawMode = format == .dng ? .dng : .tiffLinearF16
            return try renderX3F(x3f, mode: mode).data
        }
    }
}

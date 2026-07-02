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
    /// The decode's own developed f16 TIFF bytes (x3f only) — reused verbatim for a
    /// TIFF export so it never re-runs the Rust develop. nil for non-x3f inputs.
    let tiffData: Data?
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
}

/// Proxy cap for interactive decodes
let proxyMaxDimension: CGFloat = 2560

extension FoveonDeveloper {

    /// Decode `.x3f` bytes to a reusable scene-linear image
    public func decode(x3f data: Data, proxy: Bool = false) throws -> DecodedRaw {
        let raw = try renderX3F(data, mode: proxy ? .tiffProxyHalf : .tiffLinearF16, whiteBalance: nil)
        guard let image = CIImage(data: raw.data, options: [
            .colorSpace: extendedLinearSRGB, .applyOrientationProperty: true,
        ]) else { throw FoveonError.render("could not load developed TIFF") }
        return DecodedRaw(image: image, width: raw.width, height: raw.height, isX3F: true,
                          tiffData: proxy ? nil : raw.data, stats: analyzeScene(of: image),
                          monoWeights: raw.monoWeights, lens: LensCorrection(raw.lens), iso: raw.iso,
                          nativeScale: proxy ? 0.5 : 1)
    }

    /// Decode supported input (x3f / RAW / DNG / TIFF / image) to a reusable scene-linear img
    /// vars; proxy: decode at reduced size for previews etc, reuseing: an earlier decode of the
    /// same file w/ cached scene analysis
    public func decode(file url: URL, proxy: Bool = false, reusing donor: DecodedRaw? = nil) throws -> DecodedRaw {
        if url.pathExtension.lowercased() == "x3f" {
            return try decode(x3f: try Data(contentsOf: url), proxy: proxy)
        }
        if proxy, FoveonDeveloper.isRAW(url) {
            let (image, nativeScale) = try rawProxy(url, maxDimension: proxyMaxDimension)
            let e = image.extent.integral
            return DecodedRaw(image: image, width: Int(e.width), height: Int(e.height),
                              isX3F: false, tiffData: nil, stats: analyzeScene(of: image),
                              monoWeights: nil, lens: nil, iso: 0, nativeScale: nativeScale)
        }
        let image = try loadLinear(url)
        let e = image.extent.integral
        return DecodedRaw(image: image, width: Int(e.width), height: Int(e.height), isX3F: false,
                          tiffData: nil, stats: donor?.stats ?? analyzeScene(of: image),
                          monoWeights: nil, lens: nil, iso: 0, nativeScale: 1)
    }

    public func develop(_ decoded: DecodedRaw, options: FoveonOptions = .init()) -> DevelopedImage {
        // Reuse the decode's cached analysis
        let developed = developLinear(decoded.image, options, isX3F: decoded.isX3F, stats: decoded.stats)
        return DevelopedImage(image: developed.image, width: decoded.width, height: decoded.height,
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
        // Downscale the denoised image before tone-mapping
        var image = developed.image
        var scale = developed.nativeScale
        if let maxDimension, developed.width > 0, developed.height > 0 {
            let longest = max(developed.width, developed.height)
            if longest > maxDimension {
                let s = CGFloat(maxDimension) / CGFloat(longest)
                image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                scale *= Float(s)
            }
        }
        let result = tone(image, options, monoWeights: developed.monoWeights,
                          wbNeutral: developed.wbNeutral, scale: scale,
                          lens: developed.lens)
        // EDR Canvas
        if options.hdr, let hdr = result.hdr,
           let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            return context.createCGImage(hdr, from: hdr.extent.integral, format: .RGBAh, colorSpace: space)
        }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        return context.createCGImage(result.sdr, from: result.sdr.extent.integral, format: .RGBA8, colorSpace: space)
    }

    /// Encode a decoded image straight to the requested format's bytes. JPEG/HEIC
    /// run the finishing graph; DNG/TIFF require the original `.x3f` bytes, which
    /// a `DecodedRaw` no longer holds — pass them via `x3f`.
    public func encode(_ decoded: DecodedRaw, as format: OutputFormat, options: FoveonOptions, x3f: Data? = nil) throws -> Data {
        switch format {
        case .jpeg, .heic:
            return try encode(finish(decoded, options: options), as: format, quality: options.quality)
        case .dng, .tiff:
            // A TIFF export is exactly the decode's own developed bytes — reuse them.
            if format == .tiff, let tiff = decoded.tiffData { return tiff }
            guard decoded.isX3F, let x3f else {
                throw FoveonError.badInput("\(format.rawValue) output requires the original .x3f")
            }
            let mode: RawMode = format == .dng ? .dng : .tiffLinearF16
            return try renderX3F(x3f, mode: mode, whiteBalance: nil).data
        }
    }
}

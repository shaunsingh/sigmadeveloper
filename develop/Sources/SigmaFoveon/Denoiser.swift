import Accelerate
import CoreImage
import CoreML
import Foundation

// NTIRE & JIT Core ML image denoising

final class FoveonDenoiser: @unchecked Sendable {
    private enum Domain: String {
        case srgb, linear

        init(metadata value: String?) {
            self = value?.lowercased() == "linear" ? .linear : .srgb
        }

        var colorSpace: CGColorSpace {
            switch self {
            case .srgb: CGColorSpace(name: CGColorSpace.sRGB)!
            case .linear: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            }
        }
    }

    private struct Stage {
        let model: MLModel
        let imageInput: String
        let timeInput: String?
        let timeShape: [NSNumber]
        let timeType: MLMultiArrayDataType
        let output: String
        let domain: Domain
    }
    private typealias TimeFeature = (name: String, value: MLFeatureValue)

    private let stages: [Stage]   // one model, or a cascade
    private let tile: Int         // model's fixed square input (e.g. 512)
    private let overlap: Int      // feathered seam between neighbouring tiles
    private let win: [Float]      // pre-computed separable feather window
    private let colorSpace: CGColorSpace

    /// Load one or more models (each a `.mlmodelc`, or a `.mlpackage`/`.mlmodel`
    /// compiled on the fly); they run in order as a cascade.
    init(modelURLs urls: [URL]) throws {
        guard !urls.isEmpty else { throw FoveonError.render("no denoise model") }
        let config = MLModelConfiguration()

        // honestly don't get why the neural engine even exists
        // maybe this is why my m6 ultra is delayed
        // or maybe apple silicon isn't actually that good

        config.computeUnits = .cpuAndGPU
        let stages = try urls.map { url -> Stage in
            let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
            let model = try MLModel(contentsOf: compiled, configuration: config)
            return try Self.stage(for: model)
        }
        let domain = stages[0].domain
        guard stages.allSatisfy({ $0.domain == domain }) else {
            throw FoveonError.render("denoise cascades must use one colour domain")
        }
        let side = Self.spatialSide(of: stages[0]) ?? 512
        guard stages.dropFirst().allSatisfy({ Self.spatialSide(of: $0).map { $0 == side } ?? true }) else {
            throw FoveonError.render("denoise cascades must use one tile size")
        }
        let tile = max(64, side)
        let overlap = max(16, tile / 4)

        self.stages = stages
        self.colorSpace = domain.colorSpace
        self.tile = tile
        self.overlap = overlap
        self.win = (0..<tile).map { k in
            max(1e-3, min(Float(min(k, tile - 1 - k)) + 0.5, Float(overlap)) / Float(overlap))
        }
    }

    // models
    static func discover() -> [URL] {
        let fm = FileManager.default
        let dirs = [
            URL(fileURLWithPath: fm.currentDirectoryPath),
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ].compactMap { $0 }
        let bases = ["FoveonJiT", "JiTDenoiser", "Denoiser", "Restormer", "NAFNet"]
        let names = bases.flatMap { ["\($0).mlmodelc", "\($0).mlpackage", "\($0).mlmodel"] }
        let url = dirs.lazy
            .flatMap { dir in names.map(dir.appendingPathComponent) }
            .first { fm.fileExists(atPath: $0.path) }
        return url.map { [$0] } ?? []
    }

    /// Scene-linear → scene-linear. `strength` 0…1 cross-fades to the input;
    /// `ensemble` enables 8-way D4 self-ensemble.
    ///
    /// Tiles overlap and blend with a separable linear taper (flat centre, ramp
    /// across the overlap), accumulating into one buffer — seams dissolve and
    /// peak memory is bounded to a single image. Models are run in their declared
    /// colour domain: `srgb` by default for legacy restoration nets, or `linear`
    /// for a custom raw-domain JiT exported with `foveon.domain=linear`
    /// 
    /// well I hope claude got this one right, it didn't get the rest
    func denoise(_ linear: CIImage, context: CIContext, strength: Float, ensemble: Bool, time: Float) -> CIImage {
        let s = max(0, min(1, strength))
        guard s > 0.001 else { return linear }
        let extent = linear.extent.integral
        // Check for an infinite extent before Int(_:), which traps on ∞/NaN.
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return linear }
        let w = Int(extent.width), h = Int(extent.height)
        let clamped = linear.clampedToExtent()
        let step = max(1, tile - overlap)
        let conditioning = timeFeatures(time)

        var acc = Data(count: w * h * 16)   // RGBAf: RGB = Σ weight·colour, A = Σ weight
        for ty in positions(h, step: step) {
            for tx in positions(w, step: step) {
                // CIImage is Y-up: the tile's top row sits at maxY − ty.
                let bounds = CGRect(x: extent.minX + CGFloat(tx), y: extent.maxY - CGFloat(ty + tile),
                                    width: CGFloat(tile), height: CGFloat(tile))
                let inBuf = renderTile(clamped, rect: bounds, context: context)
                var outBuf: [Float]
                if ensemble {
                    outBuf = ensemblePredict(inBuf, timeFeatures: conditioning)
                } else {
                    outBuf = predict(inBuf, timeFeatures: conditioning)
                }
                matchDC(&outBuf, to: inBuf)   // a denoiser must not recolour a region
                splat(outBuf, tx: tx, ty: ty, w: w, h: h, acc: &acc)
            }
        }

        let clean = resolve(&acc, w: w, h: h).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return s >= 0.999 ? clean : clean.applyingFilter("CIDissolveTransition", parameters: [
            "inputTargetImage": linear, kCIInputTimeKey: 1 - s,
        ])
    }

    // MARK: Model description

    private static func stage(for model: MLModel) throws -> Stage {
        let desc = model.modelDescription
        let inputs = desc.inputDescriptionsByName.filter { $0.value.type == .multiArray }
        guard let image = inputs.first(where: { isImageTensor($0.value) }) else {
            throw FoveonError.render("denoise model needs an NCHW image MultiArray input")
        }
        let imageName = image.key
        let time = inputs
            .filter { $0.key != imageName }
            .first { isTimeTensor(name: $0.key, description: $0.value) }

        let outputs = desc.outputDescriptionsByName.filter { $0.value.type == .multiArray }
        guard let output = outputs.first(where: { isRestoredImageTensor($0.value) }) else {
            throw FoveonError.render("denoise model needs an NCHW/CHW RGB MultiArray output")
        }

        let metadata = desc.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String]
        let domain = Domain(metadata: metadata?["foveon.domain"] ?? metadata?["domain"])
        let timeConstraint = time?.value.multiArrayConstraint
        return Stage(
            model: model,
            imageInput: imageName,
            timeInput: time?.key,
            timeShape: timeConstraint?.shape ?? [1 as NSNumber],
            timeType: timeConstraint?.dataType ?? .float32,
            output: output.key,
            domain: domain
        )
    }

    private static func isImageTensor(_ d: MLFeatureDescription) -> Bool {
        guard let shape = d.multiArrayConstraint?.shape, shape.count == 4 else { return false }
        let batch = shape[0].intValue
        let channels = shape[1].intValue
        let height = shape[2].intValue
        let width = shape[3].intValue
        return (batch == 1 || batch <= 0)
            && channels == 3
            && (height == width || height <= 0 || width <= 0)
    }

    private static func isRestoredImageTensor(_ d: MLFeatureDescription) -> Bool {
        guard let shape = d.multiArrayConstraint?.shape else { return false }
        switch shape.count {
        case 3:
            let channels = shape[0].intValue
            let height = shape[1].intValue
            let width = shape[2].intValue
            return channels == 3 && (height == width || height <= 0 || width <= 0)
        case 4:
            let batch = shape[0].intValue
            let channels = shape[1].intValue
            let height = shape[2].intValue
            let width = shape[3].intValue
            return (batch == 1 || batch <= 0)
                && channels == 3
                && (height == width || height <= 0 || width <= 0)
        default:
            return false
        }
    }

    private static func isTimeTensor(name: String, description d: MLFeatureDescription) -> Bool {
        let lower = name.lowercased()
        if ["t", "time", "sigma", "noise", "noise_level", "denoise_time"].contains(lower) { return true }
        let elements = d.multiArrayConstraint?.shape.reduce(1) { $0 * max(1, $1.intValue) } ?? Int.max
        return elements <= 16
    }

    private static func spatialSide(of stage: Stage) -> Int? {
        let shape = stage.model.modelDescription.inputDescriptionsByName[stage.imageInput]?.multiArrayConstraint?.shape
        guard let height = shape?[2].intValue, let width = shape?[3].intValue,
              height == width, width > 0 else { return nil }
        return width
    }

    // MARK: Tiling

    /// Tile origins covering `0..<length`; the last is pinned to `length-tile`
    /// so every tile is full-size (overlapping a little more at the edge).
    private func positions(_ length: Int, step: Int) -> [Int] {
        guard length > tile else { return [0] }
        var p = Array(stride(from: 0, through: length - tile, by: step))
        if p.last != length - tile { p.append(length - tile) }
        return p
    }

    /// Render a tile to interleaved RGBA float in the model's colour domain.
    private func renderTile(_ image: CIImage, rect: CGRect, context: CIContext) -> [Float] {
        let count = tile * tile * 4
        return [Float](unsafeUninitializedCapacity: count) { buf, initializedCount in
            context.render(image, toBitmap: buf.baseAddress!, rowBytes: tile * 16,
                           bounds: rect, format: .RGBAf, colorSpace: colorSpace)
            initializedCount = count
        }
    }

    /// Restore each channel's tile mean to the input's. Global-pooling or
    /// attention-heavy restorers can drift a tile's average colour; re-centring
    /// is a cheap local-statistics fix that removes per-tile colour casts.
    private func matchDC(_ out: inout [Float], to inp: [Float]) {
        let plane = vDSP_Length(tile * tile)
        out.withUnsafeMutableBufferPointer { o in
            inp.withUnsafeBufferPointer { i in
                for c in 0..<3 {
                    var mi: Float = 0, mo: Float = 0
                    vDSP_meanv(i.baseAddress! + c, 4, &mi, plane)
                    vDSP_meanv(o.baseAddress! + c, 4, &mo, plane)
                    var d = mi - mo
                    vDSP_vsadd(o.baseAddress! + c, 4, &d, o.baseAddress! + c, 4, plane)
                }
            }
        }
    }

    /// Accumulate a denoised tile into the image buffers with feather weights.
    private func splat(_ outBuf: [Float], tx: Int, ty: Int, w: Int, h: Int, acc: inout Data) {
        let rowsInBounds = min(tile, h - ty)
        let colsInBounds = min(tile, w - tx)
        outBuf.withUnsafeBufferPointer { src in
            acc.withUnsafeMutableBytes { rawAcc in
                win.withUnsafeBufferPointer { winPtr in
                    let a = rawAcc.bindMemory(to: Float.self).baseAddress!, s = src.baseAddress!, wn = winPtr.baseAddress!
                    for k in 0..<rowsInBounds {
                        let wy = wn[k]
                        let srcRow = k * tile * 4
                        let dstRow = (ty + k) * w + tx
                        for j in 0..<colsInBounds {
                            let g = wy * wn[j]
                            let si = srcRow + j * 4
                            let di = (dstRow + j) * 4
                            a[di]     += g * s[si]
                            a[di + 1] += g * s[si + 1]
                            a[di + 2] += g * s[si + 2]
                            a[di + 3] += g
                        }
                    }
                }
            }
        }
    }

    /// Normalise the weighted sums into a CIImage tagged with the same domain in
    /// which the model was run, so Core Image converts it back to the pipeline's
    /// scene-linear working space correctly.
    private func resolve(_ acc: inout Data, w: Int, h: Int) -> CIImage {
        let count = w * h
        acc.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            for i in 0..<count {
                let o = i * 4
                let inv = 1 / max(p[o + 3], 1e-6)
                p[o]     *= inv
                p[o + 1] *= inv
                p[o + 2] *= inv
                p[o + 3] = 1
            }
        }
        // `acc` already holds the RGBAf bytes; hand it straight to CIImage (Data
        // is copy-on-write and is not mutated after this) rather than copying it.
        return CIImage(bitmapData: acc, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                       format: .RGBAf, colorSpace: colorSpace)
    }

    // MARK: Inference

    /// Interleaved RGBA → planar CHW → cascade → interleaved RGBA. BLAS does the
    /// strided de/interleave once; stages chain planar with no repack between.
    private func predict(_ inter: [Float], timeFeatures: [TimeFeature?]) -> [Float] {
        let plane = tile * tile, n = Int32(plane)
        guard let input = try? MLMultiArray(shape: [1, 3, tile, tile] as [NSNumber], dataType: .float32) else { return inter }
        let dst = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        inter.withUnsafeBufferPointer { src in
            for c in 0..<3 { cblas_scopy(n, src.baseAddress! + c, 4, dst + c * plane, 1) }
        }

        var feature: MLMultiArray = input
        for i in stages.indices {
            let stage = stages[i]
            var dict = [stage.imageInput: MLFeatureValue(multiArray: feature)]
            if let timeFeature = timeFeatures[i] { dict[timeFeature.name] = timeFeature.value }
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
                  let out = try? stage.model.prediction(from: provider),
                  let o = out.featureValue(for: stage.output)?.multiArrayValue
            else { return inter }
            feature = o
        }
        return interleave(feature, plane: plane, n: n)
    }

    private func timeFeatures(_ value: Float) -> [TimeFeature?] {
        stages.map { stage in
            guard let name = stage.timeInput,
                  let array = timeArray(for: stage, value: value)
            else { return nil }
            return (name, MLFeatureValue(multiArray: array))
        }
    }

    private func timeArray(for stage: Stage, value: Float) -> MLMultiArray? {
        guard let a = try? MLMultiArray(shape: stage.timeShape, dataType: stage.timeType) else { return nil }
        let v = max(0, min(1, value))
        switch stage.timeType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for i in 0..<a.count { p[i] = v }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: a.count)
            for i in 0..<a.count { p[i] = Double(v) }
        #if arch(arm64)
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
            for i in 0..<a.count { p[i] = Float16(v) }
        #endif
        default:
            // Swift has no Float16 on x86_64
            let boxed = NSNumber(value: v)
            for i in 0..<a.count { a[i] = boxed }
        }
        return a
    }

    /// Planar CHW model output → interleaved RGBA float (alpha lanes stay 1).
    private func interleave(_ o: MLMultiArray, plane: Int, n: Int32) -> [Float] {
        [Float](unsafeUninitializedCapacity: plane * 4) { d, count in
            count = plane * 4
            let base = d.baseAddress!
            // Fill alpha = 1 at stride-4
            var one: Float = 1
            vDSP_vfill(&one, base + 3, 4, vDSP_Length(plane))
            switch o.dataType {
            case .float32:
                let p = o.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
                for c in 0..<3 { cblas_scopy(n, p + c * plane, 1, base + c, 4) }
            case .float16:
                // vImage-convert each contiguous f16 plane to f32, then scatter via BLAS.
                let p = o.dataPointer
                var tmp = [Float](repeating: 0, count: plane)
                tmp.withUnsafeMutableBufferPointer { t in
                    var dst = vImage_Buffer(data: t.baseAddress!, height: 1,
                                            width: vImagePixelCount(plane), rowBytes: plane * 4)
                    for c in 0..<3 {
                        var src = vImage_Buffer(data: p.advanced(by: c * plane * 2), height: 1,
                                                width: vImagePixelCount(plane), rowBytes: plane * 2)
                        vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                        cblas_scopy(n, t.baseAddress!, 1, base + c, 4)
                    }
                }
            default:
                for c in 0..<3 { for i in 0..<plane { base[i * 4 + c] = o[c * plane + i].floatValue } }
            }
        }
    }

    /// D4 self-ensemble: denoise every flip/rotation, undo, average. The eight
    /// group elements are enumerated as (optional reflection) ∘ (0–3 quarter
    /// turns); each transform is one or two vImage block operations.
    private func ensemblePredict(_ inter: [Float], timeFeatures: [TimeFeature?]) -> [Float] {
        var sum = [Float](repeating: 0, count: inter.count)
        let count = vDSP_Length(inter.count)
        for flip in [false, true] {
            for quarter in 0..<4 {
                let transformed = dihedral(inter, quarterTurns: quarter, flip: flip, inverse: false)
                let denoised = predict(transformed, timeFeatures: timeFeatures)
                let restored = dihedral(denoised, quarterTurns: quarter, flip: flip, inverse: true)
                restored.withUnsafeBufferPointer { r in
                    sum.withUnsafeMutableBufferPointer { s in
                        vDSP_vadd(s.baseAddress!, 1, r.baseAddress!, 1, s.baseAddress!, 1, count)
                    }
                }
            }
        }
        var scale = Float(1.0 / 8.0)
        sum.withUnsafeMutableBufferPointer { s in
            vDSP_vsmul(s.baseAddress!, 1, &scale, s.baseAddress!, 1, count)
        }
        return sum
    }

    /// One D4 element on an interleaved RGBA square: horizontal reflection (when
    /// `flip`) then `quarterTurns` 90° rotations. `inverse` applies the exact
    /// inverse — the opposite rotation first, then the reflection.
    private func dihedral(_ src: [Float], quarterTurns: Int, flip: Bool, inverse: Bool) -> [Float] {
        let turns = UInt8(inverse ? (4 - quarterTurns) % 4 : quarterTurns)
        func rotated(_ x: [Float]) -> [Float] {
            guard turns != 0 else { return x }
            var back: [Float] = [0, 0, 0, 0]
            return transformed(x) { s, d in
                vImageRotate90_ARGBFFFF(s, d, turns, &back, vImage_Flags(kvImageNoFlags))
            }
        }
        func reflected(_ x: [Float]) -> [Float] {
            guard flip else { return x }
            return transformed(x) { s, d in
                vImageHorizontalReflect_ARGBFFFF(s, d, vImage_Flags(kvImageNoFlags))
            }
        }
        return inverse ? reflected(rotated(src)) : rotated(reflected(src))
    }

    /// Run one vImage op from an interleaved RGBA tile into a fresh buffer.
    private func transformed(
        _ input: [Float],
        _ apply: (UnsafePointer<vImage_Buffer>, UnsafePointer<vImage_Buffer>) -> vImage_Error
    ) -> [Float] {
        let side = vImagePixelCount(tile)
        let rowBytes = tile * 16
        return input.withUnsafeBufferPointer { s in
            [Float](unsafeUninitializedCapacity: input.count) { d, count in
                count = input.count
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress),
                                        height: side, width: side, rowBytes: rowBytes)
                var dst = vImage_Buffer(data: d.baseAddress, height: side, width: side, rowBytes: rowBytes)
                _ = apply(&src, &dst)
            }
        }
    }
}

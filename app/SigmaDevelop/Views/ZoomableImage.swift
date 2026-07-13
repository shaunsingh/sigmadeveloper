import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Zoomable image

/// Render the visible region sharp on tile zoom
struct ZoomTile {
    let id = UUID()
    let image: CGImage
    /// Unit rect the engine actually rendered (top-left origin) — the overlay
    /// is placed here, exactly on the pixel grid the tile was cut from.
    let region: CGRect
    let isHDR: Bool
    let request: ZoomTileRequest
}

/// Visible region and target pixel long edge for a sharpening tile.
struct ZoomTileRequest: Equatable {
    let region: CGRect
    let longEdge: Int
}

/// Stage geometry and tile policy. All rects live in the fitted image's
/// top-left unit space, matching the engine's region convention.
enum ZoomStageMath {
    /// Ask for a sharper tile once the screen outruns the base preview.
    static let tileTriggerDensity: CGFloat = 1.2
    /// Extra half-viewport rendered on each edge.
    static let tilePadFraction: CGFloat = 0.5
    static let tileMaxLongEdge: CGFloat = 2560

    enum TileDecision: Equatable {
        /// The applied tile still covers the viewport at full density.
        case keepCurrent
        /// The base preview suffices — rescind any tile.
        case rescind
        case request(ZoomTileRequest)
    }

    /// Decide whether the viewport (in fitted-image coordinates) needs a
    /// sharper tile than the applied one provides.
    static func tileDecision(visible: CGRect, fitted: CGSize, imagePixels: CGSize,
                             zoom: CGFloat, displayScale: CGFloat,
                             applied: ZoomTile?) -> TileDecision {
        guard zoom > 1.02, fitted.width > 0, fitted.height > 0,
              imagePixels.width > 0, imagePixels.height > 0, !visible.isEmpty else {
            return .rescind
        }
        let scale = max(displayScale, 1)
        // Screen pixels the region paints vs base-preview pixels backing it.
        let displayedPx = max(visible.width, visible.height) * zoom * scale
        let sourcePx = max(visible.width / fitted.width * imagePixels.width,
                           visible.height / fitted.height * imagePixels.height)
        guard displayedPx > sourcePx * tileTriggerDensity else { return .rescind }

        let visibleUnit = CGRect(x: visible.minX / fitted.width,
                                 y: visible.minY / fitted.height,
                                 width: visible.width / fitted.width,
                                 height: visible.height / fitted.height)
        if let applied,
           applied.region.insetBy(dx: -0.001, dy: -0.001).contains(visibleUnit) {
            let tilePx = CGFloat(max(applied.image.width, applied.image.height))
            let tileScreenPx = max(applied.region.width * fitted.width,
                                   applied.region.height * fitted.height) * zoom * scale
            if tilePx >= tileScreenPx * 0.95 { return .keepCurrent }
        }

        let padded = visible.insetBy(dx: -visible.width * tilePadFraction,
                                     dy: -visible.height * tilePadFraction)
            .intersection(CGRect(origin: .zero, size: fitted))
        let paddedPx = max(padded.width, padded.height) * zoom * scale
        let region = CGRect(x: padded.minX / fitted.width,
                            y: padded.minY / fitted.height,
                            width: padded.width / fitted.width,
                            height: padded.height / fitted.height)
        // The cap can pin a shallow-zoom request below the pixels the base
        // already dedicates to that region (the base renders at native stage
        // pixels and may exceed the tile cap); overlaying it would soften the
        // image. Only request tiles that genuinely out-resolve the base.
        let cappedPx = min(paddedPx.rounded(.up), tileMaxLongEdge)
        let baseRegionPx = max(region.width * imagePixels.width,
                               region.height * imagePixels.height)
        guard cappedPx > baseRegionPx * 1.05 else { return .rescind }
        return .request(ZoomTileRequest(region: region, longEdge: Int(cappedPx)))
    }

    /// Aspect-fit `imageSize` into `bounds` less the stage insets.
    static func fittedSize(for imageSize: CGSize, in bounds: CGSize,
                           insetH: CGFloat, insetV: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let insetX = min(insetH, bounds.width / 2)
        let insetY = min(insetV, bounds.height / 2)
        let available = CGSize(width: max(1, bounds.width - insetX * 2),
                               height: max(1, bounds.height - insetY * 2))
        let imageAspect = imageSize.width / imageSize.height
        let availableAspect = available.width / available.height
        if imageAspect > availableAspect {
            return CGSize(width: available.width, height: available.width / imageAspect)
        } else {
            return CGSize(width: available.height * imageAspect, height: available.height)
        }
    }

    static func pixelSize(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

/// Native pinch-, pan-, and double-tap-zoomable image clipped to its containing box.
#if os(iOS)
struct ZoomableImage: UIViewRepresentable {
    let image: CGImage
    /// Only opt into the display's extended range when the render is actually an
    /// HDR/EDR image — otherwise an ordinary SDR preview would be shown boosted.
    var isHDR: Bool = false
    var tile: ZoomTile? = nil
    var insetH: CGFloat = 0
    var insetV: CGFloat = 0
    var onTileNeeded: ((ZoomTileRequest?) -> Void)? = nil
    var onBackSwipe: (() -> Void)? = nil

    private let maxScale: CGFloat = 6
    private let doubleTapScale: CGFloat = 2.5

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.delegate = context.coordinator
        // Photos-style feel: crisp stops when panning a zoomed image.
        scrollView.decelerationRate = .fast
        scrollView.maximumZoomScale = maxScale
        scrollView.minimumZoomScale = 1
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(context.coordinator.imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView

        // SwiftUI doesn't re-invoke `updateUIView` for a pure bounds change, so the
        // first non-zero layout (the scroll view starts at .zero) is reported here —
        // without this the image stays unsized until some state forces an update.
        let coordinator = context.coordinator
        scrollView.onLayout = { [weak scrollView] size in
            guard let scrollView, size.width > 0, size.height > 0,
                  coordinator.boundsSize != size else { return }
            coordinator.boundsSize = size
            coordinator.layoutContent(in: scrollView, resetZoom: false)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        let imageChanged = coordinator.currentImage !== image
        let imageSize = ZoomStageMath.pixelSize(of: image)
        let imageSizeChanged = coordinator.imageSize != imageSize
        let boundsChanged = coordinator.boundsSize != scrollView.bounds.size
        let insetChanged = coordinator.insetH != insetH || coordinator.insetV != insetV

        coordinator.insetH = insetH
        coordinator.insetV = insetV
        coordinator.maxScale = maxScale
        coordinator.doubleTapScale = doubleTapScale
        coordinator.onTileNeeded = onTileNeeded
        coordinator.imageView.preferredImageDynamicRange = isHDR ? .high : .standard

        if imageChanged {
            coordinator.currentImage = image
            coordinator.imageView.image = UIImage(cgImage: image)
        }
        let resolvedTile = imageChanged ? nil : tile
        if coordinator.appliedTile?.id != resolvedTile?.id {
            coordinator.setTile(resolvedTile)
        }
        if imageChanged {
            DispatchQueue.main.async { [weak coordinator] in coordinator?.maybeRequestTile() }
        }

        guard imageSizeChanged || boundsChanged || insetChanged else {
            coordinator.centerContent(in: scrollView)
            return
        }

        // A sharper render of the same photo
        let oldSize = coordinator.imageSize
        let aspectChanged = oldSize.height <= 0 || imageSize.height <= 0
            || abs(oldSize.width / oldSize.height - imageSize.width / imageSize.height) > 0.001

        coordinator.imageSize = imageSize
        coordinator.boundsSize = scrollView.bounds.size
        coordinator.layoutContent(in: scrollView, resetZoom: imageSizeChanged && aspectChanged)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        private let tileView = UIImageView()
        weak var scrollView: UIScrollView?

        var boundsSize: CGSize = .zero
        var currentImage: CGImage?
        var doubleTapScale: CGFloat = 2.5
        var imageSize: CGSize = .zero
        var maxScale: CGFloat = 4
        var insetH: CGFloat = 0
        var insetV: CGFloat = 0
        var onTileNeeded: ((ZoomTileRequest?) -> Void)?
        private(set) var appliedTile: ZoomTile?

        /// zoom in overshoot corners
        private static let zoomedCornerFraction: CGFloat = 0.22

        override init() {
            super.init()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = true
            // The tile's frame is fill region
            tileView.contentMode = .scaleToFill
            tileView.isHidden = true
            imageView.addSubview(tileView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            maybeRequestTile()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { maybeRequestTile() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            maybeRequestTile()
        }

        func layoutContent(in scrollView: UIScrollView, resetZoom: Bool) {
            guard imageView.image != nil, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else {
                return
            }

            let fittedSize = ZoomStageMath.fittedSize(for: imageSize, in: scrollView.bounds.size,
                                                      insetH: insetH, insetV: insetV)
            // Same base geometry (a sharper render of the same layout): skip the
            // re-base entirely so swapping pixels never touches scroll state.
            if !resetZoom,
               abs(imageView.bounds.width - fittedSize.width) < 0.5,
               abs(imageView.bounds.height - fittedSize.height) < 0.5 {
                scrollView.maximumZoomScale = maxScale
                centerContent(in: scrollView)
                return
            }

            // `frame` is the post-zoom-transform box: assigning it while zoomed
            // silently shrinks the base geometry (zoomScale stays high while the
            // image reads as fitted, so the next double-tap "toggles" outward).
            // Neutralise the zoom, re-base the geometry, then restore
            UIView.performWithoutAnimation {
                let zoomScale = scrollView.zoomScale
                scrollView.zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: fittedSize)
                scrollView.contentSize = fittedSize
                scrollView.minimumZoomScale = 1
                scrollView.maximumZoomScale = maxScale
                scrollView.zoomScale = resetZoom ? 1 : min(max(zoomScale, 1), maxScale)
                layoutTile()
                centerContent(in: scrollView)
            }
        }

        func centerContent(in scrollView: UIScrollView) {
            // Breathing room grows with zoom (fully by 1.5×) so a corner can be
            // pulled well clear of the stage edge.
            let t = min(max((scrollView.zoomScale - 1) / 0.5, 0), 1)
            let padH = insetH + (max(scrollView.bounds.width * Self.zoomedCornerFraction, insetH) - insetH) * t
            let padV = insetV + (max(scrollView.bounds.height * Self.zoomedCornerFraction, insetV) - insetV) * t
            // Floor the centring insets at the stage insets for zoom
            let floorH = min(padH, scrollView.bounds.width / 2)
            let floorV = min(padV, scrollView.bounds.height / 2)
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, floorH)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, floorV)
            scrollView.contentInset = UIEdgeInsets(top: verticalInset,
                                                  left: horizontalInset,
                                                  bottom: verticalInset,
                                                  right: horizontalInset)
        }

        // MARK: Deep-zoom tiles

        func setTile(_ tile: ZoomTile?) {
            appliedTile = tile
            tileView.image = tile.map { UIImage(cgImage: $0.image) }
            tileView.preferredImageDynamicRange = (tile?.isHDR ?? false) ? .high : .standard
            tileView.isHidden = tile == nil
            layoutTile()
        }

        private func layoutTile() {
            guard let region = appliedTile?.region else { return }
            let base = imageView.bounds.size
            tileView.frame = CGRect(x: region.minX * base.width,
                                    y: region.minY * base.height,
                                    width: region.width * base.width,
                                    height: region.height * base.height)
        }

        /// Report a padded region whenever the displayed size outruns the base
        /// preview's pixels — and rescind (nil) when it no longer does. While the
        /// viewport stays inside the applied tile at full density, nothing is
        /// emitted, so panning never swaps or drops a tile that still covers.
        func maybeRequestTile() {
            guard let scrollView, let onTileNeeded else { return }
            guard !scrollView.isZooming, !scrollView.isDragging, !scrollView.isDecelerating else { return }
            let fitted = imageView.bounds.size
            let visible = scrollView.convert(scrollView.bounds, to: imageView)
                .intersection(CGRect(origin: .zero, size: fitted))
            switch ZoomStageMath.tileDecision(
                visible: visible, fitted: fitted, imagePixels: imageSize,
                zoom: scrollView.zoomScale,
                displayScale: scrollView.traitCollection.displayScale,
                applied: appliedTile
            ) {
            case .keepCurrent: break
            case .rescind: onTileNeeded(nil)
            case .request(let request): onTileNeeded(request)
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let targetScale = min(doubleTapScale, scrollView.maximumZoomScale)

            // Treat a near-fitted layout as not zoomed. Tray resizes can leave UIKit at a
            // small fractional scale above minimum; double-tap should still zoom in there.
            if scrollView.zoomScale >= targetScale * 0.85 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let location = recognizer.location(in: imageView)
            let clampedLocation = CGPoint(x: min(max(location.x, imageView.bounds.minX), imageView.bounds.maxX),
                                          y: min(max(location.y, imageView.bounds.minY), imageView.bounds.maxY))
            let zoomSize = CGSize(width: scrollView.bounds.width / targetScale,
                                  height: scrollView.bounds.height / targetScale)
            let zoomOrigin = CGPoint(x: clampedLocation.x - zoomSize.width / 2,
                                     y: clampedLocation.y - zoomSize.height / 2)
            scrollView.zoom(to: CGRect(origin: zoomOrigin, size: zoomSize), animated: true)
        }
    }
}

/// Scroll view that surfaces geometry changes UIKit performs outside of SwiftUI's
/// `updateUIView` cycle, so the image can lay out the first time it gets a real size.
final class ZoomScrollView: UIScrollView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

#elseif os(macOS)

/// Native AppKit scroll/magnification stage. `NSScrollView` supplies trackpad
/// momentum, rubber-banding, accessibility, and system magnification physics;
/// only image fitting and tile placement are custom.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage
    var isHDR: Bool = false
    var tile: ZoomTile? = nil
    var insetH: CGFloat = 0
    var insetV: CGFloat = 0
    var onTileNeeded: ((ZoomTileRequest?) -> Void)? = nil
    var onBackSwipe: (() -> Void)? = nil

    private let maxScale: CGFloat = 6
    private let doubleClickScale: CGFloat = 2.5

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MacZoomScrollView {
        let scrollView = MacZoomScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = maxScale
        // Photo canvases are genuinely two-dimensional; AppKit otherwise
        // locks each trackpad gesture to its initially predominant axis.
        scrollView.usesPredominantAxisScrolling = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .automatic
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = context.coordinator.canvas
        context.coordinator.scrollView = scrollView
        scrollView.onInteractionEnded = { [weak coordinator = context.coordinator] in
            coordinator?.maybeRequestTile()
        }
        scrollView.onBackSwipe = onBackSwipe

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)

        let coordinator = context.coordinator
        scrollView.onLayout = { [weak scrollView] size in
            guard let scrollView, size.width > 0, size.height > 0,
                  coordinator.boundsSize != size else { return }
            coordinator.boundsSize = size
            coordinator.layoutContent(in: scrollView, resetZoom: false)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: MacZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        let imageChanged = coordinator.currentImage !== image
        let imageSize = ZoomStageMath.pixelSize(of: image)
        let imageSizeChanged = coordinator.imageSize != imageSize
        let boundsChanged = coordinator.boundsSize != scrollView.bounds.size
        let insetChanged = coordinator.insetH != insetH || coordinator.insetV != insetV

        coordinator.insetH = insetH
        coordinator.insetV = insetV
        coordinator.maxScale = maxScale
        coordinator.doubleClickScale = doubleClickScale
        coordinator.onTileNeeded = onTileNeeded
        scrollView.onBackSwipe = onBackSwipe
        coordinator.imageView.preferredImageDynamicRange = isHDR ? .high : .standard

        if imageChanged {
            // Do not expose AppKit's stale pre-layout frame for one display
            // pass. The image becomes visible only after its fitted geometry
            // and centred clip bounds are committed below.
            coordinator.imageView.isHidden = true
            coordinator.currentImage = image
            coordinator.imageView.image = NSImage(cgImage: image, size: imageSize)
        }
        let resolvedTile = imageChanged ? nil : tile
        if coordinator.appliedTile?.id != resolvedTile?.id {
            coordinator.setTile(resolvedTile)
        }

        let oldSize = coordinator.imageSize
        let aspectChanged = oldSize.height <= 0 || imageSize.height <= 0
            || abs(oldSize.width / oldSize.height - imageSize.width / imageSize.height) > 0.001
        coordinator.imageSize = imageSize
        coordinator.boundsSize = scrollView.bounds.size

        if imageSizeChanged || boundsChanged || insetChanged {
            coordinator.layoutContent(in: scrollView, resetZoom: imageSizeChanged && aspectChanged)
        } else if imageChanged {
            coordinator.imageView.isHidden = false
            DispatchQueue.main.async { [weak coordinator] in coordinator?.maybeRequestTile() }
        }
    }

    final class Coordinator: NSObject {
        let canvas = FlippedCanvas()
        let imageView = NSImageView()
        private let tileView = NSImageView()
        weak var scrollView: NSScrollView?

        var boundsSize: CGSize = .zero
        var currentImage: CGImage?
        var doubleClickScale: CGFloat = 2.5
        var imageSize: CGSize = .zero
        var maxScale: CGFloat = 6
        var insetH: CGFloat = 0
        var insetV: CGFloat = 0
        var onTileNeeded: ((ZoomTileRequest?) -> Void)?
        private(set) var appliedTile: ZoomTile?

        override init() {
            super.init()
            imageView.imageScaling = .scaleAxesIndependently
            tileView.imageScaling = .scaleAxesIndependently
            tileView.isHidden = true
            canvas.addSubview(imageView)
            canvas.addSubview(tileView)
        }

        func layoutContent(in scrollView: NSScrollView, resetZoom: Bool) {
            guard imageView.image != nil, scrollView.bounds.width > 0,
                  scrollView.bounds.height > 0 else { return }
            let fitted = ZoomStageMath.fittedSize(for: imageSize, in: scrollView.bounds.size,
                                                   insetH: insetH, insetV: insetV)
            if !resetZoom, abs(canvas.frame.width - fitted.width) < 0.5,
               abs(canvas.frame.height - fitted.height) < 0.5 { return }

            let oldMagnification = scrollView.magnification
            let visibleCenter = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
            let normalizedCenter = CGPoint(
                x: canvas.bounds.width > 0 ? visibleCenter.x / canvas.bounds.width : 0.5,
                y: canvas.bounds.height > 0 ? visibleCenter.y / canvas.bounds.height : 0.5)
            scrollView.magnification = 1
            canvas.frame = CGRect(origin: .zero, size: fitted)
            imageView.frame = canvas.bounds
            layoutTile()
            scrollView.minMagnification = 1
            scrollView.maxMagnification = maxScale
            if resetZoom {
                scrollView.magnification = 1
            } else {
                let center = CGPoint(x: normalizedCenter.x * fitted.width,
                                     y: normalizedCenter.y * fitted.height)
                scrollView.setMagnification(min(max(oldMagnification, 1), maxScale),
                                            centeredAt: center)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
            imageView.isHidden = false
        }

        func setTile(_ tile: ZoomTile?) {
            appliedTile = tile
            tileView.image = tile.map { NSImage(cgImage: $0.image, size: $0.region.size) }
            tileView.preferredImageDynamicRange = (tile?.isHDR ?? false) ? .high : .standard
            tileView.isHidden = tile == nil
            layoutTile()
        }

        private func layoutTile() {
            guard let region = appliedTile?.region else { return }
            let base = canvas.bounds.size
            tileView.frame = CGRect(x: region.minX * base.width,
                                    y: region.minY * base.height,
                                    width: region.width * base.width,
                                    height: region.height * base.height)
        }

        func maybeRequestTile() {
            guard let scrollView, let onTileNeeded else { return }
            let fitted = canvas.bounds.size
            let visible = canvas.visibleRect.intersection(canvas.bounds)
            switch ZoomStageMath.tileDecision(
                visible: visible, fitted: fitted, imagePixels: imageSize,
                zoom: scrollView.magnification,
                displayScale: scrollView.window?.backingScaleFactor ?? 1,
                applied: appliedTile
            ) {
            case .keepCurrent: break
            case .rescind: onTileNeeded(nil)
            case .request(let request): onTileNeeded(request)
            }
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let scrollView else { return }
            let target = min(doubleClickScale, scrollView.maxMagnification)
            if scrollView.magnification >= target * 0.85 {
                scrollView.animator().magnification = scrollView.minMagnification
                onTileNeeded?(nil)
                return
            }
            let location = recognizer.location(in: canvas)
            scrollView.setMagnification(target, centeredAt: location)
            maybeRequestTile()
        }
    }
}

final class FlippedCanvas: NSView {
    override var isFlipped: Bool { true }
}

/// Keep a fitted document centered while letting `NSScrollView` pan normally
/// once magnification makes it larger than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        if documentView.frame.width < constrained.width {
            constrained.origin.x = -(constrained.width - documentView.frame.width) / 2
        }
        if documentView.frame.height < constrained.height {
            constrained.origin.y = -(constrained.height - documentView.frame.height) / 2
        }
        return constrained
    }
}

final class MacZoomScrollView: NSScrollView {
    var onLayout: ((CGSize) -> Void)?
    var onInteractionEnded: (() -> Void)?
    var onBackSwipe: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?(bounds.size)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if event.phase == .ended || event.phase == .cancelled { onInteractionEnded?() }
    }

    override func scrollWheel(with event: NSEvent) {
        if magnification <= minMagnification + 0.001,
           event.phase == .began,
           event.scrollingDeltaX > 0,
           abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
           NSEvent.isSwipeTrackingFromScrollEventsEnabled,
           let onBackSwipe {
            event.trackSwipeEvent(options: .lockDirection,
                                  dampenAmountThresholdMin: -1, max: 1) {
                amount, phase, _, _ in
                if phase == .ended, amount >= 0.3 { onBackSwipe() }
            }
            return
        }
        super.scrollWheel(with: event)
        if event.phase == .ended || event.momentumPhase == .ended { onInteractionEnded?() }
    }
}

#endif

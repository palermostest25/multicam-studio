import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// How one source appears in the output frame.
public struct LayerStyle: Sendable, Hashable {
    public var framing: Framing
    public var focus: [Double]?            // automatic crop centre from picture analysis
    public var orientedSize: CGSize
    public var orientation: CGImagePropertyOrientation
    public var isHDR: Bool

    public init(framing: Framing, focus: [Double]?, info: MediaInfo) {
        self.framing = framing
        self.focus = focus
        orientedSize = info.orientedSize
        orientation = LayerStyle.orientation(of: info.transform)
        isHDR = info.isHDR
    }

    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        // Camera rotation metadata (preferredTransform) to an EXIF orientation.
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.d == -1 { return .down }
        if t.a == -1 && t.d == 1 { return .upMirrored }
        return .up
    }

    public var centre: (Double, Double) {
        if framing.auto, let focus, focus.count == 2 { return (focus[0], focus[1]) }
        return (framing.x, framing.y)
    }

    /// Crop rectangle in oriented, top-left pixel coordinates (same maths as the FFmpeg engine).
    public func cropRect(output: CGSize) -> CGRect {
        let w = orientedSize.width, h = orientedSize.height
        let cw = max(2, min(w, h * output.width / output.height) / framing.zoom)
        let ch = max(2, cw * output.height / output.width)
        let (cx, cy) = centre
        let x = max(0, min(w - cw, w * cx - cw / 2))
        let y = max(0, min(h - ch, h * cy - ch / 2))
        return CGRect(x: x, y: y, width: cw, height: ch)
    }
}

/// One stretch of the output with a single source (or black).
final class MulticamInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID?
    let style: LayerStyle?
    let look: Look
    let totalDuration: Double

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID?, style: LayerStyle?, look: Look, totalDuration: Double) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.style = style
        self.look = look
        self.totalDuration = totalDuration
        requiredSourceTrackIDs = trackID.map { [NSNumber(value: $0)] }
    }
}

/// GPU frame compositor: orientation, crop/fit, look and fades in one Core Image pass.
final class MulticamCompositor: NSObject, AVVideoCompositing {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!,
            .cacheIntermediates: false,
            .name: "Multicam Studio",
        ]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "multicam.compositor", qos: .userInitiated)
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
         ], kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }

    var supportsHDRSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? MulticamInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: MulticamError("Could not prepare a video frame."))
                return
            }
            let size = request.renderContext.size
            var image = Self.frame(request: request, instruction: instruction, size: size)
            image = Effects.apply(instruction.look, to: image, size: size,
                                  time: request.compositionTime.seconds, total: instruction.totalDuration)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size),
                                colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync { cancelled = true }
        queue.async { [self] in cancelled = false }
    }

    static func frame(request: AVAsynchronousVideoCompositionRequest, instruction: MulticamInstruction, size: CGSize) -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        guard let id = instruction.trackID, let style = instruction.style,
              let buffer = request.sourceFrame(byTrackID: id) else { return black }
        return Framer.compose(CIImage(cvPixelBuffer: buffer), style: style, size: size).composited(over: black)
    }
}

/// Places an oriented camera picture into the output frame.
public enum Framer {
    public static func compose(_ source: CIImage, style: LayerStyle, size: CGSize) -> CIImage {
        var image = source.oriented(style.orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if style.isHDR { image = toneMap(image) }
        let w = image.extent.width, h = image.extent.height
        let out = CGRect(origin: .zero, size: size)
        switch style.framing.mode {
        case .crop:
            var rect = style.cropRect(output: size)
            // The style was measured on the oriented size; adapt if decoding differs.
            if abs(w - style.orientedSize.width) > 2 || abs(h - style.orientedSize.height) > 2 {
                let sx = w / max(1, style.orientedSize.width), sy = h / max(1, style.orientedSize.height)
                rect = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            }
            let ciRect = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
            let scale = size.width / rect.width
            return scaled(image.cropped(to: ciRect).transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY)),
                          by: scale).cropped(to: out)
        case .fit, .pad:
            let scale = min(size.width / w, size.height / h)
            let fg = scaled(image, by: scale)
            let placed = fg.transformed(by: CGAffineTransform(translationX: (size.width - fg.extent.width) / 2,
                                                              y: (size.height - fg.extent.height) / 2))
            if style.framing.mode == .pad { return placed }
            // Blurred, slightly darkened fill instead of black bars.
            let fill = max(size.width / w, size.height / h)
            let small = image.transformed(by: CGAffineTransform(scaleX: fill / 8, y: fill / 8))
            let bg = small.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(size.width) / 8 * 0.035)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.06, kCIInputSaturationKey: 1.1])
                .cropped(to: small.extent)
                .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            let centred = bg.transformed(by: CGAffineTransform(translationX: (size.width - bg.extent.width) / 2,
                                                               y: (size.height - bg.extent.height) / 2))
            return placed.composited(over: centred).cropped(to: out)
        }
    }

    static func scaled(_ image: CIImage, by scale: Double) -> CIImage {
        if scale < 0.75 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(scale)
            f.aspectRatio = 1
            return f.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func toneMap(_ image: CIImage) -> CIImage {
        if #available(macOS 15.0, *), CIFilter(name: "CIToneMapHeadroom") != nil {
            return image.applyingFilter("CIToneMapHeadroom", parameters: [
                "inputSourceHeadroom": max(1, image.contentHeadroom),
                "inputTargetHeadroom": 1.0,
            ])
        }
        return image
    }
}

/// Colour looks and fades (the browser version's Effects, applied while rendering).
public enum Effects {
    /// Moving film grain: random noise, shifted every frame, mixed in lightly.
    static func grain(_ image: CIImage, size: CGSize, time: Double, amount: CGFloat) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let frame = Int(time * 24)
        let shift = CGAffineTransform(translationX: CGFloat((frame * 7919) % 997), y: CGFloat((frame * 104729) % 991))
        let grey = noise.transformed(by: shift).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount),
        ]).cropped(to: CGRect(origin: .zero, size: size))
        return grey.composited(over: image).applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -amount / 2])
    }

    public static func apply(_ look: Look, to input: CIImage, size: CGSize, time: Double, total: Double) -> CIImage {
        var image = input
        func matrix(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        func controls(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
            ])
        }
        switch look.style {
        case .none: break
        case .warm: matrix(1.05, 1.0, 0.94)
        case .cool: matrix(0.96, 0.99, 1.06)
        case .mono: controls(saturation: 0)
        case .vintage: controls(brightness: 0.025, contrast: 0.94, saturation: 0.7); matrix(1.04, 1.0, 0.97)
        case .vivid: controls(contrast: 1.08, saturation: 1.22)
        case .noir: controls(brightness: -0.02, contrast: 1.35, saturation: 0)
        case .silver: controls(brightness: 0.03, contrast: 0.85, saturation: 0); matrix(1.0, 1.0, 1.02)
        case .sepia:
            controls(saturation: 0)
            image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        case .super8:
            controls(brightness: 0.03, contrast: 0.88, saturation: 0.75); matrix(1.08, 1.0, 0.86)
            image = grain(image, size: size, time: time, amount: 0.07)
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2),
                kCIInputRadiusKey: hypot(size.width, size.height) / 2 * 0.9,
                kCIInputIntensityKey: 0.9, "inputFalloff": 0.5,
            ])
        case .faded: controls(brightness: 0.06, contrast: 0.8, saturation: 0.8); matrix(1.02, 1.0, 0.96)
        }
        if look.brightness != 0 || look.contrast != 1 || look.saturation != 1 {
            controls(brightness: look.brightness, contrast: look.contrast, saturation: look.saturation)
        }
        if look.vignette {
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2),
                kCIInputRadiusKey: hypot(size.width, size.height) / 2 * 0.95,
                kCIInputIntensityKey: 0.8, "inputFalloff": 0.6,
            ])
        }
        var level = 1.0
        if look.fadeIn > 0 { level = min(level, time / look.fadeIn) }
        if look.fadeOut > 0 { level = min(level, (total - time) / look.fadeOut) }
        if level < 1 {
            let v = CGFloat(max(0, level))
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0),
            ])
        }
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }
}

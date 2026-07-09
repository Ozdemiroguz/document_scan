import CoreImage
import CoreVideo
import Flutter
import UIKit
import Vision
import ImageIO

/// iOS document corner detection for the `document_scan` plugin, backed by
/// Apple's Vision framework (`VNDetectRectanglesRequest`) — zero bundled model,
/// zero added binary. Detects a document as a rectangle and returns its four
/// corners as normalized 0..1 points.
///
/// Channel: `com.oguzhan.document_scan/detector`
///  - `detectFile`  { path }
///  - `detectFrame` { width,height,bytesPerRow,rotation, bytes(BGRA) }
public class DocumentScanPlugin: NSObject, FlutterPlugin {

  private var frameBusy = false
  private let stateQueue = DispatchQueue(label: "com.oguzhan.document_scan.state")
  private let workQueue = DispatchQueue(
    label: "com.oguzhan.document_scan.work", qos: .userInitiated)

  // Downscales each realtime frame before Vision runs, so a full-res (~8 MB at
  // 1080p) per-frame CVPixelBuffer is never allocated and rectangle detection
  // runs at 720px instead of 1080p. Corners are normalized, so the reduced
  // resolution doesn't change the result. Stateful (reused CIContext + pooled
  // buffers); only touched from the serial workQueue, so no extra locking.
  private let downscaler = PixelBufferDownscaler()
  private let frameMaxLongSide = 720

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.oguzhan.document_scan/detector",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DocumentScanPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "detectFile":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
        return
      }
      detectFile(path: path, sensitivity: Sensitivity(args), result: result)

    case "detectFrame":
      guard let args = call.arguments as? [String: Any],
            let bytes = args["bytes"] as? FlutterStandardTypedData,
            let width = args["width"] as? Int,
            let height = args["height"] as? Int,
            let bytesPerRow = args["bytesPerRow"] as? Int,
            let rotation = args["rotation"] as? Int else {
        // yuv420 frames are Android-only; iOS streams BGRA. Missing bgra args =
        // dropped frame, not an error.
        result(nil)
        return
      }
      detectFrame(
        bytes: bytes.data, width: width, height: height,
        bytesPerRow: bytesPerRow, rotation: rotation,
        sensitivity: Sensitivity(args), result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Maps the Dart `DetectionSensitivity` to Vision's confidence / min-size
  /// gates. The two engines have different knobs, so the level is the portable
  /// contract; these are its iOS values.
  enum Sensitivity {
    case strict, balanced, lenient

    init(_ args: [String: Any]) {
      switch args["sensitivity"] as? String {
      case "strict": self = .strict
      case "lenient": self = .lenient
      default: self = .balanced
      }
    }

    var minimumConfidence: VNConfidence {
      switch self {
      case .strict: return 0.7
      case .balanced: return 0.6
      case .lenient: return 0.4
      }
    }
    var minimumSize: Float {
      switch self {
      case .strict: return 0.20
      case .balanced: return 0.15
      case .lenient: return 0.08
      }
    }
  }

  // MARK: - Still image

  private func detectFile(
    path: String, sensitivity: Sensitivity, result: @escaping FlutterResult
  ) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      result(FlutterError(code: "INVALID_IMAGE", message: "Cannot load image", details: nil))
      return
    }
    let orientation = readOrientation(source: source)
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

    let request = Self.makeRectangleRequest(sensitivity) { corners in
      result(corners) // normalized already (Vision returns 0..1), Y-flipped below
    }
    workQueue.async {
      autoreleasepool {
        do { try handler.perform([request]) }
        catch { DispatchQueue.main.async { result(nil) } }
      }
    }
  }

  // MARK: - Realtime frame (BGRA)

  private func detectFrame(
    bytes: Data, width: Int, height: Int, bytesPerRow: Int, rotation: Int,
    sensitivity: Sensitivity, result: @escaping FlutterResult
  ) {
    guard acquireSlot() else { result(nil); return }
    let expected = bytesPerRow * height
    guard bytes.count >= expected else { releaseSlot(); result(nil); return }

    workQueue.async { [weak self] in
      autoreleasepool {
        guard let self = self else { return }
        defer { self.releaseSlot() }
        // Downscale into a small pooled buffer inside the autoreleasepool (the
        // CIContext render produces temporaries). Vision then runs at 720px.
        guard let buffer = self.downscaler.downscale(
          bytes: bytes, width: width, height: height,
          bytesPerRow: bytesPerRow, maxLongSide: self.frameMaxLongSide) else {
          DispatchQueue.main.async { result(nil) }
          return
        }
        let orientation: CGImagePropertyOrientation
        switch rotation {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = .up
        }
        let handler = VNImageRequestHandler(
          cvPixelBuffer: buffer, orientation: orientation, options: [:])
        let request = Self.makeRectangleRequest(sensitivity) { corners in
          result(corners)
        }
        do { try handler.perform([request]) }
        catch { DispatchQueue.main.async { result(nil) } }
      }
    }
  }

  // MARK: - Vision request

  private static func makeRectangleRequest(
    _ sensitivity: Sensitivity,
    _ completion: @escaping ([String: Double]?) -> Void
  ) -> VNDetectRectanglesRequest {
    let request = VNDetectRectanglesRequest { req, error in
      if error != nil {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      guard let obs = (req.results as? [VNRectangleObservation])?.first else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      // Vision: normalized 0..1, bottom-left origin. Flip Y to top-left origin.
      func pt(_ p: CGPoint) -> (Double, Double) {
        (min(max(Double(p.x), 0), 1), min(max(1 - Double(p.y), 0), 1))
      }
      let (tlx, tly) = pt(obs.topLeft)
      let (trx, tryy) = pt(obs.topRight)
      let (brx, bry) = pt(obs.bottomRight)
      let (blx, bly) = pt(obs.bottomLeft)
      let corners: [String: Double] = [
        "topLeftX": tlx, "topLeftY": tly,
        "topRightX": trx, "topRightY": tryy,
        "bottomRightX": brx, "bottomRightY": bry,
        "bottomLeftX": blx, "bottomLeftY": bly,
        // Vision's own detection confidence (0..1). The Dart side prefers this
        // over its geometric heuristic when present.
        "confidence": Double(obs.confidence),
      ]
      DispatchQueue.main.async { completion(corners) }
    }
    // Vision detects rectangles aggressively — with loose thresholds it locks
    // onto tabletops, screen edges, shadows, and low-confidence guesses. The
    // confidence + minimum-size gates come from the requested sensitivity (see
    // Sensitivity); the aspect gate stays fixed to drop extreme slivers like a
    // table edge (0.3 = up to ~3:1) regardless of level.
    request.minimumConfidence = sensitivity.minimumConfidence
    request.minimumSize = sensitivity.minimumSize
    request.maximumObservations = 1
    request.minimumAspectRatio = 0.3
    request.maximumAspectRatio = 1.0
    return request
  }

  // MARK: - Helpers

  private func readOrientation(source: CGImageSource) -> CGImagePropertyOrientation {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let raw = props[kCGImagePropertyOrientation] as? UInt32,
          let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
    return o
  }

  private func acquireSlot() -> Bool {
    stateQueue.sync { if frameBusy { return false }; frameBusy = true; return true }
  }
  private func releaseSlot() {
    stateQueue.sync { frameBusy = false }
  }
}

/// Downscales realtime frame bytes into a small pooled `CVPixelBuffer` before
/// Vision runs, so a full-resolution (~8 MB at 1080p) buffer is never allocated
/// per frame and detection runs at a reduced resolution.
///
/// A single `CIContext` (GPU/Metal-backed, expensive to build) and a
/// `CVPixelBufferPool` are reused across frames — the pool is recreated only
/// when the output dimensions change (i.e. once). Not thread-safe on its own;
/// the plugin only touches it from its serial work queue.
private final class PixelBufferDownscaler {
  private let context: CIContext
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

  init() {
    // No color management — we're scaling raw camera BGRA for detection, not
    // display, so skip the working-space conversions for speed.
    context = CIContext(options: [
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull(),
    ])
  }

  /// Scale a single-plane 32BGRA image into a new BGRA buffer whose long side is
  /// at most `maxLongSide`. Returns nil on failure; copies at full size (still
  /// pooled) if already small enough.
  func downscale(
    bytes: Data, width: Int, height: Int, bytesPerRow: Int, maxLongSide: Int
  ) -> CVPixelBuffer? {
    let longSide = max(width, height)
    let scale = (maxLongSide > 0 && longSide > maxLongSide)
      ? Double(maxLongSide) / Double(longSide) : 1.0
    // Keep dimensions even and non-zero.
    let outW = max(2, (Int(Double(width) * scale) / 2) * 2)
    let outH = max(2, (Int(Double(height) * scale) / 2) * 2)

    guard let output = makeBuffer(width: outW, height: outH) else { return nil }

    // CIImage(bitmapData:) copies the bytes, so `bytes` needn't outlive this.
    let sourceImage = CIImage(
      bitmapData: bytes, bytesPerRow: bytesPerRow,
      size: CGSize(width: width, height: height), format: .BGRA8, colorSpace: nil)
    let scaled = scale == 1.0
      ? sourceImage
      : sourceImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))

    context.render(scaled, to: output)
    return output
  }

  private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || width != poolWidth || height != poolHeight {
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ]
      var newPool: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
        == kCVReturnSuccess, let created = newPool else { return nil }
      pool = created
      poolWidth = width
      poolHeight = height
    }
    guard let pool = pool else { return nil }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
      == kCVReturnSuccess else { return nil }
    return buffer
  }
}

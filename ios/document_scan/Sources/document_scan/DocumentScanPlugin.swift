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
      detectFile(path: path, result: result)

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
        bytesPerRow: bytesPerRow, rotation: rotation, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Still image

  private func detectFile(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      result(FlutterError(code: "INVALID_IMAGE", message: "Cannot load image", details: nil))
      return
    }
    let orientation = readOrientation(source: source)
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

    let request = makeRectangleRequest { corners in
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
    result: @escaping FlutterResult
  ) {
    guard acquireSlot() else { result(nil); return }
    let expected = bytesPerRow * height
    guard bytes.count >= expected else { releaseSlot(); result(nil); return }

    workQueue.async { [weak self] in
      autoreleasepool {
        defer { self?.releaseSlot() }
        guard let buffer = Self.makePixelBuffer(
          bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow) else {
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
        let request = Self.makeRectangleRequest { corners in result(corners) }
        do { try handler.perform([request]) }
        catch { DispatchQueue.main.async { result(nil) } }
      }
    }
  }

  // MARK: - Vision request

  private func makeRectangleRequest(
    _ completion: @escaping ([String: Double]?) -> Void
  ) -> VNDetectRectanglesRequest {
    Self.makeRectangleRequest(completion)
  }

  private static func makeRectangleRequest(
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
      ]
      DispatchQueue.main.async { completion(corners) }
    }
    request.minimumConfidence = 0.3
    request.maximumObservations = 1
    request.minimumAspectRatio = 0.1
    request.maximumAspectRatio = 1.0
    request.minimumSize = 0.05
    return request
  }

  // MARK: - Helpers

  private static func makePixelBuffer(
    bytes: Data, width: Int, height: Int, bytesPerRow: Int
  ) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attrs as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let dest = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let destStride = CVPixelBufferGetBytesPerRow(buffer)
    bytes.withUnsafeBytes { src in
      guard let base = src.baseAddress else { return }
      for row in 0..<height {
        memcpy(dest.advanced(by: row * destStride),
               base.advanced(by: row * bytesPerRow),
               min(bytesPerRow, destStride))
      }
    }
    return buffer
  }

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

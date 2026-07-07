package com.oguzhan.document_scan

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Android edge/corner detection for the `document_scan` plugin, backed by
 * OpenCV. Detects a document as a rectangle (no text required) and returns its
 * four corners as normalized 0..1 points.
 *
 * Channel: `com.oguzhan.document_scan/detector`
 *  - `detectFile`  { path }                        -> corners (pixel-normalized)
 *  - `detectFrame` { width,height,rotation,format, y/u/v or bytes, strides }
 *
 * Pipeline (proven): grayscale -> GaussianBlur -> threshold(TRIANGLE) ->
 * Canny -> dilate -> findContours -> approxPolyDP -> largest convex 4-gon,
 * ordered TL/TR/BR/BL by x+y / y-x extremes.
 */
class DocumentScanPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var opencvReady = false
    @Volatile private var frameBusy = false
    private val emulatorMode by lazy { isEmulator() }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        opencvReady = OpenCVLoader.initLocal()
        if (opencvReady && emulatorMode) {
            // Emulator can crash in OpenCV parallel color conversion.
            Core.setUseOptimized(false)
            Core.setNumThreads(1)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // Release the background thread so it doesn't outlive the engine.
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "detectFile" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "path required", null); return
                }
                if (!opencvReady) { result.success(null); return }
                executor.execute {
                    try {
                        val corners = detectFromFile(path)
                        mainHandler.post { result.success(corners) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("DETECTION_ERROR", e.message, null) }
                    }
                }
            }
            "detectFrame" -> {
                val width = call.argument<Int>("width")
                val height = call.argument<Int>("height")
                val rotation = call.argument<Int>("rotation") ?: 0
                val format = call.argument<String>("format") ?: "bgra"
                if (width == null || height == null) {
                    result.error("INVALID_ARGS", "width/height required", null); return
                }
                if (!opencvReady || frameBusy) { result.success(null); return }
                frameBusy = true
                executor.execute {
                    try {
                        val corners = when (format) {
                            "yuv420" -> {
                                val y = call.argument<ByteArray>("yBytes")
                                val u = call.argument<ByteArray>("uBytes")
                                val v = call.argument<ByteArray>("vBytes")
                                val yStride = call.argument<Int>("yRowStride") ?: width
                                val uvStride = call.argument<Int>("uvRowStride") ?: width
                                val uvPixel = call.argument<Int>("uvPixelStride") ?: 1
                                if (y == null || u == null || v == null) null
                                else detectFromYuv(y, u, v, width, height, yStride, uvStride, uvPixel, rotation)
                            }
                            else -> {
                                val bytes = call.argument<ByteArray>("bytes")
                                val bpr = call.argument<Int>("bytesPerRow") ?: (width * 4)
                                if (bytes == null) null
                                else detectFromBgra(bytes, width, height, bpr, rotation)
                            }
                        }
                        mainHandler.post { result.success(corners) }
                    } catch (e: Exception) {
                        // Per-frame hot path: a failure means "drop this frame"
                        // (null), but log it so a real crash (OOM, OpenCV) isn't
                        // invisible.
                        Log.w(TAG, "Frame detection failed", e)
                        mainHandler.post { result.success(null) }
                    } finally {
                        frameBusy = false
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    // --- Still image (file) : returns PIXEL-normalized corners (0..1 of image) ---

    private fun detectFromFile(path: String): Map<String, Double>? {
        val file = File(path)
        if (!file.exists()) return null
        val bitmap = decodeBitmapWithOrientation(file) ?: return null
        val origW = bitmap.width
        val origH = bitmap.height

        // Detect at the SAME long-side cap as the camera-frame path
        // (DETECTION_MAX_LONG_SIDE). The edge pipeline in findContours uses
        // absolute-pixel operations — Canny thresholds, a fixed 9x9 dilate
        // kernel, and a 10000px^2 min-contour-area filter — so the input
        // resolution changes what counts as a document. Running the file path
        // at 1000px while frames run at 720px meant the same document could be
        // found from the gallery but missed live (or vice versa) — a
        // gallery/camera parity break. Matching the caps makes those absolute
        // thresholds act identically on both paths (and speeds up the file
        // path). Corners are normalized to the original dims below, so the cap
        // never affects output coordinates.
        val maxDim = DETECTION_MAX_LONG_SIDE
        val scale: Double
        val work: Bitmap
        if (origW > maxDim || origH > maxDim) {
            scale = maxDim.toDouble() / maxOf(origW, origH)
            work = Bitmap.createScaledBitmap(bitmap, (origW * scale).toInt(), (origH * scale).toInt(), true)
            bitmap.recycle()
        } else {
            scale = 1.0
            work = bitmap
        }

        val src = Mat()
        Utils.bitmapToMat(work, src)
        work.recycle()
        val quad = try {
            detectBestQuad(src)
        } finally {
            src.release()
        } ?: return null
        val ordered = orderCorners(quad)
        // Normalize to 0..1 of the ORIGINAL image.
        val w = origW.toDouble()
        val h = origH.toDouble()
        val inv = 1.0 / scale
        fun nx(v: Double) = (v * inv / w).coerceIn(0.0, 1.0)
        fun ny(v: Double) = (v * inv / h).coerceIn(0.0, 1.0)
        return mapOf(
            "topLeftX" to nx(ordered[0].x), "topLeftY" to ny(ordered[0].y),
            "topRightX" to nx(ordered[1].x), "topRightY" to ny(ordered[1].y),
            "bottomRightX" to nx(ordered[2].x), "bottomRightY" to ny(ordered[2].y),
            "bottomLeftX" to nx(ordered[3].x), "bottomLeftY" to ny(ordered[3].y),
        )
    }

    // --- Realtime frame paths ---

    private fun detectFromYuv(
        y: ByteArray, u: ByteArray, v: ByteArray, width: Int, height: Int,
        yStride: Int, uvStride: Int, uvPixel: Int, rotation: Int,
    ): Map<String, Double>? {
        val nv21 = toNv21(y, u, v, width, height, yStride, uvStride, uvPixel)
        if (emulatorMode) {
            val bmp = nv21ToBitmap(nv21, width, height) ?: return null
            val mat = Mat()
            Utils.bitmapToMat(bmp, mat)
            bmp.recycle()
            return detectAndNormalize(mat, rotation)
        }
        val yuvMat = Mat(height + height / 2, width, CvType.CV_8UC1)
        yuvMat.put(0, 0, nv21)
        var bgr = Mat()
        Imgproc.cvtColor(yuvMat, bgr, Imgproc.COLOR_YUV2BGR_NV21)
        yuvMat.release()

        // Downscale the BGR Mat during conversion so a full-res (e.g. 1080p
        // ~6MB) Mat is never kept for the per-frame edge pipeline. Corners come
        // out normalized, so the source scale doesn't change the result — this
        // is the main lever for per-frame Large-Object-Space GC pressure.
        val longSide = maxOf(width, height)
        if (longSide > DETECTION_MAX_LONG_SIDE) {
            val scale = DETECTION_MAX_LONG_SIDE.toDouble() / longSide
            val small = Mat()
            Imgproc.resize(
                bgr, small,
                Size(width * scale, height * scale),
                0.0, 0.0, Imgproc.INTER_AREA,
            )
            bgr.release()
            bgr = small
        }
        return detectAndNormalize(bgr, rotation)
    }

    private fun detectFromBgra(
        bytes: ByteArray, width: Int, height: Int, bytesPerRow: Int, rotation: Int,
    ): Map<String, Double>? {
        val mat: Mat
        if (bytesPerRow == width * 4) {
            mat = Mat(height, width, CvType.CV_8UC4)
            mat.put(0, 0, bytes)
        } else {
            val stridePixels = bytesPerRow / 4
            val padded = Mat(height, stridePixels, CvType.CV_8UC4)
            padded.put(0, 0, bytes)
            mat = padded.submat(0, height, 0, width).clone()
            padded.release()
        }
        return detectAndNormalize(mat, rotation)
    }

    private fun detectAndNormalize(mat: Mat, rotation: Int): Map<String, Double>? {
        val rotated = when (rotation) {
            90 -> Mat().also { Core.rotate(mat, it, Core.ROTATE_90_CLOCKWISE); mat.release() }
            180 -> Mat().also { Core.rotate(mat, it, Core.ROTATE_180); mat.release() }
            270 -> Mat().also { Core.rotate(mat, it, Core.ROTATE_90_COUNTERCLOCKWISE); mat.release() }
            else -> mat
        }

        // Cap the long side before the (expensive) Canny/contour pipeline. The
        // YUV path arrives pre-scaled (see detectFromYuv), so this is a no-op
        // there; it's the safety net for the BGRA/emulator paths, which hand in
        // a full-res Mat. Corners are normalized, so the cap doesn't shift them.
        val work = downscaleMat(rotated, DETECTION_MAX_LONG_SIDE)
        if (work != rotated) rotated.release()

        val fw = work.cols().toDouble()
        val fh = work.rows().toDouble()
        val quad = try {
            detectBestQuad(work)
        } finally {
            work.release()
        } ?: return null
        val o = orderCorners(quad)
        return mapOf(
            "topLeftX" to (o[0].x / fw).coerceIn(0.0, 1.0), "topLeftY" to (o[0].y / fh).coerceIn(0.0, 1.0),
            "topRightX" to (o[1].x / fw).coerceIn(0.0, 1.0), "topRightY" to (o[1].y / fh).coerceIn(0.0, 1.0),
            "bottomRightX" to (o[2].x / fw).coerceIn(0.0, 1.0), "bottomRightY" to (o[2].y / fh).coerceIn(0.0, 1.0),
            "bottomLeftX" to (o[3].x / fw).coerceIn(0.0, 1.0), "bottomLeftY" to (o[3].y / fh).coerceIn(0.0, 1.0),
        )
    }

    /** Downscale a Mat so its long side is at most [maxLongSide]; returns the
     *  SAME Mat when already small enough (caller checks identity before
     *  releasing). Corners are normalized, so scale doesn't shift them. */
    private fun downscaleMat(src: Mat, maxLongSide: Int): Mat {
        val longSide = maxOf(src.cols(), src.rows())
        if (longSide <= maxLongSide) return src
        val scale = maxLongSide.toDouble() / longSide
        val dst = Mat()
        Imgproc.resize(
            src, dst,
            Size(src.cols() * scale, src.rows() * scale),
            0.0, 0.0, Imgproc.INTER_AREA,
        )
        return dst
    }

    // --- Proven OpenCV edge pipeline ---

    /// Detects the best document quad in [src] and returns its four corner
    /// points (in [src]'s pixel space), or null if none is found.
    ///
    /// This owns the ENTIRE OpenCV Mat lifecycle: every `Mat`/`MatOfPoint`
    /// allocated here (the edge-pipeline working Mats, the contour list, and the
    /// per-candidate approx Mats) is released before returning, on every path
    /// including exceptions. Nothing native escapes to the caller — the caller
    /// only owns the input [src]. Returning plain `Point`s (not Mats) is what
    /// makes that guarantee possible: earlier this leaked a `List<MatOfPoint>`
    /// every frame, which grew the native heap until OOM on a long scan.
    private fun detectBestQuad(src: Mat): List<Point>? {
        val gray = Mat()
        val canned = Mat()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(9.0, 9.0))
        val dilated = Mat()
        val hierarchy = Mat()
        val contours = ArrayList<MatOfPoint>()
        try {
            // The input may be 3-channel (BGR, from the YUV path) or 4-channel
            // (RGBA, from bitmapToMat / the BGRA frame path). Pick the matching
            // grayscale conversion by channel count so a 4-channel image doesn't
            // hit BGR2GRAY's `scn == 3` assertion (which would throw and break
            // the file/BGRA paths entirely).
            val grayCode = if (src.channels() >= 4) {
                Imgproc.COLOR_RGBA2GRAY
            } else {
                Imgproc.COLOR_BGR2GRAY
            }
            Imgproc.cvtColor(src, gray, grayCode)
            Imgproc.GaussianBlur(gray, gray, Size(5.0, 5.0), 0.0)
            Imgproc.threshold(gray, gray, 20.0, 255.0, Imgproc.THRESH_TRIANGLE)
            Imgproc.Canny(gray, canned, 75.0, 200.0)
            Imgproc.dilate(canned, dilated, kernel)

            Imgproc.findContours(
                dilated, contours, hierarchy,
                Imgproc.RETR_TREE, Imgproc.CHAIN_APPROX_SIMPLE,
            )

            val candidates = contours
                .filter { Imgproc.contourArea(it) > 100e2 }
                .sortedByDescending { Imgproc.contourArea(it) }
                .take(5)

            for (contour in candidates) {
                val c2f = MatOfPoint2f(*contour.toArray())
                val approx = MatOfPoint2f()
                val convex = MatOfPoint()
                try {
                    val peri = Imgproc.arcLength(c2f, true)
                    Imgproc.approxPolyDP(c2f, approx, 0.03 * peri, true)
                    val pts = approx.toArray().toList()
                    approx.convertTo(convex, CvType.CV_32S)
                    if (pts.size == 4 && Imgproc.isContourConvex(convex)) return pts
                } finally {
                    c2f.release(); approx.release(); convex.release()
                }
            }
            return null
        } finally {
            gray.release(); canned.release(); kernel.release()
            dilated.release(); hierarchy.release()
            // Release EVERY contour Mat, including the ones we didn't inspect.
            for (contour in contours) contour.release()
        }
    }

    private fun orderCorners(points: List<Point>): List<Point> {
        val tl = points.minByOrNull { it.x + it.y } ?: Point()
        val br = points.maxByOrNull { it.x + it.y } ?: Point()
        val tr = points.minByOrNull { it.y - it.x } ?: Point()
        val bl = points.maxByOrNull { it.y - it.x } ?: Point()
        return listOf(tl, tr, br, bl)
    }

    // --- YUV / Bitmap helpers ---

    private fun toNv21(
        y: ByteArray, u: ByteArray, v: ByteArray, width: Int, height: Int,
        yStride: Int, uvStride: Int, uvPixel: Int,
    ): ByteArray {
        val nv21 = ByteArray(width * height + width * (height / 2))
        var pos = 0
        if (yStride == width) {
            System.arraycopy(y, 0, nv21, 0, width * height); pos = width * height
        } else {
            for (row in 0 until height) { System.arraycopy(y, row * yStride, nv21, pos, width); pos += width }
        }
        val uvH = height / 2; val uvW = width / 2
        for (row in 0 until uvH) for (col in 0 until uvW) {
            val i = row * uvStride + col * uvPixel
            // Guard against OEM plane layouts whose stride/pixelStride don't
            // match the reported dims (e.g. a single interleaved U/V plane) —
            // read a neutral 128 (gray chroma) rather than crashing out of range.
            nv21[pos++] = if (i < v.size) v[i] else 128.toByte()
            nv21[pos++] = if (i < u.size) u[i] else 128.toByte()
        }
        return nv21
    }

    private fun nv21ToBitmap(nv21: ByteArray, width: Int, height: Int): Bitmap? {
        val yuv = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val out = ByteArrayOutputStream()
        if (!yuv.compressToJpeg(Rect(0, 0, width, height), 85, out)) { out.close(); return null }
        val bytes = out.toByteArray(); out.close()
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }

    private fun decodeBitmapWithOrientation(file: File): Bitmap? {
        val path = file.absolutePath
        // Two-pass decode: read the bounds first and pick an inSampleSize so a
        // huge gallery photo (12–108 MP) isn't decoded at full resolution into a
        // multi-hundred-MB bitmap (OOM risk) when detection only needs ~2000px.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val opts = BitmapFactory.Options().apply {
            inSampleSize = computeInSampleSize(
                bounds.outWidth, bounds.outHeight, DETECTION_MAX_LONG_SIDE,
            )
        }
        val bitmap = BitmapFactory.decodeFile(path, opts) ?: return null

        val orientation = ExifInterface(path)
            .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.preScale(1f, -1f)
        }
        if (m.isIdentity) return bitmap
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        // createBitmap returns a new bitmap; free the pre-rotation source.
        if (rotated != bitmap) bitmap.recycle()
        return rotated
    }

    /// Largest power-of-two subsample that keeps the long side >= [maxLongSide].
    private fun computeInSampleSize(w: Int, h: Int, maxLongSide: Int): Int {
        var sample = 1
        var longSide = maxOf(w, h)
        while (longSide / 2 >= maxLongSide) {
            longSide /= 2
            sample *= 2
        }
        return sample
    }

    private fun isEmulator(): Boolean {
        val fp = Build.FINGERPRINT.lowercase()
        val model = Build.MODEL.lowercase()
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        val device = Build.DEVICE.lowercase()
        val product = Build.PRODUCT.lowercase()
        return fp.contains("generic") || fp.contains("emulator") ||
            model.contains("emulator") || model.contains("sdk") ||
            manufacturer.contains("genymotion") ||
            (brand.startsWith("generic") && device.startsWith("generic")) ||
            product.contains("sdk") || product.contains("emulator")
    }

    companion object {
        private const val TAG = "DocumentScan"
        private const val CHANNEL = "com.oguzhan.document_scan/detector"

        // Cap the long side before the edge pipeline runs — for BOTH the file
        // and the realtime-frame path, so the absolute-pixel Canny/dilate/area
        // thresholds in findContours act on the same resolution and the two
        // paths agree on what's a document (gallery/camera parity). Document
        // edges are easily found at 720px, and the per-frame Mat/buffer and
        // detection cost both shrink from 1080p.
        private const val DETECTION_MAX_LONG_SIDE = 720
    }
}

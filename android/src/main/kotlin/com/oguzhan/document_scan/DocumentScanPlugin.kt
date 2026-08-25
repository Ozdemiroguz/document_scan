package com.oguzhan.document_scan

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
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
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.util.concurrent.Executors

/**
 * Android edge/corner detection for the `document_scan` plugin, backed by
 * OpenCV. Detects a document as a rectangle (no text required) and returns its
 * four corners as normalized 0..1 points.
 *
 * Channel: `com.oguzhan.document_scan/detector`
 *  - `detectFile`  { path }                        -> corners (pixel-normalized)
 *  - `detectFrame` { width,height,rotation,format, y or bytes, strides }
 *
 * A `yuv420` frame is read as luma only — the pipeline is grayscale, so the
 * chroma planes are ignored even though the wire format still carries them.
 *
 * Pipeline: grayscale -> bilateral denoise -> three candidate strategies
 * (adaptive Canny + close, adaptive-threshold silhouette, Triangle
 * auto-threshold) pooled through convexHull and an approxPolyDP epsilon
 * sweep, then scored by rectangularity and right-angle-ness. Corners are
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
                val sens = Sensitivity.from(call.argument<String>("sensitivity"))
                executor.execute {
                    try {
                        val corners = detectFromFile(path, sens)
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
                val sens = Sensitivity.from(call.argument<String>("sensitivity"))
                frameBusy = true
                executor.execute {
                    try {
                        val corners = when (format) {
                            "yuv420" -> {
                                // Luma only: the pipeline is grayscale, so the
                                // chroma planes are never read (see detectFromYuv).
                                val y = call.argument<ByteArray>("yBytes")
                                val yStride = call.argument<Int>("yRowStride") ?: width
                                if (y == null) null
                                else detectFromYuv(y, width, height, yStride, rotation, sens)
                            }
                            else -> {
                                val bytes = call.argument<ByteArray>("bytes")
                                val bpr = call.argument<Int>("bytesPerRow") ?: (width * 4)
                                if (bytes == null) null
                                else detectFromBgra(bytes, width, height, bpr, rotation, sens)
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

    private fun detectFromFile(path: String, sens: Sensitivity): Map<String, Double>? {
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
            detectBestQuad(src, sens)
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

    /**
     * Detects in a YUV420 frame by reading its Y (luma) plane and nothing else.
     *
     * The whole detection pipeline is grayscale — [detectBestQuad]'s first act
     * used to be a BGR2GRAY conversion — and a YUV420 frame's Y plane already
     * IS that grayscale. So building NV21 and running `cvtColor(YUV2BGR_NV21)`
     * spent, per 1080p frame, a ~3 MB interleaved buffer plus a ~6 MB
     * three-channel Mat manufacturing colour the very next step threw away.
     * Reading Y straight into a single-channel Mat costs one `width * height`
     * copy, and none at all when the plane is already tightly packed.
     *
     * Dropping the colour conversion also retires the emulator special case:
     * that branch existed only because the emulator could crash inside
     * OpenCV's parallel colour conversion, and this path performs none.
     *
     * The chroma planes are not read at all. iOS never sent them (it streams
     * BGRA), and now neither platform consumes them.
     */
    private fun detectFromYuv(
        y: ByteArray, width: Int, height: Int,
        yStride: Int, rotation: Int, sens: Sensitivity,
    ): Map<String, Double>? {
        var gray = yPlaneToGrayMat(y, width, height, yStride) ?: return null

        // Downscale before the edge pipeline so a full-res Mat is never kept
        // per frame. Corners come out normalized, so the source scale doesn't
        // change the result — this is the main lever for per-frame
        // Large-Object-Space GC pressure.
        val longSide = maxOf(width, height)
        if (longSide > DETECTION_MAX_LONG_SIDE) {
            val scale = DETECTION_MAX_LONG_SIDE.toDouble() / longSide
            val small = Mat()
            Imgproc.resize(
                gray, small,
                Size(width * scale, height * scale),
                0.0, 0.0, Imgproc.INTER_AREA,
            )
            gray.release()
            gray = small
        }
        return detectAndNormalize(gray, rotation, sens)
    }

    /**
     * Copies the frame's Y plane into a single-channel Mat, honouring
     * [yStride] (a camera's rows are often padded past [width]). Returns null
     * when the plane is shorter than [width] x [height] implies — a malformed
     * frame is a dropped frame, not a crash.
     */
    private fun yPlaneToGrayMat(y: ByteArray, width: Int, height: Int, yStride: Int): Mat? {
        val stride = if (yStride > 0) yStride else width
        if (stride < width || y.size < (height - 1).toLong() * stride + width) return null

        val mat = Mat(height, width, CvType.CV_8UC1)
        if (stride == width) {
            // Tightly packed: hand the plane over as-is.
            mat.put(0, 0, y)
            return mat
        }
        // Strided: drop each row's padding into a packed buffer first.
        val packed = ByteArray(width * height)
        for (row in 0 until height) {
            System.arraycopy(y, row * stride, packed, row * width, width)
        }
        mat.put(0, 0, packed)
        return mat
    }

    private fun detectFromBgra(
        bytes: ByteArray, width: Int, height: Int, bytesPerRow: Int, rotation: Int,
        sens: Sensitivity,
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
        return detectAndNormalize(mat, rotation, sens)
    }

    private fun detectAndNormalize(mat: Mat, rotation: Int, sens: Sensitivity): Map<String, Double>? {
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
            detectBestQuad(work, sens)
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

    /// Maps the Dart `DetectionSensitivity` to the OpenCV pipeline's knobs. The
    /// level is the portable contract; these are its Android values.
    ///
    /// - [minAreaFraction]: a candidate quad must cover at least this fraction of
    ///   the frame. Strict wants a bigger, more committed document.
    /// - [cannyLoFactor]/[cannyHiFactor]: the adaptive-Canny band, scaled off the
    ///   frame's mean brightness (Strategy A). Lower factors keep weaker edges.
    /// - [maxCosine]: how far a corner may deviate from a right angle (cosine of
    ///   the corner angle). Strict demands squarer corners; lenient tolerates
    ///   more perspective skew.
    /// - [minScore]: the floor the best-scored candidate must clear to count as a
    ///   document at all — the multi-strategy generator finds *something* in most
    ///   frames, so this is what rejects non-documents.
    enum class Sensitivity(
        val minAreaFraction: Double,
        val cannyLoFactor: Double,
        val cannyHiFactor: Double,
        val maxCosine: Double,
        val minScore: Double,
    ) {
        STRICT(0.10, 0.80, 1.50, 0.35, 0.52),
        BALANCED(0.06, 0.66, 1.33, 0.42, 0.46),
        LENIENT(0.03, 0.50, 1.10, 0.50, 0.38);

        companion object {
            fun from(name: String?): Sensitivity = when (name) {
                "strict" -> STRICT
                "lenient" -> LENIENT
                else -> BALANCED
            }
        }
    }

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
    private fun detectBestQuad(src: Mat, sens: Sensitivity): List<Point>? {
        val gray = Mat()
        val filtered = Mat()
        // 5x5 ellipse for MORPH_CLOSE: bridges broken/faint edges without the
        // outline-bloat and shape-shift of the old bare 9x9 dilate.
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        try {
            // The input arrives with a different channel count per path:
            // 1 (luma, from the YUV frame path — already grayscale, nothing to
            // convert), 3 (BGR), or 4 (RGBA, from bitmapToMat / the BGRA frame
            // path). Pick by channel count so a 4-channel image doesn't hit
            // BGR2GRAY's `scn == 3` assertion, and so a 1-channel image isn't
            // fed to a converter that would reject it outright.
            if (src.channels() == 1) {
                src.copyTo(gray)
            } else {
                val grayCode = if (src.channels() >= 4) {
                    Imgproc.COLOR_RGBA2GRAY
                } else {
                    Imgproc.COLOR_BGR2GRAY
                }
                Imgproc.cvtColor(src, gray, grayCode)
            }

            // Edge-preserving denoise: bilateral smooths flat areas (paper, desk)
            // while keeping the faint page boundary — better recall on soft edges
            // than a Gaussian blur, which would wash the boundary out too.
            Imgproc.bilateralFilter(gray, filtered, 9, 75.0, 75.0)

            val frameArea = (filtered.rows() * filtered.cols()).toDouble()
            val minArea = frameArea * sens.minAreaFraction
            // A quad that covers almost the whole frame is the frame itself (or a
            // wall/desk filling the view), not a document held within it. Cap the
            // candidate area so the "everything is a document" quad is rejected
            // before it can win the score. Real documents leave a margin.
            val maxArea = frameArea * MAX_AREA_FRACTION
            val candidates = ArrayList<List<Point>>()

            // A single detection strategy can't cover every scene, so run three
            // and pool their quads — the scorer picks the winner. Each strategy
            // targets a different failure mode of the others.

            // Strategy A — adaptive Canny + close. Strong on high-contrast edges
            // (dark document on a light desk); the band adapts to brightness.
            run {
                val edges = Mat()
                try {
                    val mean = Core.mean(filtered).`val`[0]
                    val lo = (sens.cannyLoFactor * mean).coerceIn(20.0, 120.0)
                    val hi = (sens.cannyHiFactor * mean).coerceIn(80.0, 240.0)
                    Imgproc.Canny(filtered, edges, lo, hi)
                    Imgproc.morphologyEx(edges, edges, Imgproc.MORPH_CLOSE, kernel)
                    candidates += quadsFrom(edges, minArea, maxArea, sens.maxCosine)
                } finally {
                    edges.release()
                }
            }

            // Strategy B — adaptive-threshold silhouette. Segments the paper as a
            // bright region instead of chasing a gradient, so it's the one that
            // survives low contrast (white page on a light desk), where edges
            // barely exist.
            run {
                val bin = Mat()
                try {
                    Imgproc.adaptiveThreshold(
                        filtered, bin, 255.0,
                        Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C, Imgproc.THRESH_BINARY_INV,
                        21, 10.0,
                    )
                    Imgproc.morphologyEx(bin, bin, Imgproc.MORPH_CLOSE, kernel)
                    candidates += quadsFrom(bin, minArea, maxArea, sens.maxCosine)
                } finally {
                    bin.release()
                }
            }

            // Strategy C — Triangle auto-threshold then Canny. The Triangle
            // algorithm picks the cut automatically, handling uneven lighting
            // that a fixed threshold or brightness-scaled Canny alone misses.
            run {
                val bin = Mat()
                val edges = Mat()
                try {
                    Imgproc.threshold(
                        filtered, bin, 0.0, 255.0,
                        Imgproc.THRESH_BINARY + Imgproc.THRESH_TRIANGLE,
                    )
                    Imgproc.Canny(bin, edges, 50.0, 150.0)
                    Imgproc.morphologyEx(edges, edges, Imgproc.MORPH_CLOSE, kernel)
                    candidates += quadsFrom(edges, minArea, maxArea, sens.maxCosine)
                } finally {
                    bin.release(); edges.release()
                }
            }

            // Pick the best quad across all strategies — not the first found, not
            // the largest. A shadow or table edge can out-area the document, so
            // score by shape (rectangularity + right-angle-ness) with a light
            // size term, and require the winner to clear the level's floor.
            val best = candidates.maxByOrNull { scoreQuad(it, frameArea) } ?: return null
            if (scoreQuad(best, frameArea) < sens.minScore) return null
            return best
        } finally {
            gray.release(); filtered.release(); kernel.release()
        }
    }

    /// Extracts candidate document quads from a binary edge/silhouette [map].
    ///
    /// Uses `RETR_EXTERNAL` (outermost contours only — inner text blocks can't
    /// win), takes the hull of each large contour (erasing finger/shadow/dog-ear
    /// concavities so it simplifies to 4 points more reliably), then sweeps the
    /// approx tolerance until a convex, right-angled 4-gon appears. Owns and
    /// releases every native Mat it allocates; returns only plain [Point]s.
    private fun quadsFrom(
        map: Mat, minArea: Double, maxArea: Double, maxCosine: Double,
    ): List<List<Point>> {
        val contours = ArrayList<MatOfPoint>()
        val hierarchy = Mat()
        val out = ArrayList<List<Point>>()
        try {
            Imgproc.findContours(
                map, contours, hierarchy,
                Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val big = contours
                .filter {
                    val a = Imgproc.contourArea(it)
                    a > minArea && a < maxArea
                }
                .sortedByDescending { Imgproc.contourArea(it) }
                .take(6)

            for (contour in big) {
                val hull = MatOfInt()
                val hullPts = MatOfPoint()
                val h2f = MatOfPoint2f()
                val approx = MatOfPoint2f()
                val convex = MatOfPoint()
                try {
                    // convexHull returns indices; map them back to points.
                    Imgproc.convexHull(contour, hull)
                    val src = contour.toArray()
                    val idx = hull.toArray()
                    hullPts.fromList(idx.map { src[it] })
                    h2f.fromArray(*hullPts.toArray())
                    val peri = Imgproc.arcLength(h2f, true)
                    // Sweep the tolerance instead of a single guess: a noisy or
                    // slightly curved edge may only collapse to 4 points at one
                    // particular epsilon.
                    for (frac in EPSILON_SWEEP) {
                        Imgproc.approxPolyDP(h2f, approx, frac * peri, true)
                        val pts = approx.toArray().toList()
                        if (pts.size == 4) {
                            approx.convertTo(convex, CvType.CV_32S)
                            if (Imgproc.isContourConvex(convex) &&
                                maxCornerCosine(pts) < maxCosine) {
                                out += pts
                                break
                            }
                        }
                    }
                } finally {
                    hull.release(); hullPts.release(); h2f.release()
                    approx.release(); convex.release()
                }
            }
        } finally {
            hierarchy.release()
            for (contour in contours) contour.release()
        }
        return out
    }

    /// Scores a quad 0..1 on how document-like its *shape* is, independent of
    /// where it sits: rectangularity (fill vs its rotated bounding box) and
    /// right-angle-ness dominate, with a light reward for size. This is what lets
    /// a smaller, cleaner document beat a big shadow or a table edge.
    private fun scoreQuad(quad: List<Point>, frameArea: Double): Double {
        val poly = MatOfPoint2f(*quad.toTypedArray())
        val polyInt = MatOfPoint(*quad.toTypedArray())
        try {
            val area = Imgproc.contourArea(polyInt)
            val rect = Imgproc.minAreaRect(poly)
            val rectArea = rect.size.width * rect.size.height
            val rectangularity = if (rectArea > 0) (area / rectArea).coerceIn(0.0, 1.0) else 0.0
            val rightness = (1.0 - maxCornerCosine(quad)).coerceIn(0.0, 1.0)
            val sizeScore = (area / frameArea).coerceIn(0.0, 1.0)
            return 0.45 * rectangularity + 0.35 * rightness + 0.20 * sizeScore
        } finally {
            poly.release(); polyInt.release()
        }
    }

    /// The largest cosine over the quad's four corners (0 = perfect right angle,
    /// 1 = degenerate/flat). Lower is more rectangle-like. Used both as a gate in
    /// [quadsFrom] and a score term in [scoreQuad].
    private fun maxCornerCosine(pts: List<Point>): Double {
        if (pts.size != 4) return 1.0
        var maxCos = 0.0
        for (i in 0 until 4) {
            val p0 = pts[i]
            val p1 = pts[(i + 1) % 4]
            val p2 = pts[(i + 3) % 4]
            val dx1 = p1.x - p0.x; val dy1 = p1.y - p0.y
            val dx2 = p2.x - p0.x; val dy2 = p2.y - p0.y
            val dot = dx1 * dx2 + dy1 * dy2
            val mag = Math.sqrt((dx1 * dx1 + dy1 * dy1) * (dx2 * dx2 + dy2 * dy2))
            val cos = if (mag > 0) Math.abs(dot / mag) else 1.0
            if (cos > maxCos) maxCos = cos
        }
        return maxCos
    }

    private fun orderCorners(points: List<Point>): List<Point> {
        val tl = points.minByOrNull { it.x + it.y } ?: Point()
        val br = points.maxByOrNull { it.x + it.y } ?: Point()
        val tr = points.minByOrNull { it.y - it.x } ?: Point()
        val bl = points.maxByOrNull { it.y - it.x } ?: Point()
        return listOf(tl, tr, br, bl)
    }

    // --- Bitmap helpers ---

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

        // A candidate covering more than this fraction of the frame is the frame
        // itself (or a wall/desk filling the view), not a document held within
        // it. Rejecting these is what stops "the whole camera view is a document".
        private const val MAX_AREA_FRACTION = 0.92

        // approxPolyDP tolerances (fraction of the contour perimeter) tried in
        // order until a contour collapses to a 4-gon. A single fixed epsilon
        // misses quads that only simplify cleanly at a different tolerance.
        private val EPSILON_SWEEP = doubleArrayOf(0.02, 0.03, 0.05, 0.08)
    }
}

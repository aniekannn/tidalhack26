package com.horizonx.ai

/**
 * HorizonX — On-Device Vision Pipeline
 *
 * Orchestrates:
 *   1. Frame sampling from CameraX
 *   2. On-device VLM inference (MobileVLM v2, 4-bit quantized)
 *   3. Priority routing of scene descriptions
 *   4. Hazard detection & classification
 *
 * Privacy: Raw frames NEVER leave this pipeline. Only text descriptions propagate.
 */

import android.content.Context
import android.graphics.Bitmap
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.concurrent.atomic.AtomicBoolean

// ─── Data Classes ────────────────────────────────────────────────────────────

data class SceneDescription(
    val narration: String,
    val obstacles: List<Obstacle>,
    val ocrText: String?,
    val pathClear: Boolean,
    val recommendedAction: String,
    val timestamp: Long = System.currentTimeMillis()
)

data class Obstacle(
    val type: ObstacleType,
    val description: String,
    val clockDirection: Int,        // 1-12 clock position
    val distanceMeters: Float,
    val moving: Boolean,
    val approachDirection: ApproachDirection,
    val urgency: Urgency
)

enum class ObstacleType { VEHICLE, PERSON, OBJECT, TERRAIN, CONSTRUCTION }
enum class ApproachDirection { TOWARDS, AWAY, CROSSING, STATIONARY }
enum class Urgency { IMMEDIATE, SOON, AMBIENT }

// ─── Vision Pipeline ─────────────────────────────────────────────────────────

class VisionPipeline(
    private val context: Context,
    private val config: PipelineConfig = PipelineConfig()
) {
    data class PipelineConfig(
        val targetFps: Int = 10,              // Analyze every 3rd frame from 30fps
        val inputSize: Int = 384,              // Model input resolution
        val maxObstacles: Int = 3,             // Cap obstacles per frame
        val confidenceThreshold: Float = 0.6f, // Min confidence to report
        val kvCacheSize: Int = 512,            // Sliding window token cache
    )

    private val _sceneFlow = MutableSharedFlow<SceneDescription>(replay = 1)
    val sceneFlow: SharedFlow<SceneDescription> = _sceneFlow.asSharedFlow()

    private val isProcessing = AtomicBoolean(false)
    private var frameCount = 0

    // VLM model wrapper (TFLite GPU delegate in production)
    private var vlmModel: OnDeviceVLM? = null
    // OCR engine (ML Kit)
    private var ocrEngine: TextRecognizer? = null

    /**
     * Initialize on-device models.
     * Call once during app startup.
     */
    suspend fun initialize() = withContext(Dispatchers.IO) {
        vlmModel = OnDeviceVLM(context, config)
        ocrEngine = TextRecognizer(context)
        // Pre-warm the model with a blank frame
        vlmModel?.warmup()
    }

    /**
     * Process a camera frame.
     * Called from CameraX Analyzer at 30fps, but we sample at targetFps.
     *
     * PRIVACY: Frame is processed in-memory only. Never persisted or transmitted.
     */
    suspend fun processFrame(bitmap: Bitmap) {
        frameCount++

        // Frame sampling: only process every Nth frame
        if (frameCount % (30 / config.targetFps) != 0) return

        // Prevent overlapping inference
        if (!isProcessing.compareAndSet(false, true)) return

        try {
            withContext(Dispatchers.Default) {
                // 1. Downscale to model input size
                val resized = Bitmap.createScaledBitmap(
                    bitmap, config.inputSize, config.inputSize, true
                )

                // 2. Run VLM inference (on-device, ~180ms on Snapdragon 8 Gen 2)
                val vlmResult = vlmModel?.infer(resized)

                // 3. Run OCR in parallel (if text-like regions detected)
                val ocrResult = if (vlmResult?.hasText == true) {
                    ocrEngine?.recognize(resized)
                } else null

                // 4. Build scene description
                val scene = SceneDescription(
                    narration = vlmResult?.narration ?: "Processing...",
                    obstacles = vlmResult?.obstacles
                        ?.filter { it.urgency != Urgency.AMBIENT || it.distanceMeters < 5f }
                        ?.sortedBy { it.urgency.ordinal }
                        ?.take(config.maxObstacles)
                        ?: emptyList(),
                    ocrText = ocrResult?.text,
                    pathClear = vlmResult?.obstacles?.none {
                        it.urgency == Urgency.IMMEDIATE
                    } ?: true,
                    recommendedAction = vlmResult?.recommendedAction ?: "Proceed with caution"
                )

                // 5. Emit to listeners (TTS engine, hazard detector, etc.)
                _sceneFlow.emit(scene)

                // PRIVACY: Release bitmap from memory immediately
                resized.recycle()
            }
        } finally {
            isProcessing.set(false)
        }
    }

    /**
     * Release all model resources.
     */
    fun release() {
        vlmModel?.close()
        ocrEngine?.close()
    }
}

// ─── Model Interfaces (implementations in separate files) ────────────────────

/**
 * On-device Visual Language Model wrapper.
 * In production: wraps TFLite with GPU delegate for MobileVLM v2.
 */
class OnDeviceVLM(
    private val context: Context,
    private val config: VisionPipeline.PipelineConfig
) {
    data class VLMResult(
        val narration: String,
        val obstacles: List<Obstacle>,
        val hasText: Boolean,
        val recommendedAction: String,
        val inferenceTimeMs: Long
    )

    fun warmup() {
        // Load model weights, initialize KV cache
        // TFLite: Interpreter.Options().addDelegate(GpuDelegate())
    }

    suspend fun infer(bitmap: Bitmap): VLMResult {
        val startTime = System.currentTimeMillis()

        // TODO: Real TFLite inference
        // val inputBuffer = preprocessBitmap(bitmap)
        // interpreter.run(inputBuffer, outputBuffer)
        // val parsed = parseModelOutput(outputBuffer)

        // Mock inference for prototype
        val inferenceTime = System.currentTimeMillis() - startTime

        return VLMResult(
            narration = "Clear path ahead. Indoor corridor.",
            obstacles = emptyList(),
            hasText = false,
            recommendedAction = "Continue straight.",
            inferenceTimeMs = inferenceTime
        )
    }

    fun close() {
        // Release TFLite interpreter and GPU delegate
    }
}

/**
 * On-device text recognition using ML Kit.
 */
class TextRecognizer(private val context: Context) {
    data class OCRResult(
        val text: String,
        val confidence: Float,
        val language: String?
    )

    suspend fun recognize(bitmap: Bitmap): OCRResult {
        // TODO: ML Kit TextRecognition
        // val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        // val inputImage = InputImage.fromBitmap(bitmap, 0)
        // val result = recognizer.process(inputImage).await()

        return OCRResult(text = "", confidence = 0f, language = "en")
    }

    fun close() {
        // Release ML Kit resources
    }
}

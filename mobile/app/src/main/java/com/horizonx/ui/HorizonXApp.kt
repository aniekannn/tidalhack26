package com.horizonx.ui

/**
 * HorizonX — Main Application Coordinator
 *
 * Voice-first, zero-visual-dependency interface.
 * This activity coordinates all components:
 *   - Camera → Vision Pipeline → Speech Engine
 *   - Voice Commands → Action Router
 *   - Hazard Detection → Offline Reporter
 *
 * Accessibility:
 *   - All UI elements are TalkBack-compatible
 *   - Voice commands for all actions
 *   - Haptic feedback for alerts
 *   - No visual UI dependency
 */

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import com.horizonx.ai.VisionPipeline
import com.horizonx.ai.Urgency
import com.horizonx.speech.SpeechEngine
import com.horizonx.speech.SpeechPriority
import com.horizonx.hazard.HazardReporter
import com.horizonx.hazard.HazardType
import com.horizonx.hazard.Severity
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest

class HorizonXApp : AppCompatActivity() {

    // Core components
    private lateinit var visionPipeline: VisionPipeline
    private lateinit var speechEngine: SpeechEngine
    private lateinit var hazardReporter: HazardReporter

    // Voice recognition
    private var speechRecognizer: SpeechRecognizer? = null
    private var isListening = false

    // Coroutine scope
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // Vibration for haptic alerts
    private val vibrator by lazy {
        getSystemService(VIBRATOR_SERVICE) as Vibrator
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Minimal UI — just camera preview (for sighted helpers) + status
        // setContentView(R.layout.activity_main)

        // Initialize components
        initializeComponents()

        // Request permissions
        if (hasRequiredPermissions()) {
            startVisionSystem()
        } else {
            requestPermissions(
                arrayOf(
                    Manifest.permission.CAMERA,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.RECORD_AUDIO
                ),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    private fun initializeComponents() {
        // 1. Vision Pipeline — on-device ML inference
        visionPipeline = VisionPipeline(this)

        // 2. Speech Engine — dual TTS (offline native + online ElevenLabs)
        speechEngine = SpeechEngine(this)
        speechEngine.initialize {
            speechEngine.speak(
                "HorizonX ready. Tap and hold to ask a question. " +
                "I'll describe your surroundings.",
                SpeechPriority.IMMEDIATE
            )
        }

        // 3. Hazard Reporter — offline-first civic reporting
        hazardReporter = HazardReporter(this)
    }

    private fun startVisionSystem() {
        scope.launch {
            // Initialize ML models (may take 2-3 seconds)
            speechEngine.speak("Loading vision models...", SpeechPriority.AMBIENT)
            visionPipeline.initialize()
            speechEngine.speak("Vision active. Scanning surroundings.", SpeechPriority.AMBIENT)

            // Start camera
            startCamera()

            // Listen for scene descriptions
            visionPipeline.sceneFlow.collectLatest { scene ->
                handleSceneUpdate(scene)
            }
        }
    }

    /**
     * Handle new scene description from vision pipeline.
     * Routes to speech engine with appropriate priority.
     */
    private fun handleSceneUpdate(scene: com.horizonx.ai.SceneDescription) {
        // Priority 1: Immediate dangers
        scene.obstacles
            .filter { it.urgency == Urgency.IMMEDIATE }
            .forEach { obstacle ->
                speechEngine.speakAlert(
                    "${obstacle.description}, ${obstacle.distanceMeters.toInt()} meters, " +
                    "your ${clockToDirection(obstacle.clockDirection)}",
                    obstacle.clockDirection
                )
                // Haptic feedback for immediate dangers
                vibrateAlert()
            }

        // Priority 2: Navigation narration (throttled to every 3 seconds)
        if (!scene.pathClear) {
            speechEngine.speak(scene.recommendedAction, SpeechPriority.SOON)
        }

        // Priority 3: OCR text (only when new text detected)
        scene.ocrText?.takeIf { it.isNotBlank() }?.let { text ->
            speechEngine.speak("Text detected: $text", SpeechPriority.AMBIENT)
        }

        // Priority 4: Ambient scene (every 10 seconds)
        if (shouldNarrate()) {
            speechEngine.speak(scene.narration, SpeechPriority.AMBIENT)
        }
    }

    /**
     * Start CameraX with frame analysis.
     */
    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val imageAnalysis = ImageAnalysis.Builder()
                .setTargetResolution(android.util.Size(640, 480))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()

            imageAnalysis.setAnalyzer(ContextCompat.getMainExecutor(this)) { imageProxy ->
                // Convert ImageProxy to Bitmap and process
                scope.launch {
                    val bitmap = imageProxy.toBitmap()
                    visionPipeline.processFrame(bitmap)
                    imageProxy.close()
                }
            }

            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(this, cameraSelector, imageAnalysis)
        }, ContextCompat.getMainExecutor(this))
    }

    /**
     * Initialize voice command recognition.
     */
    private fun startVoiceListening() {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) return

        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
            setRecognitionListener(object : RecognitionListener {
                override fun onResults(results: Bundle?) {
                    val matches = results?.getStringArrayList(
                        SpeechRecognizer.RESULTS_RECOGNITION
                    )
                    matches?.firstOrNull()?.let { command ->
                        handleVoiceCommand(command)
                    }
                    isListening = false
                }

                override fun onReadyForSpeech(params: Bundle?) { isListening = true }
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) { isListening = false }
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
        }
    }

    /**
     * Process voice commands.
     */
    private fun handleVoiceCommand(command: String) {
        val lower = command.lowercase()

        when {
            lower.contains("what") && (lower.contains("front") || lower.contains("around") || lower.contains("see")) -> {
                speechEngine.speak("Scanning now...", SpeechPriority.IMMEDIATE)
                // Force a detailed scene description
            }
            lower.contains("read") || lower.contains("text") || lower.contains("sign") -> {
                speechEngine.speak("Reading text...", SpeechPriority.SOON)
                // Trigger OCR focus mode
            }
            lower.contains("report") || lower.contains("hazard") || lower.contains("pothole") -> {
                speechEngine.speak("Reporting hazard. What type?", SpeechPriority.SOON)
                // Trigger hazard reporting flow
            }
            lower.contains("help") -> {
                speechEngine.speak(
                    "Say: What's around me, Read that sign, Report a hazard, " +
                    "Navigate to, or Repeat.",
                    SpeechPriority.IMMEDIATE
                )
            }
            lower.contains("repeat") || lower.contains("again") -> {
                // Repeat last narration
                speechEngine.speak("Repeating...", SpeechPriority.SOON)
            }
            else -> {
                speechEngine.speak("I didn't understand. Say Help for options.", SpeechPriority.SOON)
            }
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private fun clockToDirection(clock: Int): String = when (clock) {
        12 -> "directly ahead"
        1, 2 -> "front right"
        3 -> "right"
        4, 5 -> "back right"
        6 -> "behind"
        7, 8 -> "back left"
        9 -> "left"
        10, 11 -> "front left"
        else -> "nearby"
    }

    private var lastNarrationTime = 0L
    private fun shouldNarrate(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastNarrationTime > 10_000) {
            lastNarrationTime = now
            return true
        }
        return false
    }

    private fun vibrateAlert() {
        vibrator.vibrate(
            VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE)
        )
    }

    private fun hasRequiredPermissions(): Boolean {
        return arrayOf(
            Manifest.permission.CAMERA,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.RECORD_AUDIO
        ).all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            if (grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                startVisionSystem()
            } else {
                speechEngine.speak(
                    "Camera and location permissions are needed for navigation assistance.",
                    SpeechPriority.IMMEDIATE
                )
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        visionPipeline.release()
        speechEngine.shutdown()
        hazardReporter.release()
        speechRecognizer?.destroy()
    }

    companion object {
        private const val PERMISSION_REQUEST_CODE = 100
    }
}

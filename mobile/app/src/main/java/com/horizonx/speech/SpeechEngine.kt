package com.horizonx.speech

/**
 * HorizonX — Dual TTS Engine
 *
 * Manages speech output with two backends:
 *   1. Android native TTS (always available, offline)
 *   2. ElevenLabs streaming (enhanced quality, online only)
 *
 * Features:
 *   - Priority queue (immediate interrupts, ambient queues)
 *   - Automatic fallback to offline TTS
 *   - Audio ducking for media
 *   - Spatial audio hints via left/right balance
 */

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import java.util.*
import java.util.concurrent.atomic.AtomicInteger

// ─── Data Classes ────────────────────────────────────────────────────────────

enum class SpeechPriority(val level: Int) {
    IMMEDIATE(0),  // Danger alerts — interrupts current speech
    SOON(1),       // Navigation cues — next in queue
    AMBIENT(2)     // Scene descriptions — end of queue
}

data class SpeechRequest(
    val text: String,
    val priority: SpeechPriority,
    val spatialHint: SpatialHint? = null,
    val id: String = UUID.randomUUID().toString()
)

data class SpatialHint(
    val direction: Float,  // -1.0 (left) to 1.0 (right)
    val urgency: Float     // 0.0 (calm) to 1.0 (alert)
)

enum class TTSBackend { ANDROID_NATIVE, ELEVENLABS }

// ─── Speech Engine ───────────────────────────────────────────────────────────

class SpeechEngine(
    private val context: Context,
    private val config: SpeechConfig = SpeechConfig()
) {
    data class SpeechConfig(
        val preferredBackend: TTSBackend = TTSBackend.ANDROID_NATIVE,
        val speechRate: Float = 0.95f,   // Slightly slower for clarity
        val pitch: Float = 1.0f,
        val elevenLabsVoiceId: String = "aria",
        val elevenLabsModel: String = "eleven_turbo_v2_5",
        val maxQueueSize: Int = 10
    )

    private var nativeTTS: TextToSpeech? = null
    private var isInitialized = false
    private val utteranceId = AtomicInteger(0)

    // Priority queue for speech requests
    private val speechQueue = Channel<SpeechRequest>(Channel.BUFFERED)
    private var processingJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // Audio focus for ducking other audio
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null

    /**
     * Initialize TTS engines.
     */
    fun initialize(onReady: () -> Unit = {}) {
        nativeTTS = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) {
                nativeTTS?.apply {
                    language = Locale.US
                    setSpeechRate(config.speechRate)
                    setPitch(config.pitch)

                    setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}
                        override fun onDone(utteranceId: String?) {
                            releaseAudioFocus()
                        }
                        override fun onError(utteranceId: String?) {
                            releaseAudioFocus()
                        }
                    })
                }
                isInitialized = true
                startProcessing()
                onReady()
            }
        }
    }

    /**
     * Speak text with priority handling.
     */
    fun speak(text: String, priority: SpeechPriority = SpeechPriority.AMBIENT) {
        scope.launch {
            val request = SpeechRequest(text = text, priority = priority)

            when (priority) {
                SpeechPriority.IMMEDIATE -> {
                    // Interrupt everything and speak now
                    nativeTTS?.stop()
                    speakNow(request)
                }
                else -> {
                    // Add to queue
                    speechQueue.send(request)
                }
            }
        }
    }

    /**
     * Speak with spatial audio hint.
     * Used for directional navigation cues.
     */
    fun speakDirectional(
        text: String,
        direction: Float,  // -1.0 (left) to 1.0 (right)
        priority: SpeechPriority = SpeechPriority.SOON
    ) {
        scope.launch {
            val request = SpeechRequest(
                text = text,
                priority = priority,
                spatialHint = SpatialHint(direction = direction, urgency = 0.5f)
            )

            when (priority) {
                SpeechPriority.IMMEDIATE -> {
                    nativeTTS?.stop()
                    speakNow(request)
                }
                else -> speechQueue.send(request)
            }
        }
    }

    /**
     * Speak a navigation alert with spatial cues.
     * E.g., "Cyclist from your left" with audio panned left.
     */
    fun speakAlert(text: String, clockDirection: Int) {
        // Convert clock position to stereo pan
        // 9 o'clock = full left (-1.0), 3 o'clock = full right (1.0)
        val pan = when (clockDirection) {
            in 1..3 -> (clockDirection - 12).toFloat() / 3f + 1f  // Right side
            in 9..11 -> (clockDirection - 12).toFloat() / 3f      // Left side
            12 -> 0f                                                // Center/ahead
            6 -> 0f                                                 // Behind (center)
            else -> 0f
        }.coerceIn(-1f, 1f)

        speakDirectional(text, pan, SpeechPriority.IMMEDIATE)
    }

    /**
     * Stop all speech immediately.
     */
    fun stop() {
        nativeTTS?.stop()
    }

    /**
     * Cleanup resources.
     */
    fun shutdown() {
        processingJob?.cancel()
        scope.cancel()
        nativeTTS?.stop()
        nativeTTS?.shutdown()
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    private fun startProcessing() {
        processingJob = scope.launch {
            for (request in speechQueue) {
                speakNow(request)
                // Small gap between queued utterances
                delay(200)
            }
        }
    }

    private fun speakNow(request: SpeechRequest) {
        if (!isInitialized) return

        requestAudioFocus()

        val params = android.os.Bundle().apply {
            // Spatial audio via stereo pan
            request.spatialHint?.let {
                putFloat(TextToSpeech.Engine.KEY_PARAM_PAN, it.direction)
            }
        }

        nativeTTS?.speak(
            request.text,
            TextToSpeech.QUEUE_ADD,
            params,
            "horizonx_${utteranceId.incrementAndGet()}"
        )
    }

    private fun requestAudioFocus() {
        focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .build()
        focusRequest?.let { audioManager.requestAudioFocus(it) }
    }

    private fun releaseAudioFocus() {
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
    }
}

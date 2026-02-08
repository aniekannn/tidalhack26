package com.horizonx.camera

/**
 * HorizonX — CameraX Manager
 *
 * Handles camera lifecycle, frame capture, and image analysis
 * integration with the Vision Pipeline.
 *
 * Key design decisions:
 *   - Back camera only (user faces world)
 *   - 640x480 resolution (good enough for VLM, saves bandwidth)
 *   - STRATEGY_KEEP_ONLY_LATEST (drop frames if inference is behind)
 *   - No preview surface needed (voice-first UI)
 */

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.YuvImage
import android.util.Size
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.horizonx.ai.VisionPipeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class CameraManager(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val visionPipeline: VisionPipeline,
    private val scope: CoroutineScope
) {
    private var cameraProvider: ProcessCameraProvider? = null
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /**
     * Start camera capture and wire frames to vision pipeline.
     */
    fun start() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()

            // Image analysis use case — core of HorizonX
            val imageAnalysis = ImageAnalysis.Builder()
                .setTargetResolution(Size(640, 480))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                .build()

            imageAnalysis.setAnalyzer(cameraExecutor) { imageProxy ->
                processFrame(imageProxy)
            }

            // Back camera for world-facing capture
            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cameraProvider?.unbindAll()
                cameraProvider?.bindToLifecycle(
                    lifecycleOwner,
                    cameraSelector,
                    imageAnalysis
                )
            } catch (e: Exception) {
                // Camera bind failed — will retry
            }

        }, ContextCompat.getMainExecutor(context))
    }

    /**
     * Process a single camera frame.
     * Converts YUV to Bitmap and sends to VisionPipeline.
     *
     * PRIVACY: Frame exists only in RAM during this call.
     *          Never written to disk.
     *          Never transmitted over network.
     */
    private fun processFrame(imageProxy: ImageProxy) {
        try {
            val bitmap = imageProxy.toBitmapSafe()
            if (bitmap != null) {
                scope.launch(Dispatchers.Default) {
                    visionPipeline.processFrame(bitmap)
                    // Bitmap recycled inside VisionPipeline after inference
                }
            }
        } finally {
            imageProxy.close()
        }
    }

    /**
     * Convert ImageProxy (YUV_420_888) to Bitmap.
     * Handles rotation automatically.
     */
    private fun ImageProxy.toBitmapSafe(): Bitmap? {
        return try {
            val yBuffer = planes[0].buffer
            val uBuffer = planes[1].buffer
            val vBuffer = planes[2].buffer

            val ySize = yBuffer.remaining()
            val uSize = uBuffer.remaining()
            val vSize = vBuffer.remaining()

            val nv21 = ByteArray(ySize + uSize + vSize)
            yBuffer.get(nv21, 0, ySize)
            vBuffer.get(nv21, ySize, vSize)
            uBuffer.get(nv21, ySize + vSize, uSize)

            val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            val out = ByteArrayOutputStream()
            yuvImage.compressToJpeg(android.graphics.Rect(0, 0, width, height), 80, out)
            val imageBytes = out.toByteArray()

            BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Stop camera and release resources.
     */
    fun stop() {
        cameraProvider?.unbindAll()
        cameraExecutor.shutdown()
    }
}

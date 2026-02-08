package com.horizonx.hazard

/**
 * HorizonX — Offline-First Hazard Reporter
 *
 * Handles:
 *   - On-device hazard classification from scene descriptions
 *   - Local SQLite queue for offline reports
 *   - Background sync when connectivity is restored
 *   - Privacy: location fuzzing, timestamp rounding, rotating device hash
 */

import android.content.Context
import android.location.Location
import kotlinx.coroutines.*
import java.security.MessageDigest
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

// ─── Data Classes ────────────────────────────────────────────────────────────

enum class HazardType {
    POTHOLE, BROKEN_SIGNAGE, BLOCKED_SIDEWALK, MISSING_RAMP,
    POOR_LIGHTING, CROWD_DENSITY, CONSTRUCTION, FLOODING,
    BROKEN_TRAFFIC_LIGHT, UNEVEN_SURFACE, OTHER
}

enum class Severity { LOW, MEDIUM, HIGH, CRITICAL }

data class HazardReport(
    val localId: Long = 0,
    val hazardType: HazardType,
    val severity: Severity,
    val description: String,
    val latitude: Double,
    val longitude: Double,
    val timestamp: Instant,
    val deviceHash: String,
    val confidence: Float,
    val contextTags: List<String>,
    val synced: Boolean = false,
    val syncedAt: Instant? = null
)

data class FuzzedLocation(
    val latitude: Double,
    val longitude: Double,
    val accuracyMeters: Double = 50.0
)

// ─── Hazard Reporter ─────────────────────────────────────────────────────────

class HazardReporter(
    private val context: Context,
    private val config: ReporterConfig = ReporterConfig()
) {
    data class ReporterConfig(
        val locationFuzzMeters: Double = 50.0,
        val timestampRoundMinutes: Long = 15,
        val hashRotationDays: Long = 7,
        val maxQueueSize: Int = 500,
        val syncBatchSize: Int = 50,
        val syncRetryCount: Int = 3
    )

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // In production: Room DAO for SQLite persistence
    private val reportQueue = mutableListOf<HazardReport>()

    /**
     * Create and queue a hazard report from an AI scene description.
     *
     * PRIVACY:
     * - Location is fuzzed to ±50m
     * - Timestamp is rounded to 15-minute intervals
     * - Device hash rotates weekly
     * - No images or audio are ever included
     */
    fun reportHazard(
        hazardType: HazardType,
        severity: Severity,
        description: String,
        location: Location,
        confidence: Float,
        contextTags: List<String> = emptyList()
    ): HazardReport {
        // Apply privacy transformations
        val fuzzed = fuzzLocation(location)
        val rounded = roundTimestamp(Instant.now())
        val hash = getRotatingDeviceHash()

        val report = HazardReport(
            hazardType = hazardType,
            severity = severity,
            description = sanitizeDescription(description),
            latitude = fuzzed.latitude,
            longitude = fuzzed.longitude,
            timestamp = rounded,
            deviceHash = hash,
            confidence = confidence,
            contextTags = contextTags
        )

        // Queue locally
        synchronized(reportQueue) {
            if (reportQueue.size < config.maxQueueSize) {
                reportQueue.add(report)
            }
        }

        // Attempt sync if online
        scope.launch { attemptSync() }

        return report
    }

    /**
     * Sync queued reports to backend.
     * Called automatically when connectivity changes.
     */
    suspend fun attemptSync() {
        val unsynced = synchronized(reportQueue) {
            reportQueue.filter { !it.synced }.take(config.syncBatchSize)
        }

        if (unsynced.isEmpty()) return

        try {
            // In production: HTTP POST to /api/v1/hazards/sync
            // val response = apiClient.post("/api/v1/hazards/sync") {
            //     body = BatchSyncRequest(reports = unsynced.map { it.toApi() })
            // }

            // Mark as synced
            synchronized(reportQueue) {
                unsynced.forEach { report ->
                    val idx = reportQueue.indexOf(report)
                    if (idx >= 0) {
                        reportQueue[idx] = report.copy(
                            synced = true,
                            syncedAt = Instant.now()
                        )
                    }
                }
            }
        } catch (e: Exception) {
            // Will retry on next connectivity change
            // Exponential backoff managed by WorkManager in production
        }
    }

    /**
     * Get count of pending (unsynced) reports.
     */
    fun getPendingCount(): Int = synchronized(reportQueue) {
        reportQueue.count { !it.synced }
    }

    // ─── Privacy Helpers ─────────────────────────────────────────────────────

    /**
     * Fuzz GPS coordinates by adding random offset within radius.
     * Prevents exact location tracking.
     */
    private fun fuzzLocation(location: Location): FuzzedLocation {
        val radiusDeg = config.locationFuzzMeters / 111_000.0 // ~111km per degree
        val angle = Math.random() * 2 * Math.PI
        val distance = Math.random() * radiusDeg

        return FuzzedLocation(
            latitude = (location.latitude + distance * Math.cos(angle))
                .toBigDecimal().setScale(3, java.math.RoundingMode.HALF_UP).toDouble(),
            longitude = (location.longitude + distance * Math.sin(angle))
                .toBigDecimal().setScale(3, java.math.RoundingMode.HALF_UP).toDouble()
        )
    }

    /**
     * Round timestamp to nearest 15-minute interval.
     * Prevents temporal fingerprinting.
     */
    private fun roundTimestamp(instant: Instant): Instant {
        val minutes = instant.epochSecond / 60
        val rounded = (minutes / config.timestampRoundMinutes) * config.timestampRoundMinutes
        return Instant.ofEpochSecond(rounded * 60)
    }

    /**
     * Generate a rotating anonymous device hash.
     * Changes every 7 days to prevent long-term tracking.
     */
    private fun getRotatingDeviceHash(): String {
        val weekNumber = Instant.now().epochSecond / (86400 * config.hashRotationDays)
        val seed = "${android.os.Build.FINGERPRINT}:${weekNumber}"
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(seed.toByteArray())
            .joinToString("") { "%02x".format(it) }
            .take(32)
    }

    /**
     * Remove any potential PII from AI-generated descriptions.
     */
    private fun sanitizeDescription(description: String): String {
        return description
            .replace(Regex("\\b\\d{3}[-.]?\\d{3}[-.]?\\d{4}\\b"), "[REDACTED]") // Phone numbers
            .replace(Regex("\\b[A-Z][a-z]+ [A-Z][a-z]+\\b"), "[NAME]")           // Names (naive)
            .replace(Regex("\\b\\d+ [A-Z][a-z]+ (St|Ave|Blvd|Rd)\\b"), "[ADDRESS]") // Addresses
            .take(500)
    }

    fun release() {
        scope.cancel()
    }
}

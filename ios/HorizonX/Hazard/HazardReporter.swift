import Foundation
import CoreLocation
import CryptoKit

// MARK: - Data Models

enum HazardType: String, Codable, CaseIterable {
    case pothole
    case brokenSignage = "broken_signage"
    case blockedSidewalk = "blocked_sidewalk"
    case missingRamp = "missing_ramp"
    case poorLighting = "poor_lighting"
    case crowdDensity = "crowd_density"
    case construction
    case flooding
    case brokenTrafficLight = "broken_traffic_light"
    case unevenSurface = "uneven_surface"
    case other
}

enum Severity: String, Codable {
    case low        // Minor inconvenience
    case medium     // Navigable but difficult
    case high       // Dangerous, needs immediate attention
    case critical   // Impassable, emergency
}

struct HazardReport: Codable, Identifiable {
    let id: UUID
    let hazardType: HazardType
    let severity: Severity
    let description: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let deviceHash: String
    let confidence: Float
    let contextTags: [String]
    var synced: Bool
    var syncedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case hazardType = "hazard_type"
        case severity, description, latitude, longitude, timestamp
        case deviceHash = "device_hash"
        case confidence
        case contextTags = "context_tags"
        case synced
        case syncedAt = "synced_at"
    }
}

/// API request model (matches backend schema)
struct HazardReportCreateAPI: Codable {
    let hazardType: String
    let severity: String
    let description: String
    let location: CoarseLocationAPI
    let timestamp: String
    let deviceHash: String
    let confidence: Float
    let contextTags: [String]
    
    enum CodingKeys: String, CodingKey {
        case hazardType = "hazard_type"
        case severity, description, location, timestamp
        case deviceHash = "device_hash"
        case confidence
        case contextTags = "context_tags"
    }
}

struct CoarseLocationAPI: Codable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    
    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case accuracyMeters = "accuracy_meters"
    }
}

// MARK: - Configuration

struct ReporterConfig {
    var locationFuzzMeters: Double = 50.0
    var timestampRoundMinutes: TimeInterval = 15 * 60 // 15 min in seconds
    var hashRotationDays: Int = 7
    var maxQueueSize: Int = 500
    var syncBatchSize: Int = 50
    var apiBaseURL: String = "http://localhost:8000/api/v1"
}

// MARK: - Hazard Reporter

/// Offline-first, privacy-preserving hazard reporter.
///
/// Handles:
///   - On-device hazard classification from scene descriptions
///   - Local queue for offline storage (UserDefaults / JSON file)
///   - Background sync when connectivity is restored
///   - Privacy: location fuzzing, timestamp rounding, rotating device hash
///
/// **Privacy guarantees:**
///   - Location fuzzed to ±50m (prevents exact tracking)
///   - Timestamp rounded to 15-minute intervals (prevents temporal fingerprinting)
///   - Device hash rotates weekly (prevents long-term correlation)
///   - Description sanitized to remove potential PII
///   - NO images, audio, or biometric data ever included
final class HazardReporter: ObservableObject {
    
    // MARK: - Published State
    
    @Published var pendingCount: Int = 0
    @Published var lastReportedHazard: HazardReport?
    
    // MARK: - Properties
    
    private let config: ReporterConfig
    private var reportQueue: [HazardReport] = []
    private let syncQueue = DispatchQueue(label: "com.horizonx.hazard.sync")
    private let persistenceURL: URL
    
    // URLSession for API calls
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
    
    // MARK: - Init
    
    init(config: ReporterConfig = ReporterConfig()) {
        self.config = config
        
        // Store queued reports in app's documents directory
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.persistenceURL = docs.appendingPathComponent("hazard_queue.json")
        
        // Load any previously queued (unsynced) reports
        loadQueue()
    }
    
    // MARK: - Report Hazard
    
    /// Create and queue a hazard report from an AI scene description.
    ///
    /// All privacy transformations are applied before storage.
    func reportHazard(
        hazardType: HazardType,
        severity: Severity,
        description: String,
        location: CLLocation,
        confidence: Float,
        contextTags: [String] = []
    ) -> HazardReport {
        // Apply privacy transformations
        let fuzzedLocation = fuzzLocation(location)
        let roundedTimestamp = roundTimestamp(Date())
        let deviceHash = getRotatingDeviceHash()
        let sanitized = sanitizeDescription(description)
        
        let report = HazardReport(
            id: UUID(),
            hazardType: hazardType,
            severity: severity,
            description: sanitized,
            latitude: fuzzedLocation.latitude,
            longitude: fuzzedLocation.longitude,
            timestamp: roundedTimestamp,
            deviceHash: deviceHash,
            confidence: confidence,
            contextTags: contextTags,
            synced: false,
            syncedAt: nil
        )
        
        // Queue locally (synchronous, safe for non-async context)
        syncQueue.sync {
            if reportQueue.count < config.maxQueueSize {
                reportQueue.append(report)
            }
        }
        
        saveQueue()
        updatePendingCount()
        
        DispatchQueue.main.async {
            self.lastReportedHazard = report
        }
        
        // Attempt sync in background
        Task { await attemptSync() }
        
        return report
    }
    
    // MARK: - Sync
    
    /// Sync queued reports to backend. Called when connectivity changes.
    func attemptSync() async {
        // Get unsynced reports on sync queue to avoid async context issues
        let unsynced: [HazardReport] = syncQueue.sync {
            Array(reportQueue.filter { !$0.synced }.prefix(config.syncBatchSize))
        }
        
        guard !unsynced.isEmpty else { return }
        
        // Build API request
        let locationFuzzMeters = config.locationFuzzMeters
        let apiReports = unsynced.map { report -> HazardReportCreateAPI in
            let isoFormatter = ISO8601DateFormatter()
            return HazardReportCreateAPI(
                hazardType: report.hazardType.rawValue,
                severity: report.severity.rawValue,
                description: report.description,
                location: CoarseLocationAPI(
                    latitude: report.latitude,
                    longitude: report.longitude,
                    accuracyMeters: locationFuzzMeters
                ),
                timestamp: isoFormatter.string(from: report.timestamp),
                deviceHash: report.deviceHash,
                confidence: report.confidence,
                contextTags: report.contextTags
            )
        }
        
        // POST to /api/v1/hazards/sync
        guard let url = URL(string: "\(config.apiBaseURL)/hazards/sync") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["reports": apiReports]
        request.httpBody = try? JSONEncoder().encode(body)
        
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            
            // Mark as synced on sync queue
            let syncedIds = Set(unsynced.map { $0.id })
            syncQueue.sync {
                for i in reportQueue.indices {
                    if syncedIds.contains(reportQueue[i].id) {
                        reportQueue[i].synced = true
                        reportQueue[i].syncedAt = Date()
                    }
                }
            }
            
            saveQueue()
            updatePendingCount()
            
        } catch {
            // Will retry on next connectivity change or app foreground
        }
    }
    
    // MARK: - Privacy Helpers
    
    /// Fuzz GPS coordinates by adding random offset within radius.
    /// Prevents exact location tracking while preserving neighborhood-level accuracy.
    private func fuzzLocation(_ location: CLLocation) -> (latitude: Double, longitude: Double) {
        let radiusDeg = config.locationFuzzMeters / 111_000.0  // ~111km per degree
        let angle = Double.random(in: 0...(2 * .pi))
        let distance = Double.random(in: 0...radiusDeg)
        
        let lat = (location.coordinate.latitude + distance * cos(angle))
        let lng = (location.coordinate.longitude + distance * sin(angle))
        
        // Round to 3 decimal places (~111m precision)
        return (
            latitude: (lat * 1000).rounded() / 1000,
            longitude: (lng * 1000).rounded() / 1000
        )
    }
    
    /// Round timestamp to nearest 15-minute interval.
    /// Prevents temporal fingerprinting of reports.
    private func roundTimestamp(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        let rounded = (seconds / config.timestampRoundMinutes).rounded() * config.timestampRoundMinutes
        return Date(timeIntervalSince1970: rounded)
    }
    
    /// Generate a rotating anonymous device hash.
    /// Changes every 7 days to prevent long-term device tracking.
    private func getRotatingDeviceHash() -> String {
        let weekNumber = Int(Date().timeIntervalSince1970) / (86400 * config.hashRotationDays)
        let vendorID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let seed = "\(vendorID):\(weekNumber)"
        
        let hash = SHA256.hash(data: Data(seed.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    
    /// Remove potential PII from AI-generated descriptions.
    private func sanitizeDescription(_ description: String) -> String {
        var sanitized = description
        
        // Remove phone numbers
        sanitized = sanitized.replacingOccurrences(
            of: #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
        
        // Remove potential street addresses (naive pattern)
        sanitized = sanitized.replacingOccurrences(
            of: #"\b\d+ [A-Z][a-z]+ (St|Ave|Blvd|Rd|Dr|Ln|Way)\b"#,
            with: "[ADDRESS]",
            options: .regularExpression
        )
        
        return String(sanitized.prefix(500))
    }
    
    // MARK: - Persistence
    
    private func saveQueue() {
        let data: Data? = syncQueue.sync {
            try? JSONEncoder().encode(reportQueue)
        }
        try? data?.write(to: persistenceURL)
    }
    
    private func loadQueue() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let loaded = try? JSONDecoder().decode([HazardReport].self, from: data) else {
            return
        }
        reportQueue = loaded
        updatePendingCount()
    }
    
    private func updatePendingCount() {
        let count: Int = syncQueue.sync {
            reportQueue.filter { !$0.synced }.count
        }
        DispatchQueue.main.async {
            self.pendingCount = count
        }
    }
}

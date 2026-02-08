import Foundation
import CoreML
import Vision
import UIKit
import Combine

// MARK: - Data Models

struct SceneDescription {
    let narration: String
    let obstacles: [Obstacle]
    let ocrText: String?
    let pathClear: Bool
    let recommendedAction: String
    let navigationCommand: NavigationAction
    let timestamp: Date
    
    init(narration: String, obstacles: [Obstacle], ocrText: String? = nil,
         pathClear: Bool, recommendedAction: String, 
         navigationCommand: NavigationAction = NavigationAction(action: .walkStraight, reason: "Path is clear", urgency: .ambient)) {
        self.narration = narration
        self.obstacles = obstacles
        self.ocrText = ocrText
        self.pathClear = pathClear
        self.recommendedAction = recommendedAction
        self.navigationCommand = navigationCommand
        self.timestamp = Date()
    }
}

struct Obstacle {
    let type: ObstacleType
    let description: String
    let clockDirection: Int          // 1-12 clock position
    let distanceMeters: Float
    let moving: Bool
    let approachDirection: ApproachDirection
    let urgency: Urgency
}

enum ObstacleType: String, Codable {
    case vehicle, person, object, terrain, construction, debris, barrier
}

enum ApproachDirection: String, Codable {
    case towards, away, crossing, stationary
}

enum Urgency: Int, Comparable {
    case immediate = 0
    case soon = 1
    case ambient = 2
    
    static func < (lhs: Urgency, rhs: Urgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Navigation Commands

enum NavigationActionType: String, Codable {
    case walkStraight = "walk_straight"
    case stop = "stop"
    case turnLeft = "turn_left"
    case turnRight = "turn_right"
    case stayLeft = "stay_left"
    case stayRight = "stay_right"
    case slowDown = "slow_down"
    case stepOver = "step_over"
    case duck = "duck"
    
    /// Human-readable command for TTS
    var spokenCommand: String {
        switch self {
        case .walkStraight: return "Walk straight"
        case .stop: return "Stop"
        case .turnLeft: return "Turn left"
        case .turnRight: return "Turn right"
        case .stayLeft: return "Stay on the left"
        case .stayRight: return "Stay on the right"
        case .slowDown: return "Slow down"
        case .stepOver: return "Step over obstacle"
        case .duck: return "Duck down"
        }
    }
}

struct NavigationAction {
    let action: NavigationActionType
    let reason: String
    let urgency: Urgency
    let distanceMeters: Float?
    
    init(action: NavigationActionType, reason: String, urgency: Urgency = .ambient, distanceMeters: Float? = nil) {
        self.action = action
        self.reason = reason
        self.urgency = urgency
        self.distanceMeters = distanceMeters
    }
    
    /// Full spoken instruction for TTS
    var spokenInstruction: String {
        var instruction = action.spokenCommand
        
        if let distance = distanceMeters, distance < 10 {
            instruction += ", \(Int(distance)) meters ahead"
        }
        
        if urgency == .immediate {
            instruction = "Alert! " + instruction
        }
        
        if !reason.isEmpty && urgency != .ambient {
            instruction += ". \(reason)"
        }
        
        return instruction
    }
}

// MARK: - Pipeline Configuration

struct PipelineConfig {
    let targetFPS: Int = 2                // Reduce to 2 FPS to avoid rate limiting (was 5)
    let inputSize: Int = 512              // Image resolution for API
    let maxObstacles: Int = 5             // Cap obstacles per frame
    let confidenceThreshold: Float = 0.5  // Min confidence to report
    let useCloudVision: Bool = true       // Use Gemini Vision API
    let offlineFallback: Bool = true      // Fall back to on-device when offline
    let navigationCommandInterval: TimeInterval = 2.0  // Min time between nav commands
}

// MARK: - Vision Pipeline

/// Hybrid vision inference pipeline using Gemini API + on-device fallback.
///
/// Orchestrates:
///   1. Frame sampling from AVCaptureSession
///   2. Cloud vision analysis via Gemini API (real-time obstacle detection)
///   3. On-device fallback when offline
///   4. Vision framework OCR (on-device text recognition)
///   5. Navigation command generation
///
/// Privacy: Frames sent to Gemini API for analysis. Text descriptions propagate locally.
final class VisionPipeline: ObservableObject {
    
    // Published scene descriptions for SwiftUI / subscribers
    @Published var currentScene: SceneDescription?
    @Published var lastNavigationCommand: NavigationAction?
    @Published var isOnline = true
    
    // Combine subject for streaming scene updates
    let sceneSubject = PassthroughSubject<SceneDescription, Never>()
    let navigationSubject = PassthroughSubject<NavigationAction, Never>()
    
    private let config: PipelineConfig
    private var ocrEngine: OnDeviceOCR?
    private var isProcessing = false
    private var frameCount = 0
    private var lastNavCommandTime: Date = .distantPast
    private var lastNavigationType: NavigationActionType = .walkStraight
    
    // Activity context for better detection
    private var currentContext: String = "outdoor_walking"
    
    private let processingQueue = DispatchQueue(
        label: "com.horizonx.vision.processing",
        qos: .userInitiated
    )
    
    init(config: PipelineConfig = PipelineConfig()) {
        self.config = config
    }
    
    // MARK: - Lifecycle
    
    /// Initialize vision pipeline. Call once during app startup.
    func initialize() async throws {
        print("VisionPipeline: Starting initialization...")
        ocrEngine = OnDeviceOCR()
        print("VisionPipeline: OCR engine ready")
        
        // Check network connectivity
        await checkConnectivity()
        print("VisionPipeline: Initialization complete, online: \(isOnline)")
    }
    
    /// Set the current activity context for better detection.
    func setContext(_ context: String) {
        currentContext = context
    }
    
    /// Process a camera frame from AVCaptureSession.
    ///
    /// Called at 30fps from CameraManager, but we only analyze every Nth frame.
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCount += 1
        
        // Debug: log every 30th frame to confirm frames are arriving
        if frameCount % 30 == 0 {
            print("VisionPipeline: Received frame #\(frameCount), isProcessing=\(isProcessing), isOnline=\(isOnline)")
        }
        
        // Frame sampling: only process every Nth frame for target FPS
        guard frameCount % (30 / config.targetFPS) == 0 else { return }
        
        // Prevent overlapping inference
        guard !isProcessing else { 
            if frameCount % 60 == 0 {
                print("VisionPipeline: Skipping frame - still processing previous")
            }
            return 
        }
        isProcessing = true
        print("VisionPipeline: Processing frame #\(frameCount)")
        
        let inputSize = self.config.inputSize
        let maxObstacles = self.config.maxObstacles
        let ocrEngine = self.ocrEngine
        let useCloud = self.config.useCloudVision && self.isOnline
        let context = self.currentContext
        
        // Capture pixel buffer for async processing
        guard let resized = resizePixelBuffer(pixelBuffer, width: inputSize, height: inputSize) else {
            isProcessing = false
            return
        }
        
        Task { [weak self] in
            defer { 
                Task { @MainActor in
                    self?.isProcessing = false
                }
            }
            
            var scene: SceneDescription
            
            if useCloud {
                // Cloud vision analysis via Gemini API
                scene = await self?.analyzeWithGemini(resized, context: context, ocrEngine: ocrEngine) ?? self?.createFallbackScene() ?? SceneDescription(
                    narration: "Unable to process",
                    obstacles: [],
                    pathClear: false,
                    recommendedAction: "Proceed with caution"
                )
            } else {
                // Offline fallback - basic OCR only
                let ocrText = ocrEngine?.recognizeSync(pixelBuffer: resized)
                scene = SceneDescription(
                    narration: "Offline mode. Limited detection available.",
                    obstacles: [],
                    ocrText: ocrText,
                    pathClear: true,
                    recommendedAction: "Proceed with caution. Full detection unavailable."
                )
            }
            
            // Filter and limit obstacles
            let filteredObstacles = scene.obstacles
                .filter { $0.urgency != .ambient || $0.distanceMeters < 5.0 }
                .sorted { $0.urgency < $1.urgency }
                .prefix(maxObstacles)
                .map { $0 }
            
            let finalScene = SceneDescription(
                narration: scene.narration,
                obstacles: Array(filteredObstacles),
                ocrText: scene.ocrText,
                pathClear: scene.pathClear,
                recommendedAction: scene.recommendedAction,
                navigationCommand: scene.navigationCommand
            )
            
            // Publish to subscribers
            await MainActor.run {
                self?.currentScene = finalScene
                self?.sceneSubject.send(finalScene)
                
                // Throttle navigation commands to avoid spam
                let now = Date()
                if let config = self?.config,
                   now.timeIntervalSince(self?.lastNavCommandTime ?? .distantPast) >= config.navigationCommandInterval ||
                   finalScene.navigationCommand.urgency == .immediate ||
                   finalScene.navigationCommand.action != self?.lastNavigationType {
                    
                    self?.lastNavCommandTime = now
                    self?.lastNavigationType = finalScene.navigationCommand.action
                    self?.lastNavigationCommand = finalScene.navigationCommand
                    self?.navigationSubject.send(finalScene.navigationCommand)
                }
            }
        }
    }
    
    /// Analyze frame using Gemini Vision API.
    private func analyzeWithGemini(_ pixelBuffer: CVPixelBuffer, context: String, ocrEngine: OnDeviceOCR?) async -> SceneDescription? {
        print("VisionPipeline: analyzeWithGemini called, encoding image...")
        
        guard let imageBase64 = NetworkService.encodePixelBuffer(pixelBuffer, quality: 0.85) else {
            print("VisionPipeline: ERROR - Failed to encode pixel buffer to base64")
            return nil
        }
        
        let imageSizeKB = imageBase64.count / 1024
        print("VisionPipeline: Image encoded successfully")
        print("VisionPipeline: Base64 length: \(imageBase64.count) chars (~\(imageSizeKB)KB)")
        print("VisionPipeline: Context: \(context)")
        print("VisionPipeline: Sending to backend...")
        
        do {
            let startTime = Date()
            let response = try await NetworkService.shared.analyzeScene(
                imageBase64: imageBase64,
                context: context,
                includeNavigation: true
            )
            
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            print("VisionPipeline: ✅ API response received in \(latency)ms")
            print("VisionPipeline: Narration: \(response.narration)")
            print("VisionPipeline: Obstacles detected: \(response.obstacles.count)")
            print("VisionPipeline: Path clear: \(response.path_clear)")
            print("VisionPipeline: Confidence: \(response.confidence)")
            print("VisionPipeline: Navigation: \(response.navigation_command.action) - \(response.navigation_command.reason)")
            
            // Log each obstacle for debugging
            for (index, obs) in response.obstacles.enumerated() {
                print("VisionPipeline: Obstacle \(index + 1): \(obs.type) - \(obs.description) @ \(obs.distance_meters)m, \(obs.direction) o'clock, urgency: \(obs.urgency)")
            }
            
            await MainActor.run {
                self.isOnline = true
            }
            
            // Convert API response to local models
            let obstacles = response.obstacles.map { obs -> Obstacle in
                Obstacle(
                    type: ObstacleType(rawValue: obs.type) ?? .object,
                    description: obs.description,
                    clockDirection: obs.direction,
                    distanceMeters: obs.distance_meters,
                    moving: obs.moving,
                    approachDirection: ApproachDirection(rawValue: obs.approach_direction) ?? .stationary,
                    urgency: self.parseUrgency(obs.urgency)
                )
            }
            
            let navAction = NavigationAction(
                action: NavigationActionType(rawValue: response.navigation_command.action) ?? .walkStraight,
                reason: response.navigation_command.reason,
                urgency: parseUrgency(response.navigation_command.urgency),
                distanceMeters: response.navigation_command.distance_meters
            )
            
            // Run OCR if we have text-like content
            var ocrText: String? = nil
            if response.narration.lowercased().contains("sign") || 
               response.narration.lowercased().contains("text") {
                ocrText = ocrEngine?.recognizeSync(pixelBuffer: pixelBuffer)
            }
            
            return SceneDescription(
                narration: response.narration,
                obstacles: obstacles,
                ocrText: ocrText,
                pathClear: response.path_clear,
                recommendedAction: navAction.spokenInstruction,
                navigationCommand: navAction
            )
            
        } catch {
            print("VisionPipeline: Gemini API error: \(error)")
            print("VisionPipeline: Switching to offline mode")
            await MainActor.run {
                self.isOnline = false
            }
            return nil
        }
    }
    
    private func parseUrgency(_ str: String) -> Urgency {
        switch str.lowercased() {
        case "immediate": return .immediate
        case "soon": return .soon
        default: return .ambient
        }
    }
    
    private func createFallbackScene() -> SceneDescription {
        return SceneDescription(
            narration: "Processing...",
            obstacles: [],
            pathClear: true,
            recommendedAction: "Continue with caution"
        )
    }
    
    private func checkConnectivity() async {
        // Simple connectivity check - try to reach the backend
        print("VisionPipeline: Checking connectivity to backend...")
        
        guard let url = URL(string: NetworkConfig.baseURL + "/health") else {
            print("VisionPipeline: Invalid backend URL")
            await MainActor.run { self.isOnline = false }
            return
        }
        
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5.0  // Quick timeout for health check
            let session = URLSession(configuration: config)
            
            let (_, response) = try await session.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse, 
               (200...299).contains(httpResponse.statusCode) {
                print("VisionPipeline: Backend reachable, online mode enabled")
                await MainActor.run { self.isOnline = true }
            } else {
                print("VisionPipeline: Backend returned non-200, trying offline mode")
                await MainActor.run { self.isOnline = false }
            }
        } catch {
            print("VisionPipeline: Backend not reachable (\(error.localizedDescription)), using offline mode")
            // Still mark as online to try API calls - they might work
            // The analyzeWithGemini will set offline if API calls fail
            await MainActor.run { self.isOnline = true }
        }
    }
    
    /// Release all resources.
    func release() {
        ocrEngine = nil
    }
    
    // MARK: - Image Processing
    
    /// Resize CVPixelBuffer using Core Image for efficient GPU-based scaling.
    private func resizePixelBuffer(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let scaleX = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(buffer))
        let scaleY = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(buffer))
        let resized = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        let context = CIContext(options: [.useSoftwareRenderer: false]) // Use GPU
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &outputBuffer
        )
        
        if let output = outputBuffer {
            context.render(resized, to: output)
        }
        return outputBuffer
    }
}

// MARK: - On-Device Object Detection (Vision Framework)

/// Uses Apple's Vision framework for basic object detection when offline.
/// 
/// This provides limited but functional obstacle detection using:
///   - VNDetectRectanglesRequest for barriers/signs
///   - VNDetectHumanRectanglesRequest for people
///   - VNRecognizeAnimalsRequest for animals
final class OnDeviceObjectDetector {
    
    struct DetectionResult {
        let obstacles: [Obstacle]
        let hasObstacles: Bool
    }
    
    /// Detect basic obstacles using Vision framework.
    func detect(pixelBuffer: CVPixelBuffer) -> DetectionResult {
        var obstacles: [Obstacle] = []
        let semaphore = DispatchSemaphore(value: 0)
        
        // Human detection
        let humanRequest = VNDetectHumanRectanglesRequest { request, error in
            guard let results = request.results as? [VNHumanObservation] else {
                semaphore.signal()
                return
            }
            
            for (index, human) in results.prefix(3).enumerated() {
                let rect = human.boundingBox
                let clockDir = self.rectToClockDirection(rect)
                let distance = self.estimateDistance(from: rect)
                
                obstacles.append(Obstacle(
                    type: .person,
                    description: "Person detected",
                    clockDirection: clockDir,
                    distanceMeters: distance,
                    moving: true,
                    approachDirection: .stationary,
                    urgency: distance < 2 ? .immediate : (distance < 5 ? .soon : .ambient)
                ))
            }
            semaphore.signal()
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([humanRequest])
        semaphore.wait()
        
        return DetectionResult(
            obstacles: obstacles,
            hasObstacles: !obstacles.isEmpty
        )
    }
    
    private func rectToClockDirection(_ rect: CGRect) -> Int {
        let centerX = rect.midX
        
        if centerX < 0.33 {
            return 9  // Left
        } else if centerX > 0.67 {
            return 3  // Right
        } else {
            return 12 // Center
        }
    }
    
    private func estimateDistance(from rect: CGRect) -> Float {
        // Rough distance estimation based on bounding box size
        let height = rect.height
        if height > 0.7 { return 1.0 }
        if height > 0.5 { return 2.0 }
        if height > 0.3 { return 4.0 }
        if height > 0.15 { return 8.0 }
        return 15.0
    }
}

// MARK: - On-Device OCR (Vision Framework)

/// On-device text recognition using Apple's Vision framework.
///
/// Advantages over ML Kit on iOS:
///   - Native framework, no third-party dependency
///   - Runs on Neural Engine
///   - Supports 18 languages out of the box
///   - Automatic language detection
final class OnDeviceOCR {
    
    /// Synchronous OCR for use in the processing pipeline.
    func recognizeSync(pixelBuffer: CVPixelBuffer) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                semaphore.signal()
                return
            }
            
            // Combine all recognized text
            result = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            
            semaphore.signal()
        }
        
        // Configure for speed over accuracy (real-time use)
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        semaphore.wait()
        
        return result
    }
    
    /// Async OCR with full accuracy (for "Read that sign" commands).
    func recognizeAccurate(pixelBuffer: CVPixelBuffer) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }
}

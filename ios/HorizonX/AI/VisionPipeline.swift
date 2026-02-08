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
    let targetFPS: Int = 5                // Process 5 frames per second for smooth detection
    let inputSize: Int = 512              // Image resolution for processing
    let maxObstacles: Int = 5             // Cap obstacles per frame
    let confidenceThreshold: Float = 0.5  // Min confidence to report
    let useCloudVision: Bool = false      // DISABLED: Use on-device detection instead of Gemini API
    let offlineFallback: Bool = true      // Fall back to on-device when offline
    let navigationCommandInterval: TimeInterval = 1.5  // Min time between nav commands
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
                // On-device detection using Apple Vision framework
                print("VisionPipeline: Using on-device detection")
                
                let detector = OnDeviceObjectDetector()
                let detectionResult = detector.detect(pixelBuffer: resized)
                let ocrText = ocrEngine?.recognizeSync(pixelBuffer: resized)
                
                // Generate narration based on detected obstacles
                let narration: String
                let recommendedAction: String
                var navCommand: NavigationAction
                
                if detectionResult.hasObstacles {
                    let obstacleDescriptions = detectionResult.obstacles.prefix(2).map { 
                        "\\($0.description) at \\(Int($0.distanceMeters))m" 
                    }.joined(separator: ", ")
                    narration = "Detected: \\(obstacleDescriptions)"
                    
                    // Determine recommended action based on most urgent obstacle
                    if let urgent = detectionResult.obstacles.first(where: { $0.urgency == .immediate }) {
                        recommendedAction = "Caution! \\(urgent.description) at \\(urgent.clockDirection) o'clock"
                        navCommand = NavigationAction(
                            action: urgent.clockDirection < 6 ? .stayRight : .stayLeft,
                            reason: urgent.description,
                            urgency: .immediate,
                            distanceMeters: urgent.distanceMeters
                        )
                    } else if let soon = detectionResult.obstacles.first(where: { $0.urgency == .soon }) {
                        recommendedAction = "\\(soon.description) ahead"
                        navCommand = NavigationAction(
                            action: .slowDown,
                            reason: soon.description,
                            urgency: .soon,
                            distanceMeters: soon.distanceMeters
                        )
                    } else {
                        recommendedAction = "Path has obstacles, proceed with awareness"
                        navCommand = NavigationAction(
                            action: .walkStraight,
                            reason: "Obstacles at safe distance",
                            urgency: .ambient
                        )
                    }
                } else {
                    narration = "Clear path ahead."
                    recommendedAction = "Path is clear, you may proceed."
                    navCommand = NavigationAction(
                        action: .walkStraight,
                        reason: "Path is clear",
                        urgency: .ambient
                    )
                }
                
                scene = SceneDescription(
                    narration: narration,
                    obstacles: detectionResult.obstacles,
                    ocrText: ocrText,
                    pathClear: detectionResult.pathClear,
                    recommendedAction: recommendedAction,
                    navigationCommand: navCommand
                )
                
                print("VisionPipeline: On-device detected \(detectionResult.obstacles.count) obstacles")
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

/// Uses Apple's Vision framework for comprehensive object detection.
/// 
/// This provides functional obstacle detection using:
///   - VNDetectHumanRectanglesRequest for people
///   - VNRecognizeAnimalsRequest for animals/dogs
///   - VNDetectRectanglesRequest for barriers/signs/objects
///   - VNDetectContoursRequest for general obstacles
///   - VNDetectFaceRectanglesRequest for people facing camera
final class OnDeviceObjectDetector {
    
    struct DetectionResult {
        let obstacles: [Obstacle]
        let hasObstacles: Bool
        let pathClear: Bool
    }
    
    /// Detect obstacles using multiple Vision framework requests.
    func detect(pixelBuffer: CVPixelBuffer) -> DetectionResult {
        var obstacles: [Obstacle] = []
        let group = DispatchGroup()
        let lock = NSLock()
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        // 1. Human/Body Detection
        group.enter()
        let humanRequest = VNDetectHumanRectanglesRequest { [self] request, error in
            defer { group.leave() }
            guard let results = request.results as? [VNHumanObservation] else { return }
            
            lock.lock()
            for human in results.prefix(3) {
                let rect = human.boundingBox
                let clockDir = self.rectToClockDirection(rect)
                let distance = self.estimateDistanceFromPerson(from: rect)
                
                obstacles.append(Obstacle(
                    type: .person,
                    description: results.count > 1 ? "Group of \\(results.count) people" : "Person ahead",
                    clockDirection: clockDir,
                    distanceMeters: distance,
                    moving: true,
                    approachDirection: .stationary,
                    urgency: distance < 2 ? .immediate : (distance < 4 ? .soon : .ambient)
                ))
            }
            lock.unlock()
        }
        humanRequest.upperBodyOnly = false
        
        // 2. Face Detection (indicates person facing toward you)
        group.enter()
        let faceRequest = VNDetectFaceRectanglesRequest { [self] request, error in
            defer { group.leave() }
            guard let results = request.results as? [VNFaceObservation], !results.isEmpty else { return }
            
            lock.lock()
            // Only add if no human was detected at similar position
            for face in results.prefix(2) {
                let rect = face.boundingBox
                let clockDir = self.rectToClockDirection(rect)
                let distance = self.estimateDistanceFromFace(from: rect)
                
                // Check if we already have a person at this location
                let hasPerson = obstacles.contains { 
                    $0.type == .person && abs($0.clockDirection - clockDir) <= 1 
                }
                
                if !hasPerson {
                    obstacles.append(Obstacle(
                        type: .person,
                        description: "Person facing you",
                        clockDirection: clockDir,
                        distanceMeters: distance,
                        moving: true,
                        approachDirection: .towards,
                        urgency: distance < 3 ? .immediate : .soon
                    ))
                }
            }
            lock.unlock()
        }
        
        // 3. Animal Detection (dogs, cats, etc.)
        group.enter()
        let animalRequest = VNRecognizeAnimalsRequest { [self] request, error in
            defer { group.leave() }
            guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
            
            lock.lock()
            for animal in results.prefix(2) {
                let rect = animal.boundingBox
                let clockDir = self.rectToClockDirection(rect)
                let distance = self.estimateDistance(from: rect)
                
                let animalType = animal.labels.first?.identifier ?? "Animal"
                obstacles.append(Obstacle(
                    type: .object,
                    description: "\\(animalType) detected",
                    clockDirection: clockDir,
                    distanceMeters: distance,
                    moving: true,
                    approachDirection: .stationary,
                    urgency: distance < 2 ? .immediate : (distance < 4 ? .soon : .ambient)
                ))
            }
            lock.unlock()
        }
        
        // 4. Rectangle Detection (signs, barriers, boxes, vehicles)
        group.enter()
        let rectangleRequest = VNDetectRectanglesRequest { [self] request, error in
            defer { group.leave() }
            guard let results = request.results as? [VNRectangleObservation] else { return }
            
            lock.lock()
            // Only report large rectangles (likely obstacles)
            for rect in results.prefix(3) {
                let boundingBox = rect.boundingBox
                
                // Filter out small rectangles (probably not obstacles)
                guard boundingBox.width > 0.15 && boundingBox.height > 0.15 else { continue }
                
                let clockDir = self.rectToClockDirection(boundingBox)
                let distance = self.estimateDistance(from: boundingBox)
                
                // Determine type based on position and size
                let obstacleType: ObstacleType
                let description: String
                
                if boundingBox.minY < 0.3 {
                    // Low object - likely ground obstacle
                    obstacleType = .terrain
                    description = "Ground obstacle"
                } else if boundingBox.width > 0.5 {
                    // Wide object - could be vehicle or barrier
                    obstacleType = .barrier
                    description = "Large obstacle or barrier"
                } else {
                    // Regular object
                    obstacleType = .object
                    description = "Object in path"
                }
                
                obstacles.append(Obstacle(
                    type: obstacleType,
                    description: description,
                    clockDirection: clockDir,
                    distanceMeters: distance,
                    moving: false,
                    approachDirection: .stationary,
                    urgency: distance < 2 ? .immediate : (distance < 4 ? .soon : .ambient)
                ))
            }
            lock.unlock()
        }
        rectangleRequest.minimumAspectRatio = 0.2
        rectangleRequest.maximumAspectRatio = 5.0
        rectangleRequest.minimumConfidence = 0.6
        rectangleRequest.minimumSize = 0.1
        
        // Perform all requests
        do {
            try handler.perform([humanRequest, faceRequest, animalRequest, rectangleRequest])
        } catch {
            print("OnDeviceObjectDetector: Vision request failed: \\(error)")
        }
        
        // Wait for all async results
        _ = group.wait(timeout: .now() + 0.5)
        
        // Remove duplicates (obstacles at same position)
        let uniqueObstacles = removeDuplicateObstacles(obstacles)
        
        // Sort by urgency (immediate first)
        let sortedObstacles = uniqueObstacles.sorted { $0.urgency.rawValue < $1.urgency.rawValue }
        
        // Determine if path is clear (no immediate or close obstacles in center)
        let pathClear = !sortedObstacles.contains { 
            ($0.clockDirection >= 11 || $0.clockDirection <= 1) && $0.distanceMeters < 4
        }
        
        return DetectionResult(
            obstacles: Array(sortedObstacles.prefix(5)),
            hasObstacles: !sortedObstacles.isEmpty,
            pathClear: pathClear
        )
    }
    
    private func removeDuplicateObstacles(_ obstacles: [Obstacle]) -> [Obstacle] {
        var unique: [Obstacle] = []
        for obstacle in obstacles {
            let isDuplicate = unique.contains {
                abs($0.clockDirection - obstacle.clockDirection) <= 1 &&
                abs($0.distanceMeters - obstacle.distanceMeters) < 2
            }
            if !isDuplicate {
                unique.append(obstacle)
            }
        }
        return unique
    }
    
    private func rectToClockDirection(_ rect: CGRect) -> Int {
        let centerX = rect.midX
        
        if centerX < 0.2 { return 9 }       // Far left
        if centerX < 0.35 { return 10 }     // Left
        if centerX < 0.45 { return 11 }     // Slight left
        if centerX < 0.55 { return 12 }     // Center
        if centerX < 0.65 { return 1 }      // Slight right
        if centerX < 0.8 { return 2 }       // Right
        return 3                             // Far right
    }
    
    private func estimateDistance(from rect: CGRect) -> Float {
        // Distance estimation based on bounding box size
        let size = max(rect.width, rect.height)
        if size > 0.7 { return 1.0 }
        if size > 0.5 { return 2.0 }
        if size > 0.35 { return 3.0 }
        if size > 0.25 { return 5.0 }
        if size > 0.15 { return 8.0 }
        return 12.0
    }
    
    private func estimateDistanceFromPerson(from rect: CGRect) -> Float {
        // Person-specific distance estimation (based on typical body proportions)
        let height = rect.height
        if height > 0.8 { return 0.5 }   // Very close
        if height > 0.6 { return 1.5 }   // Close
        if height > 0.4 { return 3.0 }   // Medium
        if height > 0.25 { return 5.0 }  // Far
        if height > 0.15 { return 8.0 }  // Very far
        return 12.0
    }
    
    private func estimateDistanceFromFace(from rect: CGRect) -> Float {
        // Face-specific distance estimation
        let size = max(rect.width, rect.height)
        if size > 0.4 { return 1.0 }
        if size > 0.25 { return 2.0 }
        if size > 0.15 { return 4.0 }
        if size > 0.08 { return 6.0 }
        return 10.0
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

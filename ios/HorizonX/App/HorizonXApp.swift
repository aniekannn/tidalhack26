import SwiftUI
import AVFoundation
import Speech
import CoreLocation
import Combine

// MARK: - App Entry Point
// NOTE: This file is NOT the main entry point. 
// The actual @main is in tidalhack26/tidalhack26App.swift

// @main  // DISABLED - using tidalhack26App.swift as entry point
struct HorizonXAppMain: App {
    @StateObject private var appCoordinator = AppCoordinator()
    
    var body: some Scene {
        WindowGroup {
            HorizonXView()
                .environmentObject(appCoordinator)
                .onAppear { appCoordinator.start() }
        }
    }
}

// MARK: - Main View (Voice-First, Minimal Visual UI)

/// The main view is intentionally minimal — HorizonX is voice-first.
/// The visual UI exists only for:
///   1. Sighted helpers who may assist the user
///   2. Demo/presentation purposes
///   3. Initial setup and permission granting
struct HorizonXView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Status header
                HStack {
                    Circle()
                        .fill(coordinator.isActive ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(coordinator.isActive ? "HorizonX Active" : "Starting...")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    if coordinator.hazardReporter.pendingCount > 0 {
                        Text("\(coordinator.hazardReporter.pendingCount) pending")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Current narration display (for sighted helpers / demo)
                if let scene = coordinator.visionPipeline.currentScene {
                    VStack(spacing: 12) {
                        Text(scene.narration)
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        if !scene.pathClear {
                            Text(scene.recommendedAction)
                                .font(.body)
                                .foregroundColor(.yellow)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.yellow.opacity(0.15))
                                .cornerRadius(12)
                        }
                        
                        if let ocr = scene.ocrText, !ocr.isEmpty {
                            Text("Text: \(ocr)")
                                .font(.callout)
                                .foregroundColor(.cyan)
                                .padding(.horizontal)
                        }
                        
                        // Obstacle indicators
                        ForEach(Array(scene.obstacles.enumerated()), id: \.offset) { _, obstacle in
                            HStack {
                                Image(systemName: obstacle.urgency == .immediate ? "exclamationmark.triangle.fill" : "info.circle")
                                    .foregroundColor(obstacle.urgency == .immediate ? .red : .orange)
                                Text("\(obstacle.description) — \(clockToDirection(obstacle.clockDirection)), \(Int(obstacle.distanceMeters))m")
                                    .font(.callout)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(.horizontal)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Scene: \(scene.narration). \(scene.recommendedAction)")
                }
                
                Spacer()
                
                // Voice command button (large tap target for accessibility)
                Button(action: { coordinator.toggleVoiceListening() }) {
                    ZStack {
                        Circle()
                            .fill(coordinator.isListening ? Color.red : Color.blue)
                            .frame(width: 80, height: 80)
                            .shadow(color: (coordinator.isListening ? Color.red : Color.blue).opacity(0.5), radius: 20)
                        
                        Image(systemName: coordinator.isListening ? "mic.fill" : "mic")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                }
                .accessibilityLabel(coordinator.isListening ? "Listening. Tap to stop." : "Tap to speak a command.")
                .accessibilityHint("Double tap to activate voice commands. Say Help for options.")
                .padding(.bottom, 40)
                
                // Help text
                Text("Tap mic or say \"Hey Horizon\" for voice commands")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.bottom, 20)
            }
        }
        .accessibilityElement(children: .contain)
    }
    
    private func clockToDirection(_ clock: Int) -> String {
        switch clock {
        case 12:     return "ahead"
        case 1, 2:   return "front-right"
        case 3:      return "right"
        case 4, 5:   return "back-right"
        case 6:      return "behind"
        case 7, 8:   return "back-left"
        case 9:      return "left"
        case 10, 11: return "front-left"
        default:     return "nearby"
        }
    }
}

// MARK: - App Coordinator

/// Central coordinator that wires all components together:
///   Camera → VisionPipeline → SpeechEngine
///   VoiceCommands → ActionRouter
///   HazardDetection → HazardReporter
@MainActor
final class AppCoordinator: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isActive = false
    @Published var isListening = false
    
    // MARK: - Components
    
    let visionPipeline = VisionPipeline()
    let speechEngine = SpeechEngine()
    let hazardReporter = HazardReporter()
    let cameraManager = CameraManager()
    
    // Voice recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // Location
    private let locationManager = CLLocationManager()
    
    // Subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    // Narration throttle
    private var lastNarrationTime: Date = .distantPast
    private let narrationInterval: TimeInterval = 10.0
    
    // MARK: - Lifecycle
    
    func start() {
        requestPermissions()
        
        speechEngine.speak("HorizonX ready. Tap the mic button or say a command. Say Help for options.", priority: .immediate)
        
        // Wire camera frames → vision pipeline
        cameraManager.onFrame = { [weak self] pixelBuffer in
            self?.visionPipeline.processFrame(pixelBuffer)
        }
        
        // Wire vision pipeline → speech engine + hazard detection
        visionPipeline.sceneSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scene in
                self?.handleSceneUpdate(scene)
            }
            .store(in: &cancellables)
        
        // Start camera first, then initialize vision models
        // This ensures video preview works while models load
        cameraManager.start()
        
        Task {
            do {
                speechEngine.speak("Initializing vision...", priority: .ambient)
                try await visionPipeline.initialize()
                await MainActor.run {
                    isActive = true
                }
                speechEngine.speak("Vision active. Scanning your surroundings.", priority: .ambient)
            } catch {
                // Even if vision model fails, camera is still running
                await MainActor.run {
                    isActive = true  // Mark as active anyway so UI shows running state
                }
                speechEngine.speak("Vision model failed to load. Basic features still available.", priority: .soon)
                print("Vision pipeline error: \(error)")
            }
        }
    }
    
    // MARK: - Scene Handling
    
    private func handleSceneUpdate(_ scene: SceneDescription) {
        // Priority 1: Immediate dangers with spatial audio
        for obstacle in scene.obstacles where obstacle.urgency == .immediate {
            speechEngine.speakAlert(
                "\(obstacle.description), \(Int(obstacle.distanceMeters)) meters, your \(clockToText(obstacle.clockDirection))",
                clockDirection: obstacle.clockDirection
            )
            triggerHaptic(.warning)
        }
        
        // Priority 2: Navigation commands (walk straight, stop, turn, etc.)
        let navCommand = scene.navigationCommand
        switch navCommand.action {
        case .stop:
            // Immediate stop command
            speechEngine.speakNavigation(navCommand)
            triggerHaptic(.error)
            
        case .turnLeft, .turnRight, .stayLeft, .stayRight:
            // Directional commands
            speechEngine.speakNavigation(navCommand)
            triggerHaptic(.warning)
            
        case .slowDown, .stepOver, .duck:
            // Caution commands
            speechEngine.speakNavigation(navCommand)
            triggerHaptic(.success)
            
        case .walkStraight:
            // Only announce periodically when path is clear
            let now = Date()
            if scene.pathClear && now.timeIntervalSince(lastNarrationTime) >= narrationInterval * 2 {
                lastNarrationTime = now
                speechEngine.speak("Path clear, continue straight.", priority: .ambient)
            }
        }
        
        // Priority 3: OCR text
        if let text = scene.ocrText, !text.isEmpty {
            speechEngine.speak("Text detected: \(text)", priority: .ambient)
        }
        
        // Priority 4: Ambient scene narration (throttled)
        let now = Date()
        if now.timeIntervalSince(lastNarrationTime) >= narrationInterval {
            lastNarrationTime = now
            if !scene.pathClear {
                speechEngine.speak(scene.narration, priority: .ambient)
            }
        }
    }
    
    // MARK: - Voice Commands
    
    func toggleVoiceListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }
    
    private func startListening() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            speechEngine.speak("Voice recognition not available.", priority: .soon)
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = false
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
        
        isListening = true
        triggerHaptic(.selection)
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result, result.isFinal {
                let command = result.bestTranscription.formattedString
                self.handleVoiceCommand(command)
            }
            
            if error != nil || (result?.isFinal ?? false) {
                self.stopListening()
            }
        }
        
        // Auto-stop after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.isListening == true {
                self?.stopListening()
            }
        }
    }
    
    private func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }
    
    private func handleVoiceCommand(_ command: String) {
        let lower = command.lowercased()
        
        if lower.contains("what") && (lower.contains("front") || lower.contains("around") || lower.contains("see")) {
            speechEngine.speak("Scanning now...", priority: .immediate)
            // Force a detailed scene description on next frame
            
        } else if lower.contains("read") || lower.contains("text") || lower.contains("sign") {
            speechEngine.speak("Reading text...", priority: .soon)
            // Trigger focused OCR mode
            
        } else if lower.contains("report") || lower.contains("hazard") || lower.contains("pothole") {
            // Quick hazard report from current scene
            if let scene = visionPipeline.currentScene {
                let location = locationManager.location ?? CLLocation(latitude: 0, longitude: 0)
                let report = hazardReporter.reportHazard(
                    hazardType: .other,
                    severity: .medium,
                    description: scene.narration,
                    location: location,
                    confidence: 0.7
                )
                speechEngine.speak("Hazard reported. \(hazardReporter.pendingCount) reports pending sync.", priority: .soon)
            } else {
                speechEngine.speak("No scene data available. Try again in a moment.", priority: .soon)
            }
            
        } else if lower.contains("repeat") || lower.contains("again") {
            speechEngine.repeatLast()
            
        } else if lower.contains("help") {
            speechEngine.speak(
                "Available commands: What's around me. Read that sign. Report a hazard. Repeat. Help.",
                priority: .immediate
            )
            
        } else if lower.contains("slow") {
            speechEngine.setRate(0.35)
            speechEngine.speak("Speaking slower now.", priority: .soon)
            
        } else if lower.contains("fast") {
            speechEngine.setRate(0.55)
            speechEngine.speak("Speaking faster now.", priority: .soon)
            
        } else {
            speechEngine.speak("I didn't catch that. Say Help for available commands.", priority: .soon)
        }
    }
    
    // MARK: - Permissions
    
    private func requestPermissions() {
        // Camera (handled by CameraManager)
        // Location
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        
        // Speech recognition
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                DispatchQueue.main.async {
                    self.speechEngine.speak(
                        "Microphone permission needed for voice commands. You can still use tap gestures.",
                        priority: .soon
                    )
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func clockToText(_ clock: Int) -> String {
        switch clock {
        case 12:     return "directly ahead"
        case 1, 2:   return "front right"
        case 3:      return "right"
        case 4, 5:   return "back right"
        case 6:      return "behind"
        case 7, 8:   return "back left"
        case 9:      return "left"
        case 10, 11: return "front left"
        default:     return "nearby"
        }
    }
    
    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    private func triggerHaptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

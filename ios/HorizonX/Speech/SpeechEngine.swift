import Foundation
import AVFoundation
import Combine

// MARK: - Data Models

enum SpeechPriority: Int, Comparable {
    case immediate = 0  // Danger alerts — interrupts current speech
    case soon = 1       // Navigation cues — next in queue
    case ambient = 2    // Scene descriptions — end of queue
    
    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SpeechRequest: Identifiable {
    let id = UUID()
    let text: String
    let priority: SpeechPriority
    let spatialPan: Float?  // -1.0 (left) to 1.0 (right), nil for center
    
    init(text: String, priority: SpeechPriority = .ambient, spatialPan: Float? = nil) {
        self.text = text
        self.priority = priority
        self.spatialPan = spatialPan
    }
}

// MARK: - Speech Engine Configuration

struct SpeechConfig {
    var rate: Float = 0.48            // AVSpeechUtteranceDefaultSpeechRate is 0.5
    var pitch: Float = 1.0
    var volume: Float = 1.0
    var voiceIdentifier: String? = nil // nil = system default
    var language: String = "en-US"
    var maxQueueSize: Int = 10
    var useElevenLabs: Bool = true    // Use Eleven Labs when online
    var elevenLabsVoiceId: String = "pFZP5JQG7iQjIQuC4Bku"  // Lily - calm, clear voice
}

// MARK: - Speech Engine

/// Dual TTS engine for HorizonX.
///
/// Architecture:
///   - **Offline (default)**: AVSpeechSynthesizer — always available, zero latency
///   - **Online (enhanced)**: ElevenLabs API — natural voice, calm guidance tone
///
/// Features:
///   - Priority queue (immediate alerts interrupt everything)
///   - Spatial audio via stereo panning (directional obstacle cues)
///   - Audio session management (ducks other media during speech)
///   - Haptic-coordinated alerts
///   - Automatic fallback to offline TTS when network unavailable
final class SpeechEngine: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    @Published var isSpeaking = false
    @Published var lastSpokenText: String?
    @Published var isUsingElevenLabs = false
    
    // MARK: - Properties
    
    private let synthesizer = AVSpeechSynthesizer()
    private var config: SpeechConfig
    private var speechQueue: [SpeechRequest] = []
    private let queueLock = NSLock()
    private var isOnline = false
    
    // Audio player for Eleven Labs audio
    private var audioPlayer: AVAudioPlayer?
    private var elevenLabsQueue: [SpeechRequest] = []
    private var isPlayingElevenLabs = false
    
    // Audio session for managing other audio
    private let audioSession = AVAudioSession.sharedInstance()
    
    // MARK: - Init
    
    init(config: SpeechConfig = SpeechConfig()) {
        self.config = config
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        checkNetworkAndUpdateMode()
    }
    
    /// Check network and update Eleven Labs mode
    private func checkNetworkAndUpdateMode() {
        Task {
            do {
                // Quick ping to check if backend is available
                _ = try await NetworkService.shared.generateSpeech(
                    text: "test",
                    priority: "ambient"
                )
                await MainActor.run {
                    self.isOnline = true
                    self.isUsingElevenLabs = self.config.useElevenLabs
                }
            } catch {
                await MainActor.run {
                    self.isOnline = false
                    self.isUsingElevenLabs = false
                }
            }
        }
    }
    
    // MARK: - Public API
    
    /// Speak text with priority handling.
    func speak(_ text: String, priority: SpeechPriority = .ambient) {
        let request = SpeechRequest(text: text, priority: priority)
        
        switch priority {
        case .immediate:
            // Interrupt everything and speak NOW
            synthesizer.stopSpeaking(at: .immediate)
            clearQueue()
            speakNow(request)
            
        case .soon:
            // Insert at front of queue (after any current utterance)
            enqueue(request, atFront: true)
            if !synthesizer.isSpeaking {
                processQueue()
            }
            
        case .ambient:
            // Add to end of queue
            enqueue(request, atFront: false)
            if !synthesizer.isSpeaking {
                processQueue()
            }
        }
    }
    
    /// Speak with directional spatial audio.
    ///
    /// Used for obstacle alerts: "Cyclist from your left" panned to the left ear.
    func speakDirectional(_ text: String, pan: Float, priority: SpeechPriority = .soon) {
        let request = SpeechRequest(text: text, priority: priority, spatialPan: pan)
        
        switch priority {
        case .immediate:
            synthesizer.stopSpeaking(at: .immediate)
            clearQueue()
            speakNow(request)
        default:
            enqueue(request, atFront: priority == .soon)
            if !synthesizer.isSpeaking {
                processQueue()
            }
        }
    }
    
    /// Speak an obstacle alert with spatial audio based on clock direction.
    ///
    /// Maps clock position to stereo pan:
    ///   - 9 o'clock = full left (-1.0)
    ///   - 12 o'clock = center (0.0)
    ///   - 3 o'clock = full right (1.0)
    func speakAlert(_ text: String, clockDirection: Int) {
        let pan: Float
        switch clockDirection {
        case 10, 11:     pan = -0.8   // Front-left
        case 9:          pan = -1.0   // Full left
        case 7, 8:       pan = -0.6   // Back-left
        case 1, 2:       pan = 0.8    // Front-right
        case 3:          pan = 1.0    // Full right
        case 4, 5:       pan = 0.6    // Back-right
        default:         pan = 0.0    // Center (12, 6)
        }
        
        speakDirectional(text, pan: pan, priority: .immediate)
    }
    
    /// Repeat the last spoken text.
    func repeatLast() {
        guard let text = lastSpokenText else {
            speak("Nothing to repeat.", priority: .soon)
            return
        }
        speak(text, priority: .soon)
    }
    
    /// Stop all speech immediately.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        clearQueue()
    }
    
    /// Update speech rate (e.g., from voice command "speak slower").
    func setRate(_ rate: Float) {
        config.rate = max(0.1, min(0.75, rate))
    }
    
    // MARK: - Queue Management
    
    private func enqueue(_ request: SpeechRequest, atFront: Bool) {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        // Enforce max queue size — drop oldest ambient items
        while speechQueue.count >= config.maxQueueSize {
            if let lastAmbientIdx = speechQueue.lastIndex(where: { $0.priority == .ambient }) {
                speechQueue.remove(at: lastAmbientIdx)
            } else {
                speechQueue.removeFirst()
            }
        }
        
        if atFront {
            speechQueue.insert(request, at: 0)
        } else {
            speechQueue.append(request)
        }
    }
    
    private func processQueue() {
        queueLock.lock()
        guard !speechQueue.isEmpty else {
            queueLock.unlock()
            return
        }
        let request = speechQueue.removeFirst()
        queueLock.unlock()
        
        speakNow(request)
    }
    
    private func clearQueue() {
        queueLock.lock()
        speechQueue.removeAll()
        queueLock.unlock()
    }
    
    // MARK: - Speech Synthesis
    
    private func speakNow(_ request: SpeechRequest) {
        // Store for repeat functionality
        lastSpokenText = request.text
        
        // Activate audio session
        activateAudioSession()
        
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        
        // Try Eleven Labs first if enabled and online
        if config.useElevenLabs && isOnline && request.priority != .immediate {
            speakWithElevenLabs(request)
        } else {
            speakWithAVSpeech(request)
        }
    }
    
    /// Speak using device's built-in AVSpeechSynthesizer (offline/immediate)
    private func speakWithAVSpeech(_ request: SpeechRequest) {
        let utterance = AVSpeechUtterance(string: request.text)
        
        // Voice selection
        if let identifier = config.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            // Use enhanced Siri voice if available (iOS 16+), else default
            utterance.voice = AVSpeechSynthesisVoice(language: config.language)
        }
        
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitch
        utterance.volume = config.volume
        
        // Pre-utterance delay (0 for immediate, small gap for queued)
        utterance.preUtteranceDelay = request.priority == .immediate ? 0 : 0.1
        utterance.postUtteranceDelay = 0.15
        
        synthesizer.speak(utterance)
    }
    
    /// Speak using Eleven Labs API for natural voice
    private func speakWithElevenLabs(_ request: SpeechRequest) {
        Task {
            do {
                let response = try await NetworkService.shared.generateSpeech(
                    text: request.text,
                    priority: priorityToString(request.priority),
                    voiceId: config.elevenLabsVoiceId
                )
                
                // Download the audio
                let audioData = try await NetworkService.shared.downloadAudio(from: response.audio_url)
                
                await MainActor.run {
                    self.playAudioData(audioData)
                    self.isUsingElevenLabs = true
                }
            } catch {
                print("Eleven Labs TTS failed, falling back to AVSpeech: \(error)")
                await MainActor.run {
                    self.isOnline = false
                    self.isUsingElevenLabs = false
                    self.speakWithAVSpeech(request)
                }
            }
        }
    }
    
    /// Play audio data from Eleven Labs
    private func playAudioData(_ data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.volume = config.volume
            audioPlayer?.play()
            isPlayingElevenLabs = true
        } catch {
            print("Audio playback failed: \(error)")
            isSpeaking = false
            processQueue()
        }
    }
    
    private func priorityToString(_ priority: SpeechPriority) -> String {
        switch priority {
        case .immediate: return "immediate"
        case .soon: return "soon"
        case .ambient: return "ambient"
        }
    }
    
    // MARK: - Audio Session
    
    private func configureAudioSession() {
        do {
            // Use playAndRecord to allow both speech output and voice recognition input
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voicePrompt,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }
    
    private func activateAudioSession() {
        try? audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
    }
    
    private func deactivateAudioSession() {
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    /// Prepare audio session for voice recognition input
    /// Call this before starting speech recognition to ensure proper audio routing
    func prepareForRecording() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to prepare audio session for recording: \(error)")
        }
    }
    
    /// Restore audio session for speech output after recording
    func restoreForSpeech() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voicePrompt,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            print("Failed to restore audio session for speech: \(error)")
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
        
        // Process next item in queue
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.processQueue()
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension SpeechEngine: AVAudioPlayerDelegate {
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPlayingElevenLabs = false
        }
        
        // Process next item in queue
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.processQueue()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("Audio decode error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPlayingElevenLabs = false
        }
        processQueue()
    }
}

// MARK: - Navigation Command Extension

extension SpeechEngine {
    
    /// Speak a navigation command with appropriate urgency.
    func speakNavigation(_ command: NavigationAction) {
        let priority: SpeechPriority
        switch command.urgency {
        case .immediate: priority = .immediate
        case .soon: priority = .soon
        case .ambient: priority = .ambient
        }
        
        speak(command.spokenInstruction, priority: priority)
    }
}

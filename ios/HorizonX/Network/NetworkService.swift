import Foundation
import Combine

// MARK: - Network Configuration

struct NetworkConfig {
    // For simulator: use localhost
    // For real device: use your Mac's local IP (e.g., 192.168.x.x:8000)
    // For production: use your deployed backend URL
    #if targetEnvironment(simulator)
    static let baseURL = "http://localhost:8000"
    #else
    // TODO: Replace with your Mac's local IP or production URL
    // Find your Mac's IP with: ifconfig | grep "inet " | grep -v 127.0.0.1
    static let baseURL = "http://10.247.222.228:8000"  // CHANGE THIS to your Mac's IP with port
    #endif
    
    static let timeoutInterval: TimeInterval = 30.0  // Increased for vision API calls
    static let retryCount = 2
}

// MARK: - API Request/Response Models

struct SceneEnhancementRequest: Codable {
    let base_description: String
    let activity_context: String
    let time_of_day: String
}

struct SceneEnhancementResponse: Codable {
    let enhanced_description: String
    let navigation_suggestion: String
    let confidence: Float
    let latency_ms: Int
}

struct TTSRequest: Codable {
    let text: String
    let priority: String
    let voice_id: String
}

struct TTSResponse: Codable {
    let audio_url: String
    let duration_seconds: Float
    let latency_ms: Int
}

struct VisionAnalysisRequest: Codable {
    let image_base64: String
    let context: String
    let include_navigation: Bool
}

struct VisionAnalysisResponse: Codable {
    let narration: String
    let obstacles: [ObstacleData]
    let navigation_command: NavigationCommand
    let path_clear: Bool
    let confidence: Float
    let latency_ms: Int
}

struct ObstacleData: Codable {
    let type: String
    let description: String
    let direction: Int
    let distance_meters: Float
    let moving: Bool
    let approach_direction: String
    let urgency: String
}

struct NavigationCommand: Codable {
    let action: String           // "walk_straight", "stop", "turn_left", "turn_right", "stay_left", "stay_right"
    let reason: String           // "Clear path ahead", "Obstacle detected", "Intersection ahead"
    let urgency: String          // "immediate", "soon", "ambient"
    let distance_meters: Float?  // Distance to action point
}

// MARK: - Network Errors

enum NetworkError: Error {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case serverError(Int)
    case decodingError(Error)
    case noInternetConnection
    case timeout
}

// MARK: - Network Service

/// Handles all API communication with the HorizonX backend.
/// 
/// Features:
///   - Async/await API
///   - Automatic retry with exponential backoff
///   - Offline detection and graceful degradation
///   - Request/response logging for debugging
final class NetworkService: ObservableObject {
    
    static let shared = NetworkService()
    
    @Published var isOnline = true
    
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = NetworkConfig.timeoutInterval
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Scene Enhancement (Gemini)
    
    /// Enhance an on-device scene description using Gemini API.
    /// 
    /// Privacy: Only sends TEXT, never raw images.
    func enhanceScene(
        baseDescription: String,
        activityContext: String = "walking",
        timeOfDay: String = "daytime"
    ) async throws -> SceneEnhancementResponse {
        let request = SceneEnhancementRequest(
            base_description: baseDescription,
            activity_context: activityContext,
            time_of_day: timeOfDay
        )
        
        return try await post(
            endpoint: "/api/v1/ai/enhance-scene",
            body: request
        )
    }
    
    // MARK: - Text-to-Speech (Eleven Labs)
    
    /// Generate natural speech audio using Eleven Labs.
    ///
    /// Returns the audio URL to stream or download.
    func generateSpeech(
        text: String,
        priority: String = "ambient",
        voiceId: String = "aria"
    ) async throws -> TTSResponse {
        let request = TTSRequest(
            text: text,
            priority: priority,
            voice_id: voiceId
        )
        
        return try await post(
            endpoint: "/api/v1/ai/tts",
            body: request
        )
    }
    
    // MARK: - Vision Analysis (Gemini Vision)
    
    /// Analyze an image for obstacles and generate navigation commands.
    ///
    /// This is the primary endpoint for real-time obstacle detection.
    func analyzeScene(
        imageBase64: String,
        context: String = "outdoor_walking",
        includeNavigation: Bool = true
    ) async throws -> VisionAnalysisResponse {
        let request = VisionAnalysisRequest(
            image_base64: imageBase64,
            context: context,
            include_navigation: includeNavigation
        )
        
        return try await post(
            endpoint: "/api/v1/ai/analyze-scene",
            body: request
        )
    }
    
    // MARK: - Audio Streaming
    
    /// Download TTS audio data for playback.
    func downloadAudio(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }
        
        return data
    }
    
    // MARK: - Private Helpers
    
    private func post<T: Encodable, R: Decodable>(
        endpoint: String,
        body: T,
        retries: Int = NetworkConfig.retryCount
    ) async throws -> R {
        guard let url = URL(string: NetworkConfig.baseURL + endpoint) else {
            print("NetworkService: ❌ Invalid URL: \(NetworkConfig.baseURL + endpoint)")
            throw NetworkError.invalidURL
        }
        
        print("NetworkService: 📤 POST \(endpoint)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        
        let bodySize = request.httpBody?.count ?? 0
        print("NetworkService: Request body size: \(bodySize / 1024)KB")
        
        var lastError: Error?
        
        for attempt in 0...retries {
            if attempt > 0 {
                print("NetworkService: Retry attempt \(attempt)/\(retries)")
            }
            
            do {
                let startTime = Date()
                let (data, response) = try await session.data(for: request)
                let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("NetworkService: ❌ Invalid response type")
                    throw NetworkError.invalidResponse
                }
                
                print("NetworkService: 📥 Response \(httpResponse.statusCode) in \(latency)ms, \(data.count) bytes")
                
                if (200...299).contains(httpResponse.statusCode) {
                    await MainActor.run { self.isOnline = true }
                    
                    do {
                        let decoded = try decoder.decode(R.self, from: data)
                        print("NetworkService: ✅ Successfully decoded response")
                        return decoded
                    } catch {
                        print("NetworkService: ❌ Decode error: \(error)")
                        if let responseStr = String(data: data, encoding: .utf8) {
                            print("NetworkService: Raw response: \(responseStr.prefix(500))...")
                        }
                        throw NetworkError.decodingError(error)
                    }
                } else {
                    print("NetworkService: ❌ Server error \(httpResponse.statusCode)")
                    if let responseStr = String(data: data, encoding: .utf8) {
                        print("NetworkService: Error body: \(responseStr.prefix(500))")
                    }
                    throw NetworkError.serverError(httpResponse.statusCode)
                }
            } catch let error as URLError {
                lastError = error
                print("NetworkService: ❌ URL Error: \(error.localizedDescription)")
                await MainActor.run { self.isOnline = false }
                
                // Exponential backoff
                if attempt < retries {
                    let delay = pow(2.0, Double(attempt)) * 0.5
                    print("NetworkService: Waiting \(delay)s before retry...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                lastError = error
                print("NetworkService: ❌ Error: \(error)")
            }
        }
        
        throw lastError ?? NetworkError.requestFailed(NSError(domain: "", code: -1))
    }
}

// MARK: - Image Encoding Helper

extension NetworkService {
    
    /// Convert CVPixelBuffer to base64-encoded JPEG for API transmission.
    static func encodePixelBuffer(_ buffer: CVPixelBuffer, quality: CGFloat = 0.7) -> String? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        
        guard let jpegData = uiImage.jpegData(compressionQuality: quality) else {
            return nil
        }
        
        return jpegData.base64EncodedString()
    }
}

import Foundation
import AVFoundation
import UIKit
import Combine

/// HorizonX — AVFoundation Camera Manager
///
/// Handles camera lifecycle, frame capture, and integration with
/// the VisionPipeline for on-device inference.
///
/// Key design decisions:
///   - Back camera only (user faces the world)
///   - 640×480 preset (sufficient for VLM, saves power)
///   - Drops frames if inference is behind (no buffering)
///   - No preview layer needed (voice-first UI, but optional for sighted helpers)
///
/// Privacy: Frames exist only in the AVCaptureSession output buffer.
///          Never written to Photos, disk, or network.
final class CameraManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    @Published var isRunning = false
    @Published var permissionGranted = false
    @Published var error: CameraError?
    
    enum CameraError: LocalizedError {
        case permissionDenied
        case setupFailed(String)
        case sessionFailed
        
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Camera permission is required for navigation assistance."
            case .setupFailed(let msg): return "Camera setup failed: \(msg)"
            case .sessionFailed: return "Camera session interrupted."
            }
        }
    }
    
    // MARK: - Properties
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.horizonx.camera.session")
    private let outputQueue = DispatchQueue(label: "com.horizonx.camera.output", qos: .userInitiated)
    
    /// Callback for each frame — wired to VisionPipeline.processFrame()
    var onFrame: ((CVPixelBuffer) -> Void)?
    
    // MARK: - Lifecycle
    
    /// Request camera permission and start capture.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            setupAndStart()
            
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.permissionGranted = granted
                    if granted {
                        self.setupAndStart()
                    } else {
                        self.error = .permissionDenied
                    }
                }
            }
            
        default:
            error = .permissionDenied
        }
    }
    
    /// Stop capture and release resources.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
        }
    }
    
    // MARK: - Setup
    
    private func setupAndStart() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .vga640x480  // 640×480, power-efficient
            
            // Input: back camera
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            ) else {
                DispatchQueue.main.async { self.error = .setupFailed("No back camera found") }
                return
            }
            
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }
                
                // Configure camera for best real-time performance
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
                
            } catch {
                DispatchQueue.main.async { self.error = .setupFailed(error.localizedDescription) }
                return
            }
            
            // Output: video frames
            self.videoOutput.setSampleBufferDelegate(self, queue: self.outputQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true  // Drop frames if behind
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }
            
            // Set video orientation to portrait
            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Extract pixel buffer and forward to vision pipeline
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // PRIVACY: This pixel buffer exists only in this callback scope.
        //          The VisionPipeline processes it in-memory and never persists it.
        onFrame?(pixelBuffer)
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame dropped — inference was slower than capture.
        // This is expected and fine. We prioritize latest frame via alwaysDiscardsLateVideoFrames.
    }
}

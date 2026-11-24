import AppKit
import AVFoundation
import SwiftUI

/// Webcam preview + movie recording for the demo session. Video only (no audio track), so it never
/// competes with Wave for the microphone. Recorded locally for tuning; nothing is uploaded.
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "wave.demo.camera")
    private var finished: (@Sendable () -> Void)?
    private(set) var isAvailable = false

    /// Picks the built-in camera. Returns false if there is none or it can't be used.
    func configure() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .high
        let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.first ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        isAvailable = true
        return true
    }

    func start() { queue.async { self.session.startRunning() } }

    func record(to url: URL) {
        queue.async {
            guard self.isAvailable, !self.output.isRecording else { return }
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stops recording (finalising the file) and the camera, then calls `done`.
    func stop(_ done: @escaping @Sendable () -> Void) {
        queue.async {
            if self.output.isRecording {
                self.finished = done
                self.output.stopRecording()
            } else {
                self.session.stopRunning()
                done()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        queue.async {
            self.session.stopRunning()
            let done = self.finished
            self.finished = nil
            done?()
        }
    }
}

/// Mirrored live webcam view (like a mirror, so left is left).
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

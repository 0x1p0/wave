import AppKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Webcam for the demo session: a live preview, plus small JPEG snapshots (4 per second) for tuning.
/// No video encoding — a screen recorder running at the same time needs the hardware encoder, and the two
/// fighting over it is what killed the camera before. Nothing is uploaded.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "wave.demo.camera")
    private let context = CIContext()
    private var observers: [NSObjectProtocol] = []
    private(set) var isAvailable = false

    // Snapshot state (camera queue only)
    private var snapshotDirectory: URL?
    private var clockStart: Date?
    private var lastSnapshot = -1.0
    private let interval = 0.25

    /// Picks the built-in camera. Returns false if there is none or it can't be used.
    func configure() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .medium
        let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.first ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        isAvailable = true

        // If something else interrupts the camera, bring it back.
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    if !self.session.isRunning { self.session.startRunning() }
                }
            })
        }
        return true
    }

    func start() { queue.async { self.session.startRunning() } }

    /// Starts saving snapshots named by seconds since `clock`.
    func snapshot(to directory: URL, clock: Date) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.async {
            self.snapshotDirectory = directory
            self.clockStart = clock
        }
    }

    func stop(_ done: @escaping @Sendable () -> Void) {
        queue.async {
            self.snapshotDirectory = nil
            self.session.stopRunning()
            done()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let dir = snapshotDirectory, let start = clockStart else { return }
        let t = Date().timeIntervalSince(start)
        guard t - lastSnapshot >= interval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSnapshot = t
        // Mirror (like the preview) and scale to 480 px wide.
        var image = CIImage(cvPixelBuffer: pixels)
        let scale = 480 / max(1, image.extent.width)
        image = image.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        let url = dir.appendingPathComponent(String(format: "%07.2f.jpg", t))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        CGImageDestinationFinalize(dest)
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

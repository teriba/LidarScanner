import ARKit
import SceneKit
import SwiftUI

/// Face scan with the front TrueDepth camera. Shows the tracked face mesh as a wireframe
/// and captures it with the camera image as texture. See FaceCapture for the export.
final class FaceScanController: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    let arView = ARSCNView(frame: .zero)

    @Published private(set) var isFaceTracked = false

    /// Geometry is averaged over this long to reduce jitter.
    private static let burstDuration: TimeInterval = 0.5
    /// Gives up if no tracked face shows up for this long.
    private static let timeout: TimeInterval = 3

    private var continuation: CheckedContinuation<FaceCapture, Error>?
    private var burstStart: TimeInterval?
    private var sums: [SIMD3<Float>] = []
    private var sampleCount = 0

    override init() {
        super.init()
        arView.delegate = self
        arView.session.delegate = self
        arView.automaticallyUpdatesLighting = true
    }

    func start() {
        arView.session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        arView.session.pause()
        finish(.failure(CancellationError()))
    }

    /// Collects face geometry for a short burst and returns it with the last frame.
    /// On the main actor because the session delegate reads the same state on the main queue.
    @MainActor
    func capture() async throws -> FaceCapture {
        finish(.failure(CancellationError()))
        return try await withCheckedThrowingContinuation { continuation in
            burstStart = nil
            sums = []
            sampleCount = 0
            self.continuation = continuation
        }
    }

    private func finish(_ result: Result<FaceCapture, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    // MARK: ARSessionDelegate, called on the main queue

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let face = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first { $0.isTracked }
        if isFaceTracked != (face != nil) { isFaceTracked = face != nil }

        guard continuation != nil else { return }
        let start = burstStart ?? frame.timestamp
        burstStart = start

        if let face {
            let vertices = face.geometry.vertices
            if sums.count != vertices.count {
                sums = [SIMD3<Float>](repeating: .zero, count: vertices.count)
                sampleCount = 0
            }
            for index in vertices.indices { sums[index] += vertices[index] }
            sampleCount += 1

            if frame.timestamp - start >= Self.burstDuration {
                let scale = 1 / Float(sampleCount)
                finish(.success(FaceCapture(
                    vertices: sums.map { $0 * scale },
                    indices: face.geometry.triangleIndices,
                    transform: face.transform,
                    frame: frame
                )))
                return
            }
        }
        if frame.timestamp - start >= Self.timeout {
            finish(.failure(FaceCapture.CaptureError.noFace))
        }
    }

    // MARK: ARSCNViewDelegate, called on the render thread

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard anchor is ARFaceAnchor, let device = arView.device,
              let geometry = ARSCNFaceGeometry(device: device) else { return nil }
        let material = geometry.firstMaterial
        material?.fillMode = .lines
        material?.lightingModel = .constant
        material?.diffuse.contents = UIColor.white.withAlphaComponent(0.6)
        return SCNNode(geometry: geometry)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let face = anchor as? ARFaceAnchor, let geometry = node.geometry as? ARSCNFaceGeometry else { return }
        geometry.update(from: face.geometry)
    }
}

private struct FaceViewContainer: UIViewRepresentable {
    let controller: FaceScanController

    func makeUIView(context: Context) -> ARSCNView { controller.arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct FaceScanView: View {
    let outputURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = FaceScanController()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            FaceViewContainer(controller: controller)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .padding(10)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                Text(hint)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Button {
                    capture()
                } label: {
                    if isSaving { ProgressView() } else { Text("Capture") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !controller.isFaceTracked)
                .padding(.top, 8)
            }
            .padding()
        }
        .keepScreenOn()
        .onAppear { controller.start() }
        .onDisappear { controller.pause() }
    }

    private var hint: String {
        if isSaving { return "Hold still." }
        if !controller.isFaceTracked { return "No face found. Hold the phone 25 to 50 cm from your face." }
        return "Look straight at the camera, neutral expression."
    }

    private func capture() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let capture = try await controller.capture()
                try capture.write(to: outputURL)
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

import ARKit
import RealityKit
import SwiftUI

/// Raw LiDAR scene reconstruction. Captures everything the sensor sees (rooms, outdoor
/// spaces, large objects) as an untextured triangle mesh and exports it as OBJ.
/// See MeshConversion for what can be done with the file afterwards.
final class MeshScanController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var meshChunkCount = 0

    override init() {
        super.init()
        arView.session.delegate = self
        arView.debugOptions.insert(.showSceneUnderstanding)
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        // Classification labels each face as wall, floor, etc. The export keeps the labels,
        // and the room and object conversions use them.
        configuration.sceneReconstruction =
            ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : .mesh
        configuration.environmentTexturing = .none
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        arView.session.pause()
    }

    /// Pauses the session so the mesh buffers stop changing, then writes all chunks in world space.
    func export(to url: URL) throws {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        pause()
        try MeshExporter.export(anchors, to: url)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updateCount(session) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { updateCount(session) }

    private func updateCount(_ session: ARSession) {
        meshChunkCount = session.currentFrame?.anchors.filter { $0 is ARMeshAnchor }.count ?? 0
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let controller: MeshScanController

    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct MeshScanView: View {
    let outputURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = MeshScanController()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Restart") { controller.start() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .padding(10)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                Text("Sweep the camera slowly over every surface. \(controller.meshChunkCount) mesh chunks.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text("Save mesh") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || controller.meshChunkCount == 0)
                .padding(.top, 8)
            }
            .padding()
        }
        .keepScreenOn()
        .onAppear { controller.start() }
        .onDisappear { controller.pause() }
    }

    private func save() {
        isSaving = true
        Task {
            // Let the progress indicator render before the synchronous export.
            await Task.yield()
            do {
                try controller.export(to: outputURL)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                controller.start()
            }
            isSaving = false
        }
    }
}

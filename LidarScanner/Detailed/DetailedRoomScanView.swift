import ARKit
import RoomPlan
import SwiftUI

/// Room scan that keeps the detail. RoomPlan and ARKit scene reconstruction run on one
/// shared ARSession, so the RoomPlan room and the raw mesh are in the same world space
/// and need no alignment.
final class DetailedRoomScanModel: NSObject, ObservableObject, RoomCaptureViewDelegate {
    let arSession = ARSession()
    let captureView: RoomCaptureView
    let recorder = RoomKeyframeRecorder()

    @Published private(set) var isScanning = false
    @Published private(set) var result: CapturedRoom?
    @Published private(set) var meshChunkCount = 0
    @Published var errorMessage: String?
    /// The raw mesh, copied when the scan stops.
    private(set) var mesh = TriMesh()

    private var timer: Timer?
    private var meshRequests = 0
    /// RoomPlan may run its own configuration again. Give up after this many tries
    /// so the two do not restart each other forever.
    private static let maxMeshRequests = 5

    override init() {
        captureView = RoomCaptureView(frame: .zero, arSession: arSession)
        super.init()
        captureView.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func start() {
        guard !isScanning, result == nil else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        recorder.start(session: arSession)
        meshRequests = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        isScanning = true
    }

    /// RoomPlan starts the session with its own world tracking configuration, which has
    /// no scene reconstruction. Run the same configuration again with the mesh turned on.
    /// Without reset options, tracking and anchors carry over.
    private func tick() {
        meshChunkCount = arSession.currentFrame?.anchors.filter { $0 is ARMeshAnchor }.count ?? 0
        guard meshRequests < Self.maxMeshRequests,
              let current = arSession.configuration as? ARWorldTrackingConfiguration,
              current.sceneReconstruction == [],
              let configuration = current.copy() as? ARWorldTrackingConfiguration else { return }
        let wanted: ARConfiguration.SceneReconstruction =
            ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : .mesh
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(wanted) else { return }
        configuration.sceneReconstruction = wanted
        meshRequests += 1
        arSession.run(configuration)
    }

    func stop() {
        guard isScanning else { return }
        timer?.invalidate()
        timer = nil
        recorder.stop()
        // Take the anchors before RoomPlan pauses the session.
        let anchors = arSession.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        captureView.captureSession.stop()
        mesh = MeshExporter.mesh(from: anchors)
        meshChunkCount = anchors.count
        isScanning = false
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            errorMessage = error.localizedDescription
        } else {
            result = processedResult
        }
    }
}

private struct DetailedRoomCaptureContainer: UIViewRepresentable {
    let model: DetailedRoomScanModel

    func makeUIView(context: Context) -> RoomCaptureView { model.captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct DetailedRoomScanView: View {
    let outputURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DetailedRoomScanModel()
    @State private var worker: Task<Void, Error>?
    @State private var fraction = 0.0
    @State private var stage = ""

    var body: some View {
        ZStack {
            DetailedRoomCaptureContainer(model: model)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") {
                        worker?.cancel()
                        model.stop()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if model.isScanning {
                        Button("Done") { model.stop() }
                            .buttonStyle(.borderedProminent)
                    } else if worker == nil, model.result != nil {
                        Button("Save") { save() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
                if let message = model.errorMessage {
                    Text(message)
                        .padding(10)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                if worker != nil {
                    VStack(spacing: 8) {
                        ProgressView(value: fraction)
                        Text(stage).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .keepScreenOn()
        .onAppear { model.start() }
    }

    private var status: String {
        if model.meshChunkCount == 0 {
            return model.isScanning
                ? "Waiting for the detail mesh. Move slowly around the room."
                : "No detail mesh was captured. Furniture will be saved as boxes."
        }
        return model.isScanning
            ? "Detail mesh: \(model.meshChunkCount) chunks. Look at every piece of furniture from all sides."
            : "Detail mesh: \(model.meshChunkCount) chunks."
    }

    private func save() {
        guard let room = model.result else { return }
        let mesh = model.mesh
        let keyframes = model.recorder.keyframes
        let url = outputURL
        model.errorMessage = nil
        let task = Task.detached(priority: .userInitiated) {
            try DetailedRoomBuilder.build(room: room, mesh: mesh, keyframes: keyframes, output: url) { fraction, stage in
                Task { @MainActor in
                    // Updates hop to the main actor one by one and can arrive out of order.
                    guard fraction >= self.fraction else { return }
                    self.fraction = fraction
                    self.stage = stage
                }
            }
        }
        worker = task
        Task {
            do {
                try await task.value
                dismiss()
            } catch is CancellationError {
            } catch {
                model.errorMessage = error.localizedDescription
            }
            worker = nil
            fraction = 0
        }
    }
}

import RealityKit
import SwiftUI

/// Guided object capture (ObjectCaptureSession), then on-device reconstruction to USDZ
/// (PhotogrammetrySession). Same pipeline as Apple's Reality Composer app.
@MainActor
@Observable
final class ObjectCaptureModel {
    enum Phase {
        case capturing
        case reconstructing(progress: Double)
        case failed(String)
        case done
    }

    private(set) var session: ObjectCaptureSession?
    private(set) var captureState: ObjectCaptureSession.CaptureState = .initializing
    var scanPassComplete = false
    private(set) var phase: Phase = .capturing

    let outputURL: URL
    private let workDir: URL
    private var imagesDir: URL { workDir.appending(path: "Images", directoryHint: .isDirectory) }
    private var checkpointDir: URL { workDir.appending(path: "Checkpoint", directoryHint: .isDirectory) }

    init(outputURL: URL) {
        self.outputURL = outputURL
        workDir = FileManager.default.temporaryDirectory
            .appending(path: "ObjectCapture-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func start() {
        guard session == nil, case .capturing = phase else { return }
        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let session = ObjectCaptureSession()
        // Subscribe before start, otherwise early state changes (like .ready) can be missed.
        let stateUpdates = session.stateUpdates
        let passUpdates = session.userCompletedScanPassUpdates
        Task { [weak self] in
            for await state in stateUpdates {
                self?.handle(state)
            }
        }
        Task { [weak self] in
            for await completed in passUpdates {
                self?.scanPassComplete = completed
            }
        }

        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointDir
        session.start(imagesDirectory: imagesDir, configuration: configuration)
        self.session = session
        captureState = session.state
    }

    func startDetecting() { _ = session?.startDetecting() }
    func resetDetection() { session?.resetDetection() }
    func startCapturing() { session?.startCapturing() }
    func finishCapture() { session?.finish() }

    func newPass(flipped: Bool) {
        scanPassComplete = false
        if flipped {
            session?.beginNewScanPassAfterFlip()
        } else {
            session?.beginNewScanPass()
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        cleanUp()
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        captureState = state
        switch state {
        case .completed:
            // The capture session must be released before reconstruction can use the GPU.
            session = nil
            Task { await reconstruct() }
        case .failed(let error):
            session = nil
            phase = .failed(error.localizedDescription)
            cleanUp()
        default:
            break
        }
    }

    private func reconstruct() async {
        phase = .reconstructing(progress: 0)
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpointDir
            let photogrammetry = try PhotogrammetrySession(input: imagesDir, configuration: configuration)
            try photogrammetry.process(requests: [.modelFile(url: outputURL)])

            for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    phase = .reconstructing(progress: fraction)
                case .requestError(_, let error):
                    throw error
                case .processingCancelled:
                    phase = .failed("Reconstruction was cancelled.")
                case .processingComplete:
                    phase = .done
                default:
                    break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        cleanUp()
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workDir)
    }
}

struct ObjectScanView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ObjectCaptureModel

    init(outputURL: URL) {
        _model = State(initialValue: ObjectCaptureModel(outputURL: outputURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .capturing:
                captureContent
            case .reconstructing(let progress):
                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 260)
                    Text("Building 3D model… \(Int(progress * 100))%")
                    Text("Keep the app open. This can take a few minutes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Close") { dismiss() }
                }
            case .done:
                ContentUnavailableView {
                    Label("Model saved", systemImage: "checkmark.circle")
                } actions: {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .keepScreenOn()
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var captureContent: some View {
        if let session = model.session {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
        }
        VStack {
            HStack {
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            Spacer()
            Text(hint)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            controls
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
    }

    private var hint: String {
        switch model.captureState {
        case .initializing: "Starting camera…"
        case .ready: "Point at the object and tap Continue."
        case .detecting: "Adjust the box around the object, then start capturing."
        case .capturing where model.scanPassComplete: "Pass complete. Scan again from another height, flip the object, or finish."
        case .capturing: "Walk slowly around the object."
        case .finishing: "Finishing capture…"
        default: ""
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.captureState {
        case .ready:
            Button("Continue") { model.startDetecting() }
        case .detecting:
            HStack {
                Button("Reset box") { model.resetDetection() }
                Button("Start capture") { model.startCapturing() }
            }
        case .capturing:
            if model.scanPassComplete {
                HStack {
                    Button("New pass") { model.newPass(flipped: false) }
                    Button("Flip object") { model.newPass(flipped: true) }
                    Button("Finish") { model.finishCapture() }
                }
            } else {
                Button("Finish") { model.finishCapture() }
            }
        case .finishing:
            ProgressView()
        default:
            EmptyView()
        }
    }
}

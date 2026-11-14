import RoomPlan
import SwiftUI

/// Whole-room scan with RoomPlan. Exports a parametric USDZ: walls, doors, windows
/// and furniture as clean labelled boxes.
final class RoomScanModel: NSObject, ObservableObject, RoomCaptureViewDelegate {
    let captureView = RoomCaptureView(frame: .zero)

    @Published private(set) var isScanning = false
    @Published private(set) var result: CapturedRoom?
    @Published var errorMessage: String?

    override init() {
        super.init()
        captureView.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func start() {
        guard !isScanning, result == nil else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    func stop() {
        guard isScanning else { return }
        captureView.captureSession.stop()
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

private struct RoomCaptureContainer: UIViewRepresentable {
    let model: RoomScanModel

    func makeUIView(context: Context) -> RoomCaptureView { model.captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    let outputURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RoomScanModel()

    var body: some View {
        ZStack {
            RoomCaptureContainer(model: model)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") {
                        model.stop()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if model.isScanning {
                        Button("Done") { model.stop() }
                            .buttonStyle(.borderedProminent)
                    } else if model.result != nil {
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
            }
            .padding()
        }
        .keepScreenOn()
        .onAppear { model.start() }
    }

    private func save() {
        guard let room = model.result else { return }
        do {
            try room.export(to: outputURL, exportOptions: .parametric)
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

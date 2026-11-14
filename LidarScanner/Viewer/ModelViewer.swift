import QuickLook
import SceneKit
import SwiftUI

struct ModelViewer: View {
    let scan: SavedScan

    @State private var scene: SCNScene?
    @State private var errorMessage: String?
    @State private var showAR = false

    var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could not open model",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if scan.url.pathExtension == "usdz" {
                Button { showAR = true } label: {
                    Image(systemName: "arkit")
                }
            }
            ShareLink(item: scan.url)
        }
        .fullScreenCover(isPresented: $showAR) {
            QuickLookPreview(url: scan.url).ignoresSafeArea()
        }
        .task {
            do {
                scene = try SCNScene(url: scan.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// AR Quick Look: place a USDZ in the real world at true scale.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in dismiss() }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

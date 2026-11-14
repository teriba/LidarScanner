import QuickLook
import SceneKit
import SwiftUI

struct ModelViewer: View {
    let scan: SavedScan

    @State private var scene: SCNScene?
    @State private var errorMessage: String?

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
                Button { ARQuickLook.present(scan.url) } label: {
                    Image(systemName: "arkit")
                }
            }
            ShareLink(item: scan.url)
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
/// Presented directly from UIKit so Quick Look shows its own close button. Wrapped in a
/// SwiftUI cover, the AR view hides the navigation bar and there is no way back.
@MainActor
private enum ARQuickLook {
    private static var dataSource: DataSource?

    static func present(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }

        let source = DataSource(url: url)
        dataSource = source
        let controller = QLPreviewController()
        controller.dataSource = source
        top.present(controller, animated: true)
    }

    private final class DataSource: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

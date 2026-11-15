import QuickLook
import SceneKit
import SwiftUI

struct ModelViewer: View {
    let scan: SavedScan

    @Environment(ScanStore.self) private var store
    @State private var scene: SCNScene?
    @State private var errorMessage: String?
    @State private var running: RunningConversion?
    @State private var conversionError: String?
    @State private var converted: SavedScan?

    var body: some View {
        if scan.kind == .detailed, DetailedRoomPackage(model: scan.url).exists {
            DetailedRoomEditor(scan: scan)
        } else {
            viewer
        }
    }

    private var viewer: some View {
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
        .overlay {
            if let running { ConversionProgress(running: running) }
        }
        .toolbar {
            if scan.url.pathExtension == "usdz" {
                Button { ARQuickLook.present(scan.url) } label: {
                    Image(systemName: "arkit")
                }
            }
            if scan.kind == .mesh {
                Menu {
                    ForEach(MeshConversion.allCases) { conversion in
                        Button { start(conversion) } label: {
                            Label(conversion.title, systemImage: conversion.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .disabled(running != nil)
            }
            ShareLink(item: scan.url)
        }
        .navigationDestination(item: $converted) { ModelViewer(scan: $0) }
        .alert("Conversion failed", isPresented: Binding(
            get: { conversionError != nil },
            set: { if !$0 { conversionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversionError ?? "")
        }
        .onDisappear { running?.worker.cancel() }
        .task {
            do {
                scene = try SCNScene(url: scan.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension ModelViewer {
    /// Runs a mesh conversion in the background and opens the result. The result is
    /// saved as a new scan, the original file stays as it is.
    private func start(_ conversion: MeshConversion) {
        let input = scan.url
        let output = store.newFileURL(forResultOf: conversion)
        let state = RunningConversion(title: conversion.title)
        state.worker = Task.detached(priority: .userInitiated) {
            try conversion.run(input: input, output: output) { fraction, stage in
                Task { @MainActor in state.report(fraction, stage) }
            }
        }
        running = state
        Task {
            do {
                try await state.worker.value
                store.reload()
                converted = store.scan(at: output)
            } catch is CancellationError {
            } catch {
                conversionError = error.localizedDescription
            }
            if running === state { running = nil }
        }
    }
}

/// Progress of one conversion, updated from the worker.
@MainActor
@Observable
private final class RunningConversion {
    let title: String
    private(set) var fraction = 0.0
    private(set) var stage = ""
    var worker = Task<Void, Error> {}

    init(title: String) { self.title = title }

    func report(_ fraction: Double, _ stage: String) {
        // Updates hop to the main actor one by one and can arrive out of order.
        guard fraction >= self.fraction else { return }
        self.fraction = fraction
        self.stage = stage
    }
}

private struct ConversionProgress: View {
    let running: RunningConversion

    var body: some View {
        VStack(spacing: 12) {
            Text(running.title).font(.headline)
            ProgressView(value: running.fraction)
            Text(running.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { running.worker.cancel() }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// AR Quick Look: place a USDZ in the real world at true scale.
/// Presented directly from UIKit so Quick Look shows its own close button. Wrapped in a
/// SwiftUI cover, the AR view hides the navigation bar and there is no way back.
@MainActor
enum ARQuickLook {
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

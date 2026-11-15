import SceneKit
import SwiftUI

/// Edit state of an open detailed room. Changes only touch the scene in memory.
/// Saving writes a new scan, the opened one stays as it is.
@MainActor
@Observable
final class DetailedRoomEditorModel {
    let package: DetailedRoomPackage

    private(set) var manifest = DetailedRoomManifest()
    private(set) var scene: SCNScene?
    private(set) var selectedID: String?
    private(set) var isDirty = false
    var errorMessage: String?

    private static let nudgeStep: Float = 0.05
    /// Object scans picked in this session, by replacement file name. They are copied
    /// into the new sidecar when the room is saved.
    private var pickedSources: [String: URL] = [:]

    init(package: DetailedRoomPackage) {
        self.package = package
    }

    var selected: DetailedRoomManifest.Item? {
        manifest.items.first { $0.id == selectedID }
    }

    var itemIDs: Set<String> { Set(manifest.items.map(\.id)) }

    func load() async {
        guard scene == nil else { return }
        let package = package
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let manifest = try package.readManifest()
                return (manifest, DetailedRoomScene.make(package: package, manifest: manifest))
            }.value
            manifest = loaded.0
            scene = loaded.1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ id: String?) {
        if let current = selected, let node = node(current.id) {
            DetailedRoomScene.setHighlight(false, node: node, item: current)
        }
        selectedID = id
        if let item = selected, let node = node(item.id) {
            DetailedRoomScene.setHighlight(true, node: node, item: item)
        }
    }

    func setDisplay(_ display: DetailedRoomManifest.Display) {
        change { $0.display = display }
    }

    /// Puts an object scan in place of the selected box, at real size.
    func replace(with scan: SavedScan) {
        let file = scan.url.lastPathComponent
        pickedSources[file] = scan.url
        change {
            $0.replacement = DetailedRoomManifest.Replacement(file: file, title: scan.name)
            $0.display = .replacement
        }
    }

    func setFitToBox(_ fit: Bool) {
        change { $0.replacement?.fitToBox = fit }
    }

    func rotate() {
        change {
            let turns = $0.replacement?.quarterTurns ?? 0
            $0.replacement?.quarterTurns = (turns + 1) % 4
        }
    }

    /// Moves the replacement along the box axes, in steps of 5 cm.
    func nudge(x: Float, z: Float) {
        change {
            let offset = ($0.replacement?.nudgeVector ?? .zero) + SIMD3(x, 0, z) * Self.nudgeStep
            $0.replacement?.nudge = [offset.x, offset.y, offset.z]
        }
    }

    func setShowLooseDetail(_ show: Bool) {
        guard manifest.hasLooseDetail, show != manifest.showLooseDetail, let scene else { return }
        manifest.showLooseDetail = show
        isDirty = true
        let name = DetailedRoomPackage.looseDetailName
        scene.rootNode.childNode(withName: name, recursively: false)?.removeFromParentNode()
        if show, let node = DetailedRoomScene.looseDetailNode(package: package) {
            scene.rootNode.addChildNode(node)
        }
    }

    /// Writes the edited room as a new scan: a copy of the sidecar with the new manifest,
    /// and a fresh USDZ.
    func save(to output: URL) async throws {
        let source = package
        let manifest = manifest
        let picked = pickedSources
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let target = DetailedRoomPackage(model: output)
            do {
                try files.copyItem(at: source.folder, to: target.folder)
                try files.createDirectory(at: target.replacementsFolder, withIntermediateDirectories: true)
                // Keep only the object scans that are still in use.
                let used = Set(manifest.items.compactMap { $0.replacement?.file })
                for file in (try? files.contentsOfDirectory(atPath: target.replacementsFolder.path)) ?? []
                where !used.contains(file) {
                    try? files.removeItem(at: target.replacementURL(file))
                }
                for file in used where !files.fileExists(atPath: target.replacementURL(file).path) {
                    guard let url = picked[file] else { continue }
                    try files.copyItem(at: url, to: target.replacementURL(file))
                }
                try target.write(manifest)
                try DetailedRoomScene.export(package: target, manifest: manifest, to: output)
            } catch {
                try? files.removeItem(at: target.folder)
                throw error
            }
        }.value
        isDirty = false
    }

    private func node(_ id: String) -> SCNNode? {
        scene?.rootNode.childNode(withName: id, recursively: false)
    }

    private func change(_ edit: (inout DetailedRoomManifest.Item) -> Void) {
        guard let index = manifest.items.firstIndex(where: { $0.id == selectedID }) else { return }
        var item = manifest.items[index]
        edit(&item)
        guard item != manifest.items[index] else { return }
        manifest.items[index] = item
        isDirty = true
        guard let node = node(item.id) else { return }
        let package = package
        let picked = pickedSources
        DetailedRoomScene.update(node, item: item, package: package) { file in
            picked[file] ?? package.replacementURL(file)
        }
    }
}

/// Viewer for a detailed room. Tap a piece of furniture to select it, then switch it
/// between scan mesh and box, or replace it with an object scan.
struct DetailedRoomEditor: View {
    let scan: SavedScan

    @Environment(ScanStore.self) private var store
    @State private var model: DetailedRoomEditorModel
    @State private var isPicking = false
    @State private var isSaving = false
    @State private var saved: SavedScan?

    init(scan: SavedScan) {
        self.scan = scan
        _model = State(initialValue: DetailedRoomEditorModel(package: DetailedRoomPackage(model: scan.url)))
    }

    var body: some View {
        Group {
            if let scene = model.scene {
                EditorSceneView(scene: scene, itemIDs: model.itemIDs) { model.select($0) }
                    .ignoresSafeArea(edges: .bottom)
            } else if let message = model.errorMessage {
                ContentUnavailableView(
                    "Could not open model",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let item = model.selected {
                ItemPanel(model: model, item: item) { isPicking = true }
            } else if model.scene != nil {
                Text("Tap a piece of furniture to edit it.")
                    .font(.callout)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 8)
            }
        }
        .overlay {
            if isSaving {
                ProgressView("Saving as a new scan")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isDirty {
                Button("Save") { save() }
                    .disabled(isSaving)
            }
            if model.manifest.hasLooseDetail {
                Menu {
                    Toggle("Show other scanned detail", isOn: Binding(
                        get: { model.manifest.showLooseDetail },
                        set: { model.setShowLooseDetail($0) }
                    ))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            Button { ARQuickLook.present(scan.url) } label: {
                Image(systemName: "arkit")
            }
            ShareLink(item: scan.url)
        }
        .sheet(isPresented: $isPicking) {
            ObjectScanPicker(scans: store.scans.filter { $0.kind == .object && $0.url.pathExtension.lowercased() == "usdz" }) {
                model.replace(with: $0)
            }
        }
        .navigationDestination(item: $saved) { ModelViewer(scan: $0) }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.scene != nil && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.load() }
    }

    /// Saves the edit as a new scan and opens it. AR Quick Look and sharing use the
    /// saved file, so they show edits only after this.
    private func save() {
        let output = store.newEditedRoomURL()
        isSaving = true
        Task {
            do {
                try await model.save(to: output)
                store.reload()
                saved = store.scan(at: output)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct ItemPanel: View {
    let model: DetailedRoomEditorModel
    let item: DetailedRoomManifest.Item
    let pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.category.capitalized).font(.headline)
                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.select(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            Picker("Show as", selection: Binding(get: { item.display }, set: { model.setDisplay($0) })) {
                if item.hasMesh { Text("Scan mesh").tag(DetailedRoomManifest.Display.mesh) }
                Text("Box").tag(DetailedRoomManifest.Display.box)
                if item.replacement != nil { Text("Object scan").tag(DetailedRoomManifest.Display.replacement) }
            }
            .pickerStyle(.segmented)

            if item.display == .replacement, let replacement = item.replacement {
                Text(replacement.title).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Toggle("Fit to box", isOn: Binding(get: { replacement.fitToBox }, set: { model.setFitToBox($0) }))
                        .fixedSize()
                    Spacer()
                    Button { model.rotate() } label: { Image(systemName: "rotate.right") }
                    Button { model.nudge(x: -1, z: 0) } label: { Image(systemName: "arrow.left") }
                    Button { model.nudge(x: 1, z: 0) } label: { Image(systemName: "arrow.right") }
                    Button { model.nudge(x: 0, z: -1) } label: { Image(systemName: "arrow.up") }
                    Button { model.nudge(x: 0, z: 1) } label: { Image(systemName: "arrow.down") }
                }
                .buttonStyle(.bordered)
            }
            Button(action: pick) {
                Label(item.replacement == nil ? "Replace with object scan" : "Pick another object scan", systemImage: "cube.transparent")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var sizeText: String {
        let size = item.pose.dimensions
        return String(format: "%.2f × %.2f × %.2f m (width, height, depth)", size.x, size.y, size.z)
    }
}

private struct ObjectScanPicker: View {
    let scans: [SavedScan]
    let pick: (SavedScan) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(scans) { scan in
                Button {
                    pick(scan)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(scan.name, systemImage: scan.kind.systemImage)
                        Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if scans.isEmpty {
                    ContentUnavailableView(
                        "No object scans",
                        systemImage: "cube.transparent",
                        description: Text("Scan an object first. It can then stand in for a box.")
                    )
                }
            }
            .navigationTitle("Object scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// SCNView with camera control and tap selection. SwiftUI's SceneView has no hit testing.
private struct EditorSceneView: UIViewRepresentable {
    let scene: SCNScene
    let itemIDs: Set<String>
    let onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemBackground
        view.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        )
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.itemIDs = itemIDs
        context.coordinator.onSelect = onSelect
    }

    final class Coordinator: NSObject {
        var itemIDs: Set<String> = []
        var onSelect: (String?) -> Void = { _ in }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? SCNView else { return }
            let hits = view.hitTest(recognizer.location(in: view), options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
            ])
            // Results come nearest first. Walls in front are skipped, so furniture can
            // be picked from outside the room too.
            for hit in hits where hit.node.name != DetailedRoomScene.highlightName {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, itemIDs.contains(name) {
                        onSelect(name)
                        return
                    }
                    node = current.parent
                }
            }
            onSelect(nil)
        }
    }
}

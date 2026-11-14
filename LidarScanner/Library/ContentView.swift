import SwiftUI

struct ContentView: View {
    @Environment(ScanStore.self) private var store
    @State private var activeScan: ScanKind?

    var body: some View {
        NavigationStack {
            List {
                ForEach(ScanKind.allCases) { kind in
                    let items = store.scans.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Section(kind.sectionTitle) {
                            ForEach(items) { scan in
                                NavigationLink(value: scan) { ScanRow(scan: scan) }
                            }
                            .onDelete { offsets in
                                offsets.map { items[$0] }.forEach(store.delete)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.scans.isEmpty {
                    ContentUnavailableView(
                        "No scans yet",
                        systemImage: "cube.transparent",
                        description: Text("Tap + to scan an object, a room or a face.")
                    )
                }
            }
            .navigationTitle("Scans")
            .navigationDestination(for: SavedScan.self) { ModelViewer(scan: $0) }
            .toolbar {
                Menu {
                    ForEach(ScanKind.allCases) { kind in
                        Button { activeScan = kind } label: {
                            Label(kind.menuTitle, systemImage: kind.systemImage)
                        }
                        .disabled(!kind.isSupported)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
            .refreshable { store.reload() }
            .onAppear { store.reload() }
            .fullScreenCover(item: $activeScan, onDismiss: { store.reload() }) { kind in
                switch kind {
                case .object: ObjectScanView(outputURL: store.newFileURL(for: .object))
                case .room: RoomScanView(outputURL: store.newFileURL(for: .room))
                case .mesh: MeshScanView(outputURL: store.newFileURL(for: .mesh))
                case .face: FaceScanView(outputURL: store.newFileURL(for: .face))
                }
            }
        }
    }
}

private struct ScanRow: View {
    let scan: SavedScan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(scan.name, systemImage: scan.kind.systemImage)
            Text("\(scan.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: scan.byteCount, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

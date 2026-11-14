import SwiftUI

@main
struct LidarScannerApp: App {
    @State private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}

extension View {
    /// Stops the screen from dimming while a scan is running.
    func keepScreenOn() -> some View {
        onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

import SwiftUI

@main
struct SkyfiApp: App {
    @State private var traffic = TrafficStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(traffic)
                .environment(Mixer.shared)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Audio keeps playing in the background; only the map polling stops.
            traffic.setActive(phase == .active)
        }
    }
}

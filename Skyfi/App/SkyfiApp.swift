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
                .environment(TalkStore.shared)
                .onAppear {
                    dlog("app", "launch: \(DebugLog.header().replacingOccurrences(of: "\n", with: " · "))")
                    TalkStore.shared.connect(traffic: traffic)
                }
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Audio keeps playing in the background; only the map polling stops.
            dlog("app", "scene \(phase)")
            traffic.setActive(phase == .active)
            TalkStore.shared.foreground = phase == .active
        }
    }
}

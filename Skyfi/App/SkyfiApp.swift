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
                .onAppear { TalkStore.shared.connect(traffic: traffic) }
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Audio keeps playing in the background; only the map polling stops.
            traffic.setActive(phase == .active)
            TalkStore.shared.foreground = phase == .active
        }
    }
}

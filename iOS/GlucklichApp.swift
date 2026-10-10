import SwiftUI

@main
struct GlucklichApp: App {
    @StateObject private var model = AppStore()
    @StateObject private var health = HealthStore()
    @StateObject private var watch = WatchLink()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(health)
                .environmentObject(watch)
                .tint(.teal)
        }
    }
}

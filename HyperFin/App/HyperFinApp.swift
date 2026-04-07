import SwiftUI
import SwiftData

@main
struct HyperFinApp: App {
    let dependencies: AppDependencies

    init() {
        dependencies = AppDependencies()
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
        }
        .modelContainer(dependencies.modelContainer)
    }
}

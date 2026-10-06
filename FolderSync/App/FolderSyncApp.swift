import SwiftUI

@main
struct FolderSyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1040, height: 720)
        #endif
    }
}

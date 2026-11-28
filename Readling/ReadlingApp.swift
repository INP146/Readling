import SwiftUI

@main
struct ReadlingApp: App {
    /// The one library store. It is made here, where it is made once, and not as a view's `@State` default: that
    /// expression runs every time the view is created, and a store starts migrating and rebuilding books as it is
    /// made, so each extra one rebuilt the same books and wrote the library again (and, by changing observed state
    /// while the app's body was being evaluated, caused yet another).
    @State private var store: LibraryStore

    init() {
        // UI tests launch with `-freshLibrary` to start from an empty library of their own, leaving the reader's
        // books and places alone.
        let fresh = ProcessInfo.processInfo.arguments.contains("-freshLibrary")
        _store = State(initialValue: LibraryStore(fileURL: fresh
            ? URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "library.json") : nil))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .tint(.accent)
        }
    }
}

extension URL {
    /// Everything the app keeps: the library, books, downloaded dictionaries and the reader's background.
    static let appData = URL.applicationSupportDirectory.appendingPathComponent("Readling", isDirectory: true)
}

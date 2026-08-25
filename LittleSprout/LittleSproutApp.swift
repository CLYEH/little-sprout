import SwiftUI

@main
struct LittleSproutApp: App {
    @State private var authStore: AuthStore

    init() {
        let client = SupabaseClientFactory.makeClient()
        _authStore = State(initialValue: AuthStore(authService: SupabaseAuthService(client: client)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(authStore: authStore)
        }
    }
}

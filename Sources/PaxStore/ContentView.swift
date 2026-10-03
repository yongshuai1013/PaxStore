import SwiftUI
import SideSign

struct ContentView: View {
    @State private var appleID = ""
    @State private var isLoggedIn = false

    var body: some View {
        MainTabView(appleID: $appleID, isLoggedIn: $isLoggedIn, onLogout: doLogout)
            .onAppear {
                if PaxAuthService.shared.restoreSession() {
                    if let savedID = PaxAuthService.shared.currentAppleID {
                        appleID = savedID
                    }
                    isLoggedIn = true
                }
            }
    }

    private func doLogout() {
        PaxAuthService.shared.logout()
        isLoggedIn = false
        appleID = ""
    }
}

import SwiftUI
import LocalAuthentication
struct AppLockView: View { @State private var unlocked=false; var body: some View { Group { if unlocked { WebContainerView(url: URL(string: "https://your-domain.example")!) } else { VStack(spacing:16){Image(systemName:"lock.shield").font(.system(size:48));Text("航的助手").font(.title2);Button("解锁") { authenticate() }} } }.task { authenticate() } }
    private func authenticate(){let context=LAContext();var error:NSError?;guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error:&error) else {unlocked=true;return};context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"保护你的教务数据") { success,_ in DispatchQueue.main.async { unlocked=success }}}
}

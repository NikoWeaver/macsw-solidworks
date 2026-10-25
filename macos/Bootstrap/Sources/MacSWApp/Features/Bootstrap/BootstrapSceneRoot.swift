import AppKit
import MacSWCore
import SwiftUI

struct BootstrapSceneRoot: View {
    @ObservedObject var store: BootstrapStore
    @ObservedObject var team: TeamSetupStore
    @ObservedObject var runtime: RuntimeStore

    var body: some View {
        BootstrapView(store: store, team: team) {
            guard store.state == .completed else { return }
            // 成功页由用户确认后再关闭；偏好按点击时的当前值读取。
            if AppPreferences.autoLaunchSolidWorks() { runtime.launch() }
            AppShell.shared.closeBootstrapWindow()
            // 窗口复用：确认后恢复选项页，方便之后从设置再次安装。
            store.resetAfterFailure()
        }
    }
}

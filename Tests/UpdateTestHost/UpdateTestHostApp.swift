import Sparkle
import SwiftUI

@main
struct UpdateTestHostApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("Lurume 更新测试") {
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)

                Text("Sparkle 沙盒更新测试")
                    .font(.title2.weight(.semibold))

                Text("版本 \(displayVersion)（构建 \(buildVersion)）")
                    .foregroundStyle(.secondary)

                Button("检查测试更新…") {
                    updaterController.checkForUpdates(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: 360, height: 220)
            .padding()
        }
    }

    private var displayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    }
}

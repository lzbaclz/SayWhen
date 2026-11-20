import SwiftUI
import SwiftData
import AppIntents
import UserNotifications

@MainActor @Observable final class AppRoute {
    static let shared = AppRoute()
    var capture = false
    var itemID: UUID?
}

struct RecordTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "在说到录入待办"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppRoute.shared.capture = true
        return .result()
    }
}

struct Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordTaskIntent(), phrases: ["用\(.applicationName)记待办"], shortTitle: "录入待办", systemImageName: "mic.fill")
    }
}

final class Delegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["id"] as? String
        Task { @MainActor in
            if let raw { AppRoute.shared.itemID = UUID(uuidString: raw) }
            completionHandler()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main struct SayWhenApp: App {
    @UIApplicationDelegateAdaptor(Delegate.self) var delegate
    @State private var launch: Result<TaskStore, Error>

    init() {
        _launch = State(initialValue: Result { try Self.openStore() })
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch launch {
                case .success(let store): TaskList(store: store)
                case .failure(let error):
                    ContentUnavailableView {
                        Label("暂时无法打开清单", systemImage: "tray")
                    } description: { Text(error.localizedDescription) } actions: {
                        Button("重试") { launch = Result { try Self.openStore() } }
                    }
                }
            }
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .onOpenURL { url in
                if url.scheme == "saywhen", url.host == "task" { AppRoute.shared.itemID = UUID(uuidString: url.lastPathComponent) }
            }
        }
    }
    private static func openStore() throws -> TaskStore {
        let container = try ModelContainer(for: SchemaV1.Item.self, migrationPlan: MigrationPlan.self)
        let store = TaskStore(container)
        store.openItems = try store.page(done: false, limit: 40)
        return store
    }
}

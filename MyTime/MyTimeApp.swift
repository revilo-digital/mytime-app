import SwiftData
import SwiftUI

@main
struct MyTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var timer: TimerService
    @State private var awayMonitor: AwayMonitor?

    init() {
        // Unit tests are hosted in the app; keep them away from the real store.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            container = try Persistence.makeContainer(inMemory: isTesting)
        } catch {
            fatalError("Could not open MyTime store: \(error)")
        }
        Persistence.seedIfEmpty(container.mainContext)
        let timer = TimerService(context: container.mainContext)
        _timer = State(initialValue: timer)
        Hotkeys.register(timer: timer)
        if !isTesting {
            BackupService.shared.start(container: container)
            let away = AwayMonitor(timer: timer)
            // Shown after the check that noticed you're back, never mid-launch or mid-poll.
            away.onReturn = { report in Task { @MainActor in AwayPrompt.present(report, timer: timer) } }
            away.start()
            _awayMonitor = State(initialValue: away)
        }
    }

    var body: some Scene {
        Window("MyTime", id: AppWindows.mainID) {
            MainView(timer: timer)
        }
        .modelContainer(container)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1000, height: 640)

        MenuBarExtra {
            TimerPopover(timer: timer)
        } label: {
            MenuBarLabel(timer: timer)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)

        Settings {
            SettingsView()
                .modelContainer(container)
        }
    }
}

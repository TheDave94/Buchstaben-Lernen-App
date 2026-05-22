import SwiftUI
import PrimaeNative

// MARK: - Main entry point

// During XCTest runs the test host bootstraps `TestApp` with an empty
// WindowGroup so AVAudioEngine isn't initialised in the headless
// simulator (it would abort with an RPC timeout / SIGABRT).
@main
struct MainEntryPoint {
    static func main() {
        if NSClassFromString("XCTestCase") != nil {
            TestApp.main()
        } else {
            PrimaeApp.main()
        }
    }
}

// MARK: - Production app
struct PrimaeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = TracingViewModel()

    /// Stored under `primaeAppearance`: "system" / "light" / "dark".
    @AppStorage(PrimaeAppearance.storageKey) private var appearance: String = "system"

    init() {
        // Register SPM-bundled fonts with CoreText. `UIAppFonts` only
        // covers main-bundle fonts; the SPM resource bundle needs
        // `CTFontManagerRegisterFontsForURLs`. Idempotent.
        PrimaeFonts.registerAll()
        // Pre-create the calibration session-log root so the app
        // appears in the Files app even before the first save lands.
        CalibrationSessionLogger.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            PrimaeNative.MainAppView()
                .environment(vm)
                .preferredColorScheme(PrimaeAppearance.resolve(appearance))
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                vm.appDidBecomeActive()
            case .background, .inactive:
                // `appDidEnterBackground` is async — drains pending JSON
                // store writes. Wrap in a Task so iOS's scene-suspension
                // grace window holds the process alive until the awaits
                // resolve, instead of losing a freshly completed letter
                // to a half-flushed write on suspension.
                Task { await vm.appDidEnterBackground() }
            @unknown default:
                Task { await vm.appDidEnterBackground() }
            }
        }
    }
}

// MARK: - Test host app (empty — avoids AVAudioEngine init)
struct TestApp: App {
    var body: some Scene {
        WindowGroup { }
    }
}

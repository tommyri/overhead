import SwiftUI
import OverheadCore

@main
struct OverheadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Overhead", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") { Task { await model.refreshAll(force: true) } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Overview") { model.selectedProvider = nil }
                    .keyboardShortcut("1", modifiers: .command)
                ForEach(Array(model.activeProviders.prefix(8).enumerated()), id: \.element) { index, p in
                    Button(p.displayName) { model.selectedProvider = p }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 640, height: 760)
        }
    }
}

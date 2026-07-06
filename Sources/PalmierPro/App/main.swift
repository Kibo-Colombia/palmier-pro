import AppKit

// Must run before anything lazily creates the new-name directories or reads defaults.
KomaMigration.run()
Log.bootstrap()
Telemetry.start()
BundledFonts.register()
LUTStore.shared.warm()
GradePresetStore.shared.warm()
AccountService.shared.configure()
ModelCatalog.shared.configure()

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()

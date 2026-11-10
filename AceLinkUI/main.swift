import Cocoa
import os

/// AceLinkUI used to be called Ace Link. On first launch, takes over its data folder
/// (channels, icons, the engine VM's downloads) and its settings, so nothing is lost.
/// Runs before anything reads either of them.
private func migrateFromAceLink() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let oldDir = support.appendingPathComponent("Ace Link")
    let newDir = support.appendingPathComponent("AceLinkUI")
    if FileManager.default.fileExists(atPath: oldDir.path),
       !FileManager.default.fileExists(atPath: newDir.path) {
        do {
            try FileManager.default.moveItem(at: oldDir, to: newDir)
            os_log("Moved %{public}@ to %{public}@", oldDir.path, newDir.path)
        } catch {
            os_log("Cannot move %{public}@: %{public}@", oldDir.path, error.localizedDescription)
        }
    }

    let migratedKey = "MigratedFromAceLink"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: migratedKey) else { return }
    if let old = defaults.persistentDomain(forName: "io.blaise.acelink") {
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
    defaults.set(true, forKey: migratedKey)
}

migrateFromAceLink()

let appDelegate = AppDelegate()

NSApplication.shared.delegate = appDelegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

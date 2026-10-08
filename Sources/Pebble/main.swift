import AppKit

MainActor.assumeIsolated {
  let defaults = UserDefaults.standard
  if let identifier = Bundle.main.bundleIdentifier,
     defaults.persistentDomain(forName: identifier) == nil,
     var settings = defaults.persistentDomain(forName: "local.copper.CopperLocal") {
    settings["NSWindow Frame PebblePanel"] = settings.removeValue(forKey: "NSWindow Frame CopperLocalPanel")
    defaults.setPersistentDomain(settings, forName: identifier)
  }
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}

import AppKit

// Menu-bar-only app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = AppController()
app.delegate = controller
app.run()

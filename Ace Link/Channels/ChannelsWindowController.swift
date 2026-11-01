import Cocoa
import SwiftUI

final class ChannelsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(actions: PlaybackActions) {
        let view = ChannelsView(
            store: ChannelStore.shared,
            status: PlaybackStatus.shared,
            actions: actions
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ace Link"
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 820, height: 540))
        window.center()
        window.setFrameAutosaveName("ChannelsWindow")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar at the top of the screen (Ace Link, Edit, Window), needed now that
/// the app has a regular window: it gives text fields copy/paste and Cmd+Q/Cmd+W.
enum AppMainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ace Link",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ace Link", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ace Link", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Ace Link"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Emoji & Symbols",
                         action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
                         keyEquivalent: "")
        main.addItem(submenu(editMenu, title: "Edit"))

        let windowMenu = NSMenu(title: "Window")
        let channels = windowMenu.addItem(withTitle: "Channels",
                                          action: #selector(AppDelegate.showChannelsWindow(_:)),
                                          keyEquivalent: "0")
        channels.target = target
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

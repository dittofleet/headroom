import ServiceManagement

/// Start at login, as a standard login item. It belongs to the app bundle,
/// so it shows under Login Items in System Settings and disappears with the
/// app: nothing is installed anywhere else, and deleting Headroom is a
/// complete uninstall.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Where the user can allow it again after switching it off there.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

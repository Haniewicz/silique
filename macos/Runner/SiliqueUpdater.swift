import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle owns the installer and verifies publisher signatures. Flutter owns
/// discovery/notification; background checks never install without a user action.
@MainActor
final class SiliqueUpdater: NSObject, SPUUpdaterDelegate {
  private let channel: FlutterMethodChannel
  private let lifecycle: FlutterMethodChannel
  private var controller: SPUStandardUpdaterController!
  private var started = false
  private var pendingInstall: (() -> Void)?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "silique.notes/updates", binaryMessenger: messenger)
    lifecycle = FlutterMethodChannel(name: "silique.notes/lifecycle", binaryMessenger: messenger)
    super.init()
    controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "info":
        result([
          "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
          "build": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
        ])
      case "installMac":
        if self.pendingInstall != nil {
          self.flushAndRelaunch()
          result(nil)
          return
        }
        if !self.started {
          self.controller.startUpdater()
          self.started = true
        }
        guard self.controller.updater.canCheckForUpdates else {
          result(FlutterError(code: "update_busy", message: SiliqueLanguage.text(
            "The installer is already open.", "Instalator jest już otwarty."), details: nil))
          return
        }
        self.controller.checkForUpdates(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
               untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    // Never replace a running app until the editor confirms all pending writes.
    // Failure keeps the current application open and leaves the installer pending.
    pendingInstall = installHandler
    flushAndRelaunch()
    return true
  }

  private func flushAndRelaunch() {
    lifecycle.invokeMethod("flushBeforeQuit", arguments: nil) { [weak self] result in
      guard let self = self else { return }
      if (result as? Bool) == true {
        let install = self.pendingInstall
        self.pendingInstall = nil
        install?()
      } else {
        let alert = NSAlert()
        alert.messageText = SiliqueLanguage.text("Could not save the note", "Nie udało się zapisać notatki")
        alert.informativeText = SiliqueLanguage.text(
          "The update was paused. Save your notes and try again.",
          "Aktualizacja została wstrzymana. Zapisz notatki i spróbuj ponownie.")
        alert.addButton(withTitle: SiliqueLanguage.text("Try again", "Spróbuj ponownie"))
        alert.addButton(withTitle: SiliqueLanguage.text("Later", "Później"))
        if alert.runModal() == .alertFirstButtonReturn { self.flushAndRelaunch() }
      }
    }
  }

}

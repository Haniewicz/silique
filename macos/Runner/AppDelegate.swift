import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var terminationPending = false

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return .terminateNow
    }
    if terminationPending { return .terminateLater }
    terminationPending = true
    let channel = FlutterMethodChannel(
      name: "silique.notes/lifecycle",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("flushBeforeQuit", arguments: nil) { [weak self] result in
      self?.terminationPending = false
      // A failed save leaves the app open; the Dart editor displays the error.
      sender.reply(toApplicationShouldTerminate: (result as? Bool) == true)
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

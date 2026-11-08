import Cocoa
import FlutterMacOS
import Security

// BEGIN native language helper
/// App-owned copy only. Do not override AppleLanguages: Cocoa/Keychain/Sparkle
/// own their dialogs and localization; credential identifiers remain unchanged.
enum SiliqueLanguage {
  static let preferenceKey = "silique.interfaceLanguage"

  @discardableResult
  static func setLanguage(_ code: String) -> Bool {
    guard code == "en" || code == "pl" else { return false }
    UserDefaults.standard.set(code, forKey: preferenceKey)
    return true
  }

  static func text(_ english: String, _ polish: String) -> String {
    // Missing/invalid preferences intentionally default to English, not the OS.
    return UserDefaults.standard.string(forKey: preferenceKey) == "pl" ? polish : english
  }
}
// END native language helper

class MainFlutterWindow: NSWindow {
  private var storageURLs: [URL] = []
  private var updater: SiliqueUpdater?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    updater = SiliqueUpdater(messenger: flutterViewController.engine.binaryMessenger)

    let languageChannel = FlutterMethodChannel(
      name: "silique/language", binaryMessenger: flutterViewController.engine.binaryMessenger)
    languageChannel.setMethodCallHandler { call, result in
      guard call.method == "setLanguage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
        let code = arguments["languageCode"] as? String,
        SiliqueLanguage.setLanguage(code)
      else {
        result(FlutterError(code: "invalid_language",
          message: SiliqueLanguage.text("Choose English or Polish.", "Wybierz angielski lub polski."), details: nil))
        return
      }
      result(nil)
    }

    let storageChannel = FlutterMethodChannel(
      name: "silique.notes/storage", binaryMessenger: flutterViewController.engine.binaryMessenger)
    storageChannel.setMethodCallHandler { [weak self] call, result in
      do {
        var bookmarks = UserDefaults.standard.dictionary(forKey: "silique.storageBookmarks") as? [String: Data] ?? [:]
        if call.method == "remember", let path = call.arguments as? String {
          let url = URL(fileURLWithPath: path, isDirectory: true)
          bookmarks[path] = try url.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
          UserDefaults.standard.set(bookmarks, forKey: "silique.storageBookmarks")
        } else if call.method == "restore", let path = call.arguments as? String {
          guard let bookmark = bookmarks[path] else {
            throw NSError(domain: "SiliqueStorage", code: 2,
              userInfo: [NSLocalizedDescriptionKey: SiliqueLanguage.text(
                "Select the data folder again: \(path)", "Wybierz ponownie katalog danych: \(path)")])
          }
          var stale = false
          let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale)
          guard url.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "SiliqueStorage", code: 1,
              userInfo: [NSLocalizedDescriptionKey: SiliqueLanguage.text(
                "Cannot access the data folder: \(path)", "Brak dostępu do katalogu danych: \(path)")])
          }
          self?.storageURLs.append(url)
          if stale {
            bookmarks[path] = try url.bookmarkData(options: .withSecurityScope,
              includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarks, forKey: "silique.storageBookmarks")
          }
        } else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(nil)
      } catch {
        result(FlutterError(code: "storage_access_failed", message: error.localizedDescription, details: nil))
      }
    }

    let keyWrites = FlutterMethodChannel(
      name: "silique.notes/keys", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let keyQueue = DispatchQueue(label: "pl.silique.keychain-writes")
    keyWrites.setMethodCallHandler { call, result in
      if call.method == "listKeys" {
        keyQueue.async {
          // The file-based keychain rejects kSecMatchLimitAll together with
          // kSecReturnData (errSecParam/-50), so enumeration returns attributes
          // only and each account is read separately by the plugin.
          let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain: false,
          ]
          var reference: CFTypeRef?
          let status = SecItemCopyMatching(query as CFDictionary, &reference)
          if status == errSecItemNotFound {
            DispatchQueue.main.async { result([String]()) }
            return
          }
          guard status == errSecSuccess else {
            DispatchQueue.main.async {
              result(FlutterError(code: "keychain_list_failed",
                message: SiliqueLanguage.text("Could not read the list of keys (macOS \(status)).",
                  "Nie udało się odczytać listy kluczy (macOS \(status))."),
                details: nil))
            }
            return
          }
          let accounts = (reference as? [[CFString: Any]] ?? [])
            .compactMap { $0[kSecAttrAccount] as? String }
          DispatchQueue.main.async { result(accounts) }
        }
        return
      }
      if call.method == "relabelBundle" {
        keyQueue.async {
          // One-shot migration: avoid a second Keychain prompt after the first
          // consent. Once the label is migrated (flag persisted), never touch
          // the Keychain again for relabeling.
          if UserDefaults.standard.bool(forKey: "silique.keychainLabelMigrated") {
            DispatchQueue.main.async { result(nil) }
            return
          }
          // Migrate the existing entry's label in place. It never deletes or
          // recreates the item. The label is non-critical, so any failure
          // (e.g. errSecAuthFailed) still reports success.
          let labelQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "pl.novanotes.keys",
            kSecAttrAccount: "nova.keys.v1",
            kSecUseDataProtectionKeychain: false,
          ]
          let relabelStatus = SecItemUpdate(labelQuery as CFDictionary,
            [kSecAttrLabel: "Silique — klucze lokalne"] as CFDictionary)
          if relabelStatus == errSecSuccess {
            UserDefaults.standard.set(true, forKey: "silique.keychainLabelMigrated")
          }
          DispatchQueue.main.async { result(nil) }
        }
        return
      }
      guard call.method == "writeBundle",
        let arguments = call.arguments as? [String: Any],
        let value = arguments["value"] as? String,
        let data = value.data(using: .utf8)
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Legacy writes target the historical bundle account; a promoted bundle
      // ("silique.keys.v2") is written to that account instead. The service
      // identity stays `pl.novanotes.keys`.
      let targetAccount = (arguments["account"] as? String) ?? "nova.keys.v1"
      keyQueue.async {
        let query: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrService: "pl.novanotes.keys",
          kSecAttrAccount: targetAccount,
          kSecUseDataProtectionKeychain: false,
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
          var item = query
          item[kSecValueData] = data
          item[kSecAttrLabel] = "Silique — klucze lokalne"
          status = SecItemAdd(item as CFDictionary, nil)
        }
        // After a successful write, migrate the entry's label in place. This is
        // one-shot (guarded by the same flag as relabelBundle), idempotent, and
        // never deletes or recreates the item. The label is non-critical: a
        // failed relabel must not turn the write into an error.
        if status == errSecSuccess &&
          !UserDefaults.standard.bool(forKey: "silique.keychainLabelMigrated") {
          let relabelStatus = SecItemUpdate(query as CFDictionary,
            [kSecAttrLabel: "Silique — klucze lokalne"] as CFDictionary)
          if relabelStatus == errSecSuccess {
            UserDefaults.standard.set(true, forKey: "silique.keychainLabelMigrated")
          }
        }
        // Never delete a previous bundle on authorization or update failure.
        let finalStatus = status
        DispatchQueue.main.async {
          if finalStatus == errSecSuccess {
            result(nil)
          } else {
            result(FlutterError(code: "keychain_write_failed",
              message: SiliqueLanguage.text(
                "Could not save the keys (macOS \(finalStatus)). The existing entry was preserved.",
                "Nie udało się zapisać kluczy (macOS \(finalStatus)). Istniejący wpis zachowano."),
              details: nil))
          }
        }
      }
    }

    super.awakeFromNib()
  }
}

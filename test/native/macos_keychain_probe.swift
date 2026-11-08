import Foundation
import Security

// Link the resolved plugin itself, not a model of Apple's Security framework.
// All operations are scoped to a random synthetic service and account.
struct ProbeFailure: Error {}

func runProbe() throws {
    let service = "pl.silique.test.keychain-param." + UUID().uuidString
    let key = "synthetic-credential"
    // Same query as MainFlutterWindow.writeBundle, with a disposable identity.
    let identity: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: key,
        kSecUseDataProtectionKeychain: false,
    ]
    defer { SecItemDelete(identity as CFDictionary) }

    func status(_ name: String, _ query: [CFString: Any]) {
        var value: CFTypeRef?
        print("\(name): \(SecItemCopyMatching(query as CFDictionary, &value))")
    }
    var plain = identity
    plain[kSecReturnData] = true
    status("explicit file-keychain missing read", plain)
    var implicit = plain
    implicit.removeValue(forKey: kSecUseDataProtectionKeychain)
    status("implicit keychain missing read", implicit)
    var accessible = implicit
    accessible[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
    accessible[kSecAttrSynchronizable] = false
    status("plugin base missing read", accessible)
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlocked, [], &error
    ) else {
        print("Unable to construct isolated access-control diagnostic")
        throw ProbeFailure()
    }
    var legacy = implicit
    legacy[kSecAttrAccessControl] = access
    status("plugin legacy fallback missing read", legacy)
    legacy[kSecUseDataProtectionKeychain] = false
    status("explicit file-keychain access-control missing read", legacy)

    let storage = FlutterSecureStorage()
    let params = KeychainQueryParameters(
        key: key,
        service: service,
        isSynchronizable: false,
        accessibilityLevel: "unlocked",
        usesDataProtectionKeychain: false,
        shouldReturnData: true,
        accessControlFlags: nil,
        useSecureEnclave: false
    )
    // Diagnostic only: nil accessibility still permits cross-accessibility
    // fallbacks in plugin 0.4.3. Do not assume it fixes the startup failure.
    var noAccessibility = params
    noAccessibility.accessibilityLevel = nil
    let candidate = storage.read(params: noAccessibility)
    print("nil-accessibility missing read (diagnostic): \(candidate.status)")

    var checks = 0
    var failures = 0
    func check(_ name: String, _ condition: Bool, _ detail: String) {
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name): \(detail)")
    }
    let missing = storage.read(params: params)
    check("missing credential returns nil", missing.status == errSecSuccess && missing.value == nil,
          "status=\(missing.status)")
    switch storage.containsKey(params: params) {
    case .success(let found): check("missing credential does not exist", !found, "found=\(found)")
    case .failure(let failure): check("missing credential does not exist", false, "status=\(failure.status)")
    }
    var item = identity
    item[kSecValueData] = Data("synthetic-original".utf8)
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else {
        print("Unable to create isolated writer fixture: \(added)")
        throw ProbeFailure()
    }
    let present = storage.read(params: params)
    check("writer credential remains readable",
          present.status == errSecSuccess && present.value as? String == "synthetic-original",
          "status=\(present.status)")
    let candidatePresent = storage.read(params: noAccessibility)
    print("nil-accessibility writer read (diagnostic): \(candidatePresent.status), " +
          "original=\(candidatePresent.value as? String == "synthetic-original")")
    var allParams = params
    allParams.key = nil
    let all = storage.readAll(params: allParams)
    print("plugin exhaustive readAll (diagnostic): status=\(all.status)")
    // The file-based keychain rejects kSecMatchLimitAll together with
    // kSecReturnData (errSecParam), so the shipped path enumerates attributes
    // only and reads each account separately.
    let attributes: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecUseDataProtectionKeychain: false,
    ]
    var attributeRef: CFTypeRef?
    let attributeStatus = SecItemCopyMatching(attributes as CFDictionary, &attributeRef)
    let accounts = (attributeRef as? [[CFString: Any]] ?? [])
        .compactMap { $0[kSecAttrAccount] as? String }
    let perKeyRead = storage.read(params: params)
    check("attribute enumeration preserves writer credential",
          attributeStatus == errSecSuccess && accounts.contains(key) &&
            perKeyRead.status == errSecSuccess &&
            perKeyRead.value as? String == "synthetic-original",
          "status=\(attributeStatus), accounts=\(accounts.count), read=\(perKeyRead.status)")
    var updatedItem = identity
    updatedItem[kSecReturnData] = true
    let updated = SecItemUpdate(identity as CFDictionary,
                                [kSecValueData: Data("synthetic-updated".utf8)] as CFDictionary)
    let reopened = FlutterSecureStorage().read(params: params)
    check("reopen preserves updated credential",
          updated == errSecSuccess && reopened.status == errSecSuccess &&
            reopened.value as? String == "synthetic-updated",
          "update=\(updated), read=\(reopened.status)")
    let deleted = storage.delete(params: params)
    var remaining: CFTypeRef?
    let absent = SecItemCopyMatching(updatedItem as CFDictionary, &remaining)
    check("scoped deletion removes fixture",
          deleted.status == errSecSuccess && absent == errSecItemNotFound,
          "delete=\(deleted.status), read=\(absent)")
    print("Native Keychain probe: checks=\(checks), failures=\(failures)")
    if failures != 0 { throw ProbeFailure() }
}

do {
    try runProbe()
} catch {
    // runProbe's defer cleans up even when a regression check fails.
    fputs("Native Keychain regression failed; see scoped diagnostics above\n", stderr)
    exit(1)
}

import Foundation
import Security

/// Persists Anime 365 session cookies in iOS Keychain and shares them across all mirrors.
final class SessionCookies {
    private let lock = NSLock()
    private let service = "app.neifur365.ios.session"
    private let account = "a365_cookies"
    private var jar: [String: String] = [:]

    init() {
        jar = loadFromKeychain()
    }

    subscript(name: String) -> String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return jar[name]
        }
        set {
            lock.lock()
            if let v = newValue, !v.isEmpty {
                jar[name] = v
            } else {
                jar.removeValue(forKey: name)
            }
            let snapshot = jar
            lock.unlock()
            saveToKeychain(snapshot)
        }
    }

    func save(from response: HTTPURLResponse, url: URL) {
        guard let fields = response.allHeaderFields as? [String: String] else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        let now = Date()

        lock.lock()
        for c in cookies {
            if let exp = c.expiresDate, exp < now {
                jar.removeValue(forKey: c.name)
            } else if c.value.isEmpty || c.value == "deleted" {
                jar.removeValue(forKey: c.name)
            } else {
                jar[c.name] = c.value
            }
        }
        let snapshot = jar
        lock.unlock()
        saveToKeychain(snapshot)
    }

    func importHeader(_ header: String) {
        let pairs = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        lock.lock()
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty {
                jar[key] = val
            }
        }
        let snapshot = jar
        lock.unlock()
        saveToKeychain(snapshot)
    }

    func importCookies(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else { return }
        lock.lock()
        for c in cookies {
            if !c.name.isEmpty && !c.value.isEmpty && c.value != "deleted" {
                jar[c.name] = c.value
            }
        }
        let snapshot = jar
        lock.unlock()
        saveToKeychain(snapshot)
    }

    func header() -> String {
        lock.lock()
        let pairs = jar.map { "\($0.key)=\($0.value)" }
        lock.unlock()
        return pairs.joined(separator: "; ")
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return jar.isEmpty
    }

    func clear() {
        lock.lock()
        jar.removeAll()
        lock.unlock()
        deleteFromKeychain()
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveToKeychain(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

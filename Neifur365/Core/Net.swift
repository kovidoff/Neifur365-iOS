import Foundation

struct HttpError: LocalizedError {
    let code: Int
    let bodySnippet: String

    var errorDescription: String? { "HTTP \(code)" }
}

struct ApiError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct SignInRequiredError: LocalizedError {
    var errorDescription: String? { "Войдите в аккаунт Anime 365, чтобы смотреть" }
}

struct SubscriptionRequiredError: LocalizedError {
    static let message = "Для просмотра нужна подписка Anime 365"
    var errorDescription: String? { Self.message }
}

struct InvalidCredentialsError: LocalizedError {
    var errorDescription: String? { "Неверный e-mail или пароль" }
}

struct CloudflareBlockedError: LocalizedError {
    var errorDescription: String? { "Зеркало заблокировано проверкой Cloudflare" }
}

extension Error {
    /// Human-readable Russian error message for UI presentation.
    var userMessage: String {
        if let http = self as? HttpError {
            switch http.code {
            case 401, 403: return "Доступ запрещён (\(http.code))"
            case 429: return "Слишком много запросов, попробуйте чуть позже"
            case 500...599: return "Сервис временно недоступен (\(http.code))"
            default: return "Ошибка сервера (\(http.code))"
            }
        }
        if let api = self as? ApiError {
            return api.message
        }
        if let err = self as? SignInRequiredError {
            return err.errorDescription ?? "Войдите в аккаунт Anime 365"
        }
        if let err = self as? SubscriptionRequiredError {
            return err.errorDescription ?? SubscriptionRequiredError.message
        }
        if let err = self as? InvalidCredentialsError {
            return err.errorDescription ?? "Неверный e-mail или пароль"
        }
        if let urlErr = self as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
                return "Нет соединения с сетью"
            case .timedOut:
                return "Сервер не отвечает"
            default:
                return urlErr.localizedDescription
            }
        }
        return localizedDescription.isEmpty ? "Что-то пошло не так" : localizedDescription
    }
}

/// Lenient decoding helpers so string-encoded numbers or nulls from Anime 365 API never break decoding.
extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Int(s) { return v }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return defaultValue
    }

    func decodeLossyInt64(forKey key: Key, default defaultValue: Int64 = 0) -> Int64 {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Int64(s) { return v }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return defaultValue
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Double(s.replacingOccurrences(of: ",", with: ".")) {
            return v
        }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        return nil
    }

    func decodeLossyString(forKey key: Key, default defaultValue: String = "") -> String {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        return defaultValue
    }
}

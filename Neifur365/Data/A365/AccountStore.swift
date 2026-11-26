import Foundation
import WebKit

enum AccountState: Equatable {
    case unknown
    case signedOut
    case signedIn(Profile)
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var state: AccountState = .unknown
    @Published private(set) var expired: Bool = false
    @Published private(set) var unconfirmed: Bool = false

    private let api: Anime365Client
    private let prefs: Prefs
    private var checkingSession = false

    var profile: Profile? {
        if case .signedIn(let p) = state { return p }
        return nil
    }

    var isSignedIn: Bool { profile != nil }

    init(api: Anime365Client, prefs: Prefs) {
        self.api = api
        self.prefs = prefs

        api.onSessionLost = { [weak self] in
            Task { @MainActor in
                await self?.handleSessionLost()
            }
        }
        refresh()
    }

    private func applySignedIn(_ profile: Profile) {
        prefs.claimFor(userId: profile.id)
        prefs.saveProfile(profile)
        unconfirmed = false
        expired = false
        state = .signedIn(profile)
        Task { await flushPendingWatches() }
    }

    func flushPendingWatches() async {
        guard isSignedIn, !prefs.pendingWatches.isEmpty else { return }
        let items = prefs.pendingWatches
        for item in items {
            do {
                try await api.markWatched(translationId: item.translationId)
                prefs.removePendingWatch(translationId: item.translationId)
            } catch {
                break
            }
        }
    }

    private func handleSessionLost() async {
        guard !checkingSession, isSignedIn else { return }
        checkingSession = true
        defer { checkingSession = false }
        do {
            if let verified = try await api.profile() {
                applySignedIn(verified)
            } else {
                expired = true
                unconfirmed = false
                state = .signedOut
                prefs.saveProfile(nil)
            }
        } catch {
            // Network glitch while verifying session: keep current state.
        }
    }

    func refresh() {
        Task {
            do {
                if let p = try await api.profile() {
                    applySignedIn(p)
                } else {
                    unconfirmed = false
                    state = .signedOut
                    prefs.saveProfile(nil)
                }
            } catch {
                if state == .unknown {
                    unconfirmed = true
                    if let saved = prefs.savedProfile() {
                        state = .signedIn(saved)
                    } else {
                        state = .signedOut
                    }
                }
            }
        }
    }

    func login(email: String, password: String) async throws -> Profile {
        let p = try await api.login(email: email, password: password)
        applySignedIn(p)
        return p
    }

    func adoptBrowserCookies(_ cookies: [HTTPCookie]) async -> Profile? {
        api.cookies.importCookies(cookies)
        guard let p = try? await api.profile() else { return nil }
        applySignedIn(p)
        return p
    }

    func logout() {
        api.logout()
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for c in cookies {
                WKWebsiteDataStore.default().httpCookieStore.delete(c)
            }
        }
        expired = false
        unconfirmed = false
        state = .signedOut
        prefs.saveProfile(nil)
    }
}

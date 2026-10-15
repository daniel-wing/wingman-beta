import CryptoKit
import Foundation
import Security

/// Who signed the running copy of Wingman. macOS ties its privacy permissions
/// (microphone, system audio, calendar, Accessibility) to the signature, so
/// when it changes (0.8's own certificate → an Apple Developer ID), the new
/// copy has to be allowed again. Wingman remembers the last signer to notice.
enum SigningCheck {
    struct Signer: Equatable {
        /// "team:<Team ID>" for an Apple developer certificate, "cert:<hash>"
        /// for another certificate, "adhoc" for none.
        let id: String
        var isDeveloperID: Bool { id.hasPrefix("team:") }
    }

    static let key = "lastSigner"

    static func current() -> Signer {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return Signer(id: "adhoc") }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return Signer(id: "team:" + team)
        }
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            return Signer(id: "cert:" + digest.prefix(8).map { String(format: "%02x", $0) }.joined())
        }
        return Signer(id: "adhoc")
    }

    /// Whether this launch is the first one after the signer changed, so the
    /// permissions given to the old copy no longer apply.
    /// - A fresh install (setup not completed) never counts: the welcome guide asks.
    /// - No signer remembered: the previous version predates this check (0.8, or
    ///   0.9 builds before it), and those were never signed with a Developer ID.
    static func changed(welcomeCompleted: Bool, last: String?, current: Signer) -> Bool {
        guard welcomeCompleted else { return false }
        guard let last else { return current.isDeveloperID }
        return last != current.id
    }

    /// Run once per launch: decides, then remembers the current signer.
    static func checkAtLaunch(welcomeCompleted: Bool, defaults: UserDefaults = .standard) -> Bool {
        let current = current()
        let changed = changed(welcomeCompleted: welcomeCompleted, last: defaults.string(forKey: key), current: current)
        defaults.set(current.id, forKey: key)
        if changed {
            // Remembered from the old copy: it says nothing about this one.
            defaults.removeObject(forKey: "systemAudioConfirmed")
        }
        return changed
    }
}

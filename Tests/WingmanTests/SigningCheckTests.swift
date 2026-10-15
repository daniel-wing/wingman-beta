import Foundation
import Testing
@testable import Wingman

/// When "Allow Wingman Again" appears: only for someone who already set
/// Wingman up, and only when the signer really changed.
@Suite struct SigningCheckTests {
    private let developerID = SigningCheck.Signer(id: "team:ABCDE12345")
    private let ownCertificate = SigningCheck.Signer(id: "cert:0011223344556677")

    @Test func aFreshInstallNeverSeesIt() {
        #expect(!SigningCheck.changed(welcomeCompleted: false, last: nil, current: developerID))
        #expect(!SigningCheck.changed(welcomeCompleted: false, last: ownCertificate.id, current: developerID))
    }

    @Test func upgradingFrom08ToADeveloperIDBuild() {
        // 0.8 remembered no signer, and was never Developer ID signed.
        #expect(SigningCheck.changed(welcomeCompleted: true, last: nil, current: developerID))
        #expect(!SigningCheck.changed(welcomeCompleted: true, last: nil, current: ownCertificate))
    }

    @Test func aChangedSignerCountsOnceThenNotAgain() {
        #expect(SigningCheck.changed(welcomeCompleted: true, last: ownCertificate.id, current: developerID))
        #expect(!SigningCheck.changed(welcomeCompleted: true, last: developerID.id, current: developerID))
        // Back to the old copy (a downgrade) is a change too.
        #expect(SigningCheck.changed(welcomeCompleted: true, last: developerID.id, current: ownCertificate))
    }

    @Test func theCheckRemembersTheSignerAndForgetsTheOldSystemAudioAnswer() throws {
        let defaults = try #require(UserDefaults(suiteName: "wingman-signing-\(UUID().uuidString)"))
        defaults.set(true, forKey: "systemAudioConfirmed")
        defaults.set("cert:something-else", forKey: SigningCheck.key)
        let changed = SigningCheck.checkAtLaunch(welcomeCompleted: true, defaults: defaults)
        #expect(defaults.string(forKey: SigningCheck.key) == SigningCheck.current().id)
        #expect(changed == (SigningCheck.current().id != "cert:something-else"))
        #expect(defaults.bool(forKey: "systemAudioConfirmed") == !changed)
        // The next launch: same signer, nothing to do.
        #expect(!SigningCheck.checkAtLaunch(welcomeCompleted: true, defaults: defaults))
    }
}

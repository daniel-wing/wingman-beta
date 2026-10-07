import Darwin
import Foundation
import Testing
@testable import Wingman

@Suite struct ProcessTreeTests {
    @Test func parentOfThisProcess() {
        #expect(ProcessTree.parentPID(of: getpid()) == getppid())
        #expect(ProcessTree.parentPID(of: 999_999) == nil)
    }

    #if !NO_DIAGNOSTICS && !APP_STORE
    @Test func argumentsFromAProcArgsBuffer() {
        // argc, executable path, NUL padding, then the arguments (and the environment).
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/Applications/Chrome Helper".utf8) + [0, 0, 0]
        for argument in ["Google Chrome Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"] {
            bytes += Array(argument.utf8) + [0]
        }
        bytes += Array("HOME=/Users/someone".utf8) + [0]
        #expect(ProcessTree.arguments(in: bytes) ==
                ["Google Chrome Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"])
        #expect(ProcessTree.arguments(in: [1, 0]).isEmpty)
    }

    @Test func noChromiumRoleForOtherProcesses() {
        #expect(ProcessTree.chromiumRole(of: getpid()) == nil)
    }
    #endif
}

#if !APP_STORE
@Suite struct PageAccessTests {
    @Test func switchesOnOnlyFromAKnownOff() {
        #expect(PageAccess.shouldSwitchOn(.off, force: false))
        #expect(!PageAccess.shouldSwitchOn(.on, force: false))
        #expect(!PageAccess.shouldSwitchOn(.on, force: true))
        // Unreadable says nothing about the state: left alone unless forced.
        #expect(!PageAccess.shouldSwitchOn(.unreadable, force: false))
        #expect(PageAccess.shouldSwitchOn(.unreadable, force: true))
    }

    @Test func restoresOnlyWhatItTurnedOnFromOff() {
        #expect(PageAccess.shouldRestore(original: .off, changed: true, keep: false, assistiveStarted: false))
        #expect(!PageAccess.shouldRestore(original: .off, changed: false, keep: false, assistiveStarted: false))
        #expect(!PageAccess.shouldRestore(original: .on, changed: false, keep: false, assistiveStarted: false))
        #expect(!PageAccess.shouldRestore(original: .off, changed: true, keep: true, assistiveStarted: false))
        // Forced on from an unknown value: not switched "back" to a guess.
        #expect(!PageAccess.shouldRestore(original: .unreadable, changed: true, keep: false, assistiveStarted: false))
    }

    @Test func assistiveUseThatStartedMeanwhileKeepsItOn() {
        #expect(!PageAccess.shouldRestore(original: .off, changed: true, keep: false, assistiveStarted: true))
    }
}
#endif

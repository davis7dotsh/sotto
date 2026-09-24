import ApplicationServices
import XCTest
@testable import V07

final class NativePasteCommandTests: XCTestCase {
    private let menu: [Int: NativePasteMenuMetadata] = [
        0: .init(role: .menuBar),
        1: .init(role: .menuBarItem),
        2: .init(role: .menu),
        3: .init(role: .menuItem, commandCharacter: "V", commandModifiers: 0),
        4: .init(role: .menuItem, commandCharacter: "c", commandModifiers: 0),
        5: .init(role: .menuItem, commandCharacter: "v", commandModifiers: 3),
    ]
    private let edges = [0: [1], 1: [2], 2: [3, 4, 5]]

    func testFindsUniqueCommandVWithoutTitlesOrEnabledState() {
        XCTAssertEqual(discovery(menu).find(in: 0, deadline: 1), 3)
        var lowercase = menu
        lowercase[3] = .init(role: .menuItem, commandCharacter: "v", commandModifiers: 0)
        XCTAssertEqual(discovery(lowercase).find(in: 0, deadline: 1), 3)
    }

    func testModifierMaskZeroMeansCommandAlone() {
        for modifiers in [UInt32(1), 2, 4, 8, 16] {
            var changed = menu
            changed[3] = .init(role: .menuItem, commandCharacter: "v", commandModifiers: modifiers)
            XCTAssertNil(discovery(changed).find(in: 0, deadline: 1))
        }
    }

    func testAmbiguousOrUnverifiedCommandModifiersRejectTheWholeWalk() {
        let modifierCases: [UInt32?] = [0, nil]
        for modifiers in modifierCases {
            var changed = menu
            changed[4] = .init(role: .menuItem, commandCharacter: "v", commandModifiers: modifiers)
            XCTAssertNil(discovery(changed).find(in: 0, deadline: 1))
        }
    }

    func testFailedMetadataOrChildrenAfterFindingCandidateIsNotSuccess() {
        var incomplete = menu
        incomplete.removeValue(forKey: 4)
        XCTAssertNil(discovery(incomplete).find(in: 0, deadline: 1))

        let failingChildren = NativePasteCommandDiscovery<Int>(
            metadata: { self.menu[$0] },
            children: { element, _ in element == 4 ? nil : self.edges[element, default: []] },
            sameElement: ==, now: { 0 }, isCancelled: { false }
        )
        XCTAssertNil(failingChildren.find(in: 0, deadline: 1))
    }

    func testTraversalLimitsDoNotDeclareAPartialWalkUnique() {
        let reader = discovery(menu)
        XCTAssertNil(reader.find(in: 0, deadline: 1, maximumNodes: 5))
        XCTAssertNil(reader.find(in: 0, deadline: 1, maximumDepth: 2))
        XCTAssertEqual(reader.find(in: 0, deadline: 1, maximumNodes: 6, maximumDepth: 3), 3)
        XCTAssertNil(reader.find(in: 2, deadline: 1))
    }

    func testDeadlineAndCancellationAfterCandidateStillRejectTheWalk() {
        for cancel in [false, true] {
            var time: TimeInterval = 0
            var cancelled = false
            let reader = NativePasteCommandDiscovery<Int>(
                metadata: { self.menu[$0] },
                children: { element, _ in
                    if element == 3 {
                        if cancel { cancelled = true }
                        else { time = 1 }
                    }
                    return self.edges[element, default: []]
                },
                sameElement: ==, now: { time }, isCancelled: { cancelled }
            )
            XCTAssertNil(reader.find(in: 0, deadline: 1))
        }
    }

    func testRepeatedHandlesAndCyclesAreNotAdditionalCommands() {
        let reader = NativePasteCommandDiscovery<Int>(
            metadata: { self.menu[$0] },
            children: { element, _ in
                if element == 4 { return [2, 3] }
                return self.edges[element, default: []]
            },
            sameElement: ==, now: { 0 }, isCancelled: { false }
        )
        XCTAssertEqual(reader.find(in: 0, deadline: 1), 3)
    }

    func testDisabledOrUnsupportedCommandsAreNotInvoked() {
        for enabled in [true, false] {
            var performed = 0
            let action = invocation(
                enabled: enabled ? .allowed : .unavailable,
                supportsPress: enabled ? .unavailable : .allowed,
                perform: { _ in performed += 1; return .success }
            )
            XCTAssertEqual(action.invoke(3, canDispatch: { true }), .unavailable)
            XCTAssertEqual(performed, 0)
        }
    }

    func testReplacedCommandOrUnverifiedEnabledStateBlocksWithoutInvocation() {
        var performed = 0
        let changedCommand = invocation(command: .blocked, perform: { _ in performed += 1; return .success })
        XCTAssertEqual(changedCommand.invoke(3, canDispatch: { true }), .blocked)
        let unreadableEnabled = invocation(enabled: .blocked, perform: { _ in performed += 1; return .success })
        XCTAssertEqual(unreadableEnabled.invoke(3, canDispatch: { true }), .blocked)
        XCTAssertEqual(performed, 0)
    }

    func testPermissionRevocationOrCancellationDuringPreflightPreventsAction() {
        for revokePermission in [true, false] {
            var trusted = true
            var cancelled = false
            var performed = 0
            let action = NativePasteCommandInvocation<Int>(
                isTrusted: { trusted }, isCancelled: { cancelled },
                isCommand: { _ in .allowed }, isEnabled: { _ in .allowed },
                supportsPress: { _ in
                    if revokePermission { trusted = false }
                    else { cancelled = true }
                    return .allowed
                },
                performPress: { _ in performed += 1; return .success }
            )
            XCTAssertEqual(action.invoke(3, canDispatch: { true }), .blocked)
            XCTAssertEqual(performed, 0)
        }
    }

    func testActionResultsNeverCauseAnAutomaticSecondAttempt() {
        let cases: [(AXError, NativePasteCommand.Attempt)] = [
            (.success, .dispatched), (.cannotComplete, .dispatched), (.failure, .dispatched),
            (.noValue, .dispatched), (.attributeUnsupported, .dispatched),
            (.actionUnsupported, .unavailable), (.notImplemented, .unavailable),
            (.apiDisabled, .blocked), (.invalidUIElement, .blocked), (.illegalArgument, .blocked),
        ]
        for (response, expected) in cases {
            var performed = 0
            let action = invocation(perform: { _ in performed += 1; return response })
            XCTAssertEqual(action.invoke(3, canDispatch: { true }), expected)
            XCTAssertEqual(performed, 1)
        }
    }

    func testCancellationAfterActionStartedDoesNotMisreportItAsUnsent() {
        var cancelled = false
        let action = NativePasteCommandInvocation<Int>(
            isTrusted: { true }, isCancelled: { cancelled },
            isCommand: { _ in .allowed }, isEnabled: { _ in .allowed }, supportsPress: { _ in .allowed },
            performPress: { _ in cancelled = true; return .cannotComplete }
        )
        XCTAssertEqual(action.invoke(3, canDispatch: { true }), .dispatched)
    }

    func testLastMomentOwnershipGuardRunsAfterMetadataAndPreventsDispatch() {
        var clipboardOwned = true
        var performed = 0
        var guardCalls = 0
        let action = NativePasteCommandInvocation<Int>(
            isTrusted: { true }, isCancelled: { false },
            isCommand: { _ in .allowed }, isEnabled: { _ in .allowed },
            supportsPress: { _ in clipboardOwned = false; return .allowed },
            performPress: { _ in performed += 1; return .success }
        )
        let outcome = action.invoke(3, canDispatch: { guardCalls += 1; return clipboardOwned })
        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(guardCalls, 1)
        XCTAssertEqual(performed, 0)
    }

    private func discovery(_ nodes: [Int: NativePasteMenuMetadata]) -> NativePasteCommandDiscovery<Int> {
        NativePasteCommandDiscovery(metadata: { nodes[$0] }, children: { element, _ in self.edges[element, default: []] },
                                   sameElement: ==, now: { 0 }, isCancelled: { false })
    }

    private func invocation(command: NativePasteReadiness = .allowed, enabled: NativePasteReadiness = .allowed,
                            supportsPress: NativePasteReadiness = .allowed,
                            perform: @escaping (Int) -> AXError) -> NativePasteCommandInvocation<Int> {
        NativePasteCommandInvocation(isTrusted: { true }, isCancelled: { false }, isCommand: { _ in command },
                                    isEnabled: { _ in enabled }, supportsPress: { _ in supportsPress }, performPress: perform)
    }
}

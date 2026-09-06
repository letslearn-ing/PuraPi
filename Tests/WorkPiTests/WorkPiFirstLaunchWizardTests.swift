import Foundation
import XCTest
@testable import WorkPi

final class WorkPiFirstLaunchWizardTests: XCTestCase {
    func testRuntimeMustBeReadyBeforeCheckingAuthentication() {
        let step = WorkPiFirstLaunchStepResolver.resolve(
            runtime: .missing(node: .missing),
            authenticationLoaded: true,
            authenticationPhase: .idle,
            authentication: .empty
        )

        XCTAssertEqual(step, .runtimeSetup)
    }

    func testAvailableRuntimeStartsAuthenticationCheckUntilStatusLoads() {
        let step = WorkPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: false,
            authenticationPhase: .idle,
            authentication: .empty
        )

        XCTAssertEqual(step, .checkingAuthentication)
    }

    func testAuthenticationWithoutConfiguredProviderNeedsSetup() {
        let step = WorkPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: true,
            authenticationPhase: .idle,
            authentication: .empty
        )

        XCTAssertEqual(step, .authenticationSetup)
    }

    func testConfiguredProviderCompletesFirstLaunchSetup() {
        let provider = WorkPiAuthProvider(
            id: "anthropic",
            name: "Anthropic",
            authTypes: [],
            status: WorkPiAuthStatus(
                configured: true,
                type: .apiKey,
                source: "stored",
                subscription: false
            )
        )
        let snapshot = WorkPiAuthSnapshot(
            providers: [provider],
            credentials: [WorkPiStoredCredential(providerId: "anthropic", type: .apiKey)],
            models: [],
            modelsTruncated: false
        )

        let step = WorkPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: true,
            authenticationPhase: .idle,
            authentication: snapshot
        )

        XCTAssertEqual(step, .ready)
    }

    func testAuthenticationFailureReturnsToSetupStep() {
        let step = WorkPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: false,
            authenticationPhase: .failed("认证桥接不可用"),
            authentication: .empty
        )

        XCTAssertEqual(step, .authenticationSetup)
    }

    private func installation() -> WorkPiRuntimeInstallation {
        WorkPiRuntimeInstallation(
            executableURL: URL(fileURLWithPath: "/tmp/pi"),
            version: WorkPiRuntimeVersion(major: 0, minor: 84, patch: 4),
            source: .existing,
            nodeURL: URL(fileURLWithPath: "/tmp/node")
        )
    }
}

import Foundation
import XCTest
@testable import PuraPi

final class PuraPiFirstLaunchWizardTests: XCTestCase {
    func testRuntimeMustBeReadyBeforeCheckingAuthentication() {
        let step = PuraPiFirstLaunchStepResolver.resolve(
            runtime: .missing(node: .missing),
            authenticationLoaded: true,
            authenticationPhase: .idle,
            authentication: .empty
        )

        XCTAssertEqual(step, .runtimeSetup)
    }

    func testAvailableRuntimeStartsAuthenticationCheckUntilStatusLoads() {
        let step = PuraPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: false,
            authenticationPhase: .idle,
            authentication: .empty
        )

        XCTAssertEqual(step, .checkingAuthentication)
    }

    func testAuthenticationWithoutConfiguredProviderNeedsSetup() {
        let step = PuraPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: true,
            authenticationPhase: .idle,
            authentication: .empty
        )

        XCTAssertEqual(step, .authenticationSetup)
    }

    func testConfiguredProviderCompletesFirstLaunchSetup() {
        let provider = PuraPiAuthProvider(
            id: "anthropic",
            name: "Anthropic",
            authTypes: [],
            status: PuraPiAuthStatus(
                configured: true,
                type: .apiKey,
                source: "stored",
                subscription: false
            )
        )
        let snapshot = PuraPiAuthSnapshot(
            providers: [provider],
            credentials: [PuraPiStoredCredential(providerId: "anthropic", type: .apiKey)],
            models: [],
            modelsTruncated: false
        )

        let step = PuraPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: true,
            authenticationPhase: .idle,
            authentication: snapshot
        )

        XCTAssertEqual(step, .ready)
    }

    func testAuthenticationFailureReturnsToSetupStep() {
        let step = PuraPiFirstLaunchStepResolver.resolve(
            runtime: .available(installation()),
            authenticationLoaded: false,
            authenticationPhase: .failed("认证桥接不可用"),
            authentication: .empty
        )

        XCTAssertEqual(step, .authenticationSetup)
    }

    private func installation() -> PuraPiRuntimeInstallation {
        PuraPiRuntimeInstallation(
            executableURL: URL(fileURLWithPath: "/tmp/pi"),
            version: PuraPiRuntimeVersion(major: 0, minor: 84, patch: 4),
            source: .existing,
            nodeURL: URL(fileURLWithPath: "/tmp/node")
        )
    }
}

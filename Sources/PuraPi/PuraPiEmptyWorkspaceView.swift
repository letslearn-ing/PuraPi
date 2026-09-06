import SwiftUI

@MainActor
struct PuraPiEmptyWorkspaceView: View {
    @ObservedObject var runtimeProvisioner: PuraPiRuntimeProvisioner
    @ObservedObject var authCoordinator: PuraPiAuthCoordinator
    let language: PuraPiInterfaceLanguage
    let onCreateProject: () -> Void
    let onOpenProject: () -> Void
    let onOpenAccountSettings: () -> Void

    var body: some View {
        PuraPiFirstLaunchWizard(
            runtimeProvisioner: runtimeProvisioner,
            authCoordinator: authCoordinator,
            language: language,
            onCreateProject: onCreateProject,
            onOpenProject: onOpenProject,
            onOpenAccountSettings: onOpenAccountSettings
        )
    }
}

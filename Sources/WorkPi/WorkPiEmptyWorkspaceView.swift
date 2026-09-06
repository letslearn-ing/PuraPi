import SwiftUI

@MainActor
struct WorkPiEmptyWorkspaceView: View {
    @ObservedObject var runtimeProvisioner: WorkPiRuntimeProvisioner
    @ObservedObject var authCoordinator: WorkPiAuthCoordinator
    let language: WorkPiInterfaceLanguage
    let onCreateProject: () -> Void
    let onOpenProject: () -> Void
    let onOpenAccountSettings: () -> Void

    var body: some View {
        WorkPiFirstLaunchWizard(
            runtimeProvisioner: runtimeProvisioner,
            authCoordinator: authCoordinator,
            language: language,
            onCreateProject: onCreateProject,
            onOpenProject: onOpenProject,
            onOpenAccountSettings: onOpenAccountSettings
        )
    }
}

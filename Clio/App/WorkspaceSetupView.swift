import SwiftUI

struct WorkspaceSetupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Clio")
                    .font(.custom(Typography.family, fixedSize: 24).bold())
                    .foregroundStyle(Color(nsColor: Palette.emphasis))

                Text("Choose the first folder in your writing workspace. Clio keeps Markdown and text files on disk, and you can add more searchable folders at any time.")
                    .font(.custom(Typography.family, fixedSize: 13))
                    .foregroundStyle(Color(nsColor: Palette.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button("Use Documents/Clio") {
                    appState.chooseDefaultWorkspace()
                }
                .buttonStyle(.glassProminent)
                .tint(appState.accent.color)

                Button("Choose a Folder…") {
                    appState.chooseAnotherWorkspace()
                }
                .buttonStyle(.glass)
            }

            if let errorMessage = appState.workspaceErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Workspace access needs attention", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(appState.accent.color)

                    Text(errorMessage)
                        .foregroundStyle(Color(nsColor: Palette.muted))

                    Button("Dismiss") {
                        appState.dismissWorkspaceError()
                    }
                    .buttonStyle(.glass)
                }
                .font(.custom(Typography.family, fixedSize: 12))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Palette.background))
    }
}

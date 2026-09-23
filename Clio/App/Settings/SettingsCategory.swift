/// The pages of the Settings panel, in sidebar order. The raw value is
/// persisted, so renaming a case orphans the stored selection (it falls back
/// to `.general`) rather than failing.
enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general, editor, writing, workspaces, export, assisted, localMCP

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .editor: "Editor"
        case .writing: "Writing"
        case .workspaces: "Workspaces"
        case .export: "Export"
        case .assisted: "Assisted Commands"
        case .localMCP: "Local MCP"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editor: "textformat"
        case .writing: "pencil.line"
        case .workspaces: "folder"
        case .export: "square.and.arrow.up"
        case .assisted: "sparkles"
        case .localMCP: "point.3.connected.trianglepath.dotted"
        }
    }
}

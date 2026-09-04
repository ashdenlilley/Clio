import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceDiscoverySettings {
    var respectsGitIgnore: Bool { didSet { persist() } }
    var includesHiddenFiles: Bool { didSet { persist() } }
    var includesTextFiles: Bool { didSet { persist() } }
    var enabledBuiltIns: Set<BuiltInExclusion> { didSet { persist() } }
    var additionalPatternsText: String { didSet { persist() } }
    var temporarilyShowsIgnored = false

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private var isInitializing = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.policy),
           let stored = try? JSONDecoder().decode(DiscoveryPolicy.self, from: data) {
            respectsGitIgnore = stored.respectsGitIgnore
            includesHiddenFiles = stored.includesHiddenFiles
            includesTextFiles = stored.includesTextFiles
            enabledBuiltIns = stored.enabledBuiltIns
            additionalPatternsText = stored.additionalPatterns.joined(separator: "\n")
        } else {
            let policy = DiscoveryPolicy.default
            respectsGitIgnore = policy.respectsGitIgnore
            includesHiddenFiles = policy.includesHiddenFiles
            includesTextFiles = policy.includesTextFiles
            enabledBuiltIns = policy.enabledBuiltIns
            additionalPatternsText = ""
        }
        isInitializing = false
    }

    var policy: DiscoveryPolicy {
        DiscoveryPolicy(
            respectsGitIgnore: respectsGitIgnore,
            includesHiddenFiles: includesHiddenFiles,
            includesTextFiles: includesTextFiles,
            enabledBuiltIns: enabledBuiltIns,
            additionalPatterns: additionalPatternsText
                .components(separatedBy: .newlines)
        )
    }

    func set(_ exclusion: BuiltInExclusion, enabled: Bool) {
        if enabled {
            enabledBuiltIns.insert(exclusion)
        } else {
            enabledBuiltIns.remove(exclusion)
        }
    }
}

private extension WorkspaceDiscoverySettings {
    enum Keys {
        static let policy = "workspace.discoveryPolicy"
    }

    func persist() {
        guard !isInitializing,
              let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: Keys.policy)
    }
}

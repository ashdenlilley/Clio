import Darwin
import Foundation

actor WorkspaceScanner {
    enum ScannerError: LocalizedError {
        case rootUnavailable(URL)
        case invalidRelativePath(URL)

        var errorDescription: String? {
            switch self {
            case .rootUnavailable(let url): "Workspace is unavailable at \(url.path)."
            case .invalidRelativePath(let url): "A file escaped its workspace: \(url.path)."
            }
        }
    }

    private let fileManager: FileManager
    private let identityStore: DocumentIdentityStore

    init(
        fileManager: FileManager = .default,
        identityStore: DocumentIdentityStore = .shared
    ) {
        self.fileManager = fileManager
        self.identityStore = identityStore
    }

    func scan(
        workspace: WorkspaceDescriptor,
        policy: DiscoveryPolicy,
        includesIgnored: Bool = false
    ) throws -> WorkspaceTreeSnapshot {
        let rootURL = workspace.rootURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScannerError.rootUnavailable(rootURL)
        }

        var pendingFiles: [PendingFile] = []
        var directories: [(
            url: URL,
            relativePath: String,
            inheritedExclusion: ExclusionReason?,
            matcher: GitIgnoreMatcher
        )] = [(rootURL, "", nil, GitIgnoreMatcher(policy: policy))]

        while let directory = directories.popLast() {
            try Task.checkCancellation()
            var matcher = directory.matcher

            if policy.respectsGitIgnore, directory.inheritedExclusion == nil {
                let ignoreURL = directory.url.appendingPathComponent(".gitignore")
                if let source = try? String(contentsOf: ignoreURL, encoding: .utf8) {
                    matcher.appendGitIgnore(
                        source: source,
                        sourceURL: ignoreURL,
                        baseRelativePath: directory.relativePath
                    )
                }
            }

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: []
                ).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
            } catch where Self.isRacedDisappearance(error) {
                continue
            }

            for childURL in children {
                try Task.checkCancellation()
                let values: URLResourceValues
                do {
                    values = try childURL.resourceValues(forKeys: Set(Self.resourceKeys))
                } catch where Self.isRacedDisappearance(error) {
                    continue
                }

                guard values.isSymbolicLink != true else { continue }
                let relativePath = Self.relativePath(
                    for: childURL,
                    rootURL: rootURL
                )
                guard !relativePath.isEmpty else {
                    if !fileManager.fileExists(atPath: childURL.path) {
                        continue
                    }
                    throw ScannerError.invalidRelativePath(childURL)
                }

                let isHidden = values.isHidden == true || childURL.lastPathComponent.hasPrefix(".")
                if isHidden, !policy.includesHiddenFiles,
                   childURL.lastPathComponent != ".gitignore" {
                    continue
                }

                let exclusionReason = directory.inheritedExclusion
                    ?? matcher.exclusionReason(
                        for: relativePath,
                        isDirectory: values.isDirectory == true
                    )

                if values.isDirectory == true {
                    guard values.isPackage != true else { continue }
                    if exclusionReason == nil || includesIgnored {
                        directories.append((childURL, relativePath, exclusionReason, matcher))
                    }
                    continue
                }

                guard values.isRegularFile == true,
                      Self.isSupportedDocument(childURL, policy: policy) else {
                    continue
                }
                guard exclusionReason == nil || includesIgnored else { continue }
                let identityValues: URLResourceValues
                do {
                    // These keys are intentionally not prefetched above. The
                    // uncached lookup validates that this directory entry is
                    // still live, and its result replaces the later identity
                    // stat on the 25k-file indexing path.
                    identityValues = try childURL.resourceValues(
                        forKeys: Self.identityResourceKeys
                    )
                } catch where Self.isRacedDisappearance(error) {
                    continue
                }

                let locator = try DocumentLocator(
                    workspaceID: workspace.id,
                    relativePath: relativePath
                )
                pendingFiles.append(
                    PendingFile(
                        locator: locator,
                        url: childURL,
                        relativePath: relativePath,
                        physicalIdentity: .authorizedFile(
                            at: childURL,
                            resourceValues: identityValues
                        ),
                        modificationDate: values.contentModificationDate ?? .distantPast,
                        byteCount: Int64(values.fileSize ?? 0),
                        exclusionReason: exclusionReason
                    )
                )
            }
        }

        let ids = try identityStore.resolve(pendingFiles.map {
            DocumentIdentityCandidate(
                locator: $0.locator,
                physicalIdentity: $0.physicalIdentity,
                canonicalPath: $0.url.standardizedFileURL.resolvingSymlinksInPath().path
            )
        })
        var files = zip(pendingFiles, ids).map { pending, id in
            WorkspaceFile(
                documentID: id,
                locator: pending.locator,
                relativePath: pending.relativePath,
                modificationDate: pending.modificationDate,
                byteCount: pending.byteCount,
                exclusionReason: pending.exclusionReason
            )
        }

        files.sort {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        return WorkspaceTreeSnapshot(
            workspace: workspace,
            files: files,
            generatedAt: Date(),
            isComplete: true
        )
    }

    /// Inspects one event path using only the ignore files on its ancestor
    /// chain. This is the fast invalidation path used by the on-disk index.
    func file(
        at fileURL: URL,
        workspace: WorkspaceDescriptor,
        policy: DiscoveryPolicy,
        includesIgnored: Bool = false
    ) throws -> WorkspaceFile? {
        let rootURL = workspace.rootURL.standardizedFileURL
        let standardizedURL = fileURL.standardizedFileURL
        let relativePath = Self.relativePath(for: standardizedURL, rootURL: rootURL)
        guard !relativePath.isEmpty else { return nil }

        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var matcher = GitIgnoreMatcher(policy: policy)
        var directoryURL = rootURL
        var directoryRelativePath = ""
        var inheritedExclusion: ExclusionReason?

        for (offset, component) in components.enumerated() {
            try Task.checkCancellation()
            if policy.respectsGitIgnore, inheritedExclusion == nil {
                let ignoreURL = directoryURL.appendingPathComponent(".gitignore")
                if let source = try? String(contentsOf: ignoreURL, encoding: .utf8) {
                    matcher.appendGitIgnore(
                        source: source,
                        sourceURL: ignoreURL,
                        baseRelativePath: directoryRelativePath
                    )
                }
            }

            let childURL = directoryURL.appendingPathComponent(component)
            let values = try childURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isHiddenKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else { return nil }
            let childRelativePath = components.prefix(offset + 1).joined(separator: "/")
            let isHidden = values.isHidden == true || component.hasPrefix(".")
            if isHidden, !policy.includesHiddenFiles, component != ".gitignore" {
                return nil
            }

            let exclusionReason = inheritedExclusion
                ?? matcher.exclusionReason(
                    for: childRelativePath,
                    isDirectory: values.isDirectory == true
                )

            if offset < components.count - 1 {
                guard values.isDirectory == true, values.isPackage != true else { return nil }
                if exclusionReason != nil, !includesIgnored { return nil }
                inheritedExclusion = exclusionReason
                directoryURL = childURL
                directoryRelativePath = childRelativePath
                continue
            }

            guard values.isRegularFile == true,
                  Self.isSupportedDocument(childURL, policy: policy),
                  exclusionReason == nil || includesIgnored else {
                return nil
            }
            let locator = try DocumentLocator(
                workspaceID: workspace.id,
                relativePath: childRelativePath
            )
            let documentID = try identityStore.resolve(
                DocumentIdentityCandidate(
                    locator: locator,
                    physicalIdentity: .authorizedFile(at: childURL),
                    canonicalPath: childURL.standardizedFileURL.resolvingSymlinksInPath().path
                )
            )
            return WorkspaceFile(
                documentID: documentID,
                locator: locator,
                relativePath: childRelativePath,
                modificationDate: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0),
                exclusionReason: exclusionReason
            )
        }
        return nil
    }
}

private extension WorkspaceScanner {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .contentModificationDateKey,
        .fileSizeKey,
    ]

    static let identityResourceKeys: Set<URLResourceKey> = [
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
    ]

    struct PendingFile {
        let locator: DocumentLocator
        let url: URL
        let relativePath: String
        let physicalIdentity: PhysicalFileIdentity
        let modificationDate: Date
        let byteCount: Int64
        let exclusionReason: ExclusionReason?
    }

    static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return "" }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    static func isRacedDisappearance(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(ENOENT) || error.code == Int(ENOTDIR) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRacedDisappearance(underlying)
        }
        return false
    }

    static func isSupportedDocument(_ url: URL, policy: DiscoveryPolicy) -> Bool {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": true
        case "txt": policy.includesTextFiles
        default: false
        }
    }
}

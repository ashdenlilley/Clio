#if DEBUG
  import Darwin
  import Foundation

  /// Subprocess-only durability probe used by tests. It is unreachable without
  /// an explicit test environment variable and is not compiled into Release.
  enum CrashTestDriver {
    private static let modeKey = "CLIO_CRASH_TEST_MODE"
    private static let rootKey = "CLIO_CRASH_TEST_ROOT"

    static func runIfRequested() {
      let environment = ProcessInfo.processInfo.environment
      guard let mode = environment[modeKey],
        let rootPath = environment[rootKey]
      else { return }
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
      do {
        switch mode {
        case "journal":
          let id = DocumentID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
          )
          let journal = CrashRecoveryJournal(rootURL: rootURL)
          _ = try journal.checkpoint(
            CrashRecoveryRecord(
              documentID: id,
              generation: BufferGeneration(bufferID: id.rawValue, revision: 41),
              filename: "subprocess.md",
              targetURL: nil,
              reason: .dirtyBuffer,
              data: Data("subprocess dirty generation".utf8)
            ))
          terminateAbruptly()
        case "atomic-candidate":
          let destination = rootURL.appendingPathComponent("draft.md")
          let expected = try DocumentRevisionReader.revision(at: destination)
          let writer = AtomicFileWriter(phaseHook: { phase in
            if phase == .candidateSynced { terminateAbruptly() }
          })
          _ = try writer.replace(
            contents: Data("subprocess atomic candidate".utf8),
            at: destination,
            onlyIf: expected
          )
          _exit(92)
        default:
          _exit(93)
        }
      } catch {
        _exit(94)
      }
    }

    private static func terminateAbruptly() -> Never {
      _ = kill(getpid(), SIGKILL)
      _exit(95)
    }
  }
#endif

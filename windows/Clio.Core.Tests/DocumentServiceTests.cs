using System.Text;
using Xunit;

namespace Clio.Core.Tests;

public sealed class DocumentServiceTests : IDisposable
{
    private readonly TempDir _workspace = new();
    private readonly TempDir _support = new();

    public void Dispose()
    {
        _workspace.Dispose();
        _support.Dispose();
    }

    private CrashRecoveryJournal Journal => new(_support["journal"]);
    private RecoveryStore Recovery => new(_support["recovery"]);

    private DocumentService Service(Func<string, FileSnapshot>? read = null) => new(Recovery, Journal, read);

    private string Doc(string content = "base", string name = "doc.md")
    {
        var path = _workspace[name];
        File.WriteAllText(path, content);
        return path;
    }

    private DocumentSession Open(string path) => DocumentSession.Open(path, _workspace.Path);

    private static string Text(byte[] bytes) => Encoding.UTF8.GetString(bytes);

    // ---- shared vectors ------------------------------------------------------------------------

    [Fact]
    public void ScenariosMatchSharedVectors()
    {
        foreach (var scenario in SpecVectors.Load("external-change.json").GetProperty("scenarios").EnumerateArray())
        {
            var name = scenario.GetProperty("name").GetString()!;
            using var workspace = new TempDir();
            using var support = new TempDir();
            var path = workspace["doc.md"];
            File.WriteAllText(path, "base");
            var journal = new CrashRecoveryJournal(support["journal"]);
            var service = new DocumentService(new RecoveryStore(support["recovery"]), journal);
            var session = DocumentSession.Open(path, workspace.Path);

            if (scenario.TryGetProperty("edit", out var edit)) session.SetText(edit.GetString()!);
            if (scenario.TryGetProperty("disk", out var disk))
            {
                if (disk.ValueKind == System.Text.Json.JsonValueKind.Null) File.Delete(path);
                else File.WriteAllText(path, disk.GetString()!);
            }

            var action = scenario.GetProperty("action").GetString()!;
            var result = "?";
            try
            {
                if (action == "reconcile")
                    result = service.ReconcileExternalChange(session) switch
                    {
                        ReconcileResult.Unchanged => "unchanged", ReconcileResult.Reloaded => "reloaded",
                        ReconcileResult.ConflictRaised => "conflict", ReconcileResult.Deleted => "deleted", _ => "?",
                    };
                else if (action == "save")
                {
                    service.Save(session);
                    result = "saved";
                }
                else
                {
                    // Resolve scenarios start from a conflict raised by a reconcile.
                    Assert.Equal(ReconcileResult.ConflictRaised, service.ReconcileExternalChange(session));
                    if (scenario.TryGetProperty("diskAfterConflict", out var again)) File.WriteAllText(path, again.GetString()!);
                    var choice = action["resolve:".Length..] switch
                    {
                        "keepClio" => ConflictChoice.KeepClio, "loadExternal" => ConflictChoice.LoadExternal, _ => ConflictChoice.KeepBoth,
                    };
                    service.Resolve(choice, session);
                    result = "resolved";
                }
            }
            catch (ExternalConflictException) { result = "conflict"; }
            catch (DocumentDeletedException) { result = "deleted"; }
            catch (ConflictResolutionException e) when (e.Failure == ResolutionFailure.ConflictChanged) { result = "conflictChanged"; }

            var expect = scenario.GetProperty("expect");
            Assert.True(expect.GetProperty("result").GetString() == result, $"{name}: result {result}");
            var diskText = File.Exists(path) ? File.ReadAllText(path) : null;
            Assert.True(expect.GetProperty("diskText").GetString() == diskText, $"{name}: disk '{diskText}'");
            Assert.True(expect.GetProperty("bufferText").GetString() == session.Text, $"{name}: buffer '{session.Text}'");
            Assert.True(expect.GetProperty("dirty").GetBoolean() == session.IsDirty, $"{name}: dirty {session.IsDirty}");
            Assert.True(expect.GetProperty("conflict").GetBoolean() == (session.Conflict is not null), $"{name}: conflict");
            var backedBy = session.Path is null ? null : System.IO.Path.GetFileName(session.Path);
            Assert.True(expect.GetProperty("backedBy").GetString() == backedBy, $"{name}: backed by {backedBy}");

            var extra = Directory.EnumerateFiles(workspace.Path).Where(p => System.IO.Path.GetFileName(p) != "doc.md")
                .ToDictionary(p => System.IO.Path.GetFileName(p), File.ReadAllText);
            var wantExtra = expect.GetProperty("extraFiles").EnumerateObject().ToDictionary(f => f.Name, f => f.Value.GetString()!);
            Assert.True(wantExtra.Count == extra.Count && wantExtra.All(w => extra.TryGetValue(w.Key, out var v) && v == w.Value),
                $"{name}: extra files [{string.Join(", ", extra.Keys)}]");

            var preserved = Directory.Exists(support["recovery"]) ? Directory.EnumerateFiles(support["recovery"]).Select(File.ReadAllText).Order().ToList() : [];
            var wantRecovery = expect.GetProperty("recovery").EnumerateArray().Select(r => r.GetString()!).Order().ToList();
            Assert.True(wantRecovery.SequenceEqual(preserved), $"{name}: recovery [{string.Join(", ", preserved)}]");

            var reasons = journal.ValidRecords().Select(r => r.Reason.ToString()).Select(r => char.ToLowerInvariant(r[0]) + r[1..]).Order(StringComparer.Ordinal).ToList();
            var wantReasons = expect.GetProperty("journalReasons").EnumerateArray().Select(r => r.GetString()!).Order(StringComparer.Ordinal).ToList();
            Assert.True(wantReasons.SequenceEqual(reasons), $"{name}: journal [{string.Join(", ", reasons)}]");
            Assert.True(!Directory.EnumerateFiles(workspace.Path, ".clio-*", SearchOption.AllDirectories).Any(), $"{name}: sidecars");
        }
    }

    // ---- save ----------------------------------------------------------------------------------

    [Fact]
    public void SavePreservesBomAndCrLfOfTheOriginal()
    {
        var path = _workspace["crlf.md"];
        File.WriteAllBytes(path, [0xEF, 0xBB, 0xBF, .. "one\r\ntwo\r\n"u8.ToArray()]);
        var session = Open(path);
        Assert.Equal("one\ntwo\n", session.Text);
        session.SetText("one\ntwo\nthree\n");
        Service().Save(session);
        Assert.Equal<byte>([0xEF, 0xBB, 0xBF, .. "one\r\ntwo\r\nthree\r\n"u8.ToArray()], File.ReadAllBytes(path));
    }

    [Fact]
    public void EditsMadeDuringASaveStayDirty()
    {
        var path = Doc();
        var session = Open(path);
        session.SetText("first");
        var edited = false;
        var service = Service(p =>
        {
            var snapshot = FileSnapshots.Read(p);
            if (!edited) { edited = true; session.SetText("later"); }
            return snapshot;
        });
        service.Save(session);
        Assert.Equal("first", File.ReadAllText(path));
        Assert.True(session.IsDirty);
        Assert.Equal("later", session.Text);
        service.Save(session);
        Assert.Equal("later", File.ReadAllText(path));
        Assert.False(session.IsDirty);
    }

    [Fact]
    public void ADetachedDocumentIsNeverResurrectedBySaving()
    {
        var path = Doc();
        var session = Open(path);
        session.SetText("mine");
        File.Delete(path);
        var service = Service();
        Assert.Throws<DocumentDeletedException>(() => service.Save(session));
        Assert.Throws<DetachedDocumentException>(() => service.Save(session));
        Assert.False(File.Exists(path));
        Assert.True(session.RequiresExplicitRestore);
    }

    [Fact]
    public void ADocumentWithNoFileIsNotWrittenByTheService()
    {
        var session = new DocumentSession(workspaceRoot: _workspace.Path);
        session.SetText("untitled text");
        Assert.Throws<UnbackedDocumentException>(() => Service().Save(session));
        Assert.Empty(Directory.EnumerateFiles(_workspace.Path));
    }

    [Fact]
    public void SaveRefusesAFileOutsideTheWorkspace()
    {
        using var other = new TempDir();
        var stray = Path.Combine(other.Path, "stray.md");
        File.WriteAllText(stray, "s");
        var session = DocumentSession.Open(stray, _workspace.Path);
        session.SetText("changed");
        Assert.Throws<FileOutsideWorkspaceException>(() => Service().Save(session));
        Assert.Equal("s", File.ReadAllText(stray));
    }

    [Fact]
    public void DirtyTextIsJournaledBeforeTheWriteAndClearedAfter()
    {
        var path = Doc();
        var session = Open(path);
        session.SetText("mine");
        var journal = Journal;
        var service = new DocumentService(Recovery, journal, p =>
        {
            Assert.Equal("mine", Text(Assert.Single(journal.ValidRecords()).Data)); // present while the save runs
            return FileSnapshots.Read(p);
        });
        service.Save(session);
        Assert.Empty(journal.ValidRecords());
    }

    [Fact]
    public void TheEchoOfOurOwnSaveIsNotAnExternalChange()
    {
        var path = Doc();
        var session = Open(path);
        var service = Service();
        session.SetText("mine");
        service.Save(session);
        session.SetText("mine, edited again");
        Assert.Equal(ReconcileResult.Unchanged, service.ReconcileExternalChange(session));
        Assert.Null(session.Conflict);
    }

    [Fact]
    public void ASelfWriteIsConsumedOnceAndExpires()
    {
        var now = DateTimeOffset.UtcNow;
        var path = Doc();
        var session = Open(path);
        var service = new DocumentService(Recovery, Journal, now: () => now);
        session.SetText("mine");
        service.Save(session);
        var revision = DocumentIO.CurrentRevision(path);
        Assert.True(service.ConsumeSelfWrite(path, revision));
        Assert.False(service.ConsumeSelfWrite(path, revision));

        session.SetText("again");
        service.Save(session);
        now += TimeSpan.FromSeconds(6);
        Assert.False(service.ConsumeSelfWrite(path, DocumentIO.CurrentRevision(path)));
    }

    // ---- conflicts -----------------------------------------------------------------------------

    [Fact]
    public void ResolvingWithoutAConflictIsRefused()
    {
        var session = Open(Doc());
        var ex = Assert.Throws<ConflictResolutionException>(() => Service().Resolve(ConflictChoice.KeepClio, session));
        Assert.Equal(ResolutionFailure.NoConflict, ex.Failure);
    }

    [Fact]
    public void TypingDuringAResolutionRefusesIt()
    {
        var path = Doc();
        var session = Open(path);
        var typing = false;
        var service = Service(p =>
        {
            var snapshot = FileSnapshots.Read(p);
            if (typing) { typing = false; session.SetText("mine, and more"); }
            return snapshot;
        });
        session.SetText("mine");
        File.WriteAllText(path, "outside");
        Assert.Equal(ReconcileResult.ConflictRaised, service.ReconcileExternalChange(session));

        typing = true; // the user types while the resolution is reading the disk
        var ex = Assert.Throws<ConflictResolutionException>(() => service.Resolve(ConflictChoice.KeepClio, session));
        Assert.Equal(ResolutionFailure.ConflictChanged, ex.Failure);
        Assert.Equal("outside", File.ReadAllText(path));
        Assert.NotNull(session.Conflict);
        Assert.Equal("mine, and more", session.Text);
    }

    [Fact]
    public void TypingBeforeResolvingIsIncludedInTheChosenText()
    {
        var path = Doc();
        var session = Open(path);
        var service = Service();
        session.SetText("mine");
        File.WriteAllText(path, "outside");
        service.ReconcileExternalChange(session);
        session.SetText("mine, and more");

        service.Resolve(ConflictChoice.KeepClio, session);
        Assert.Equal("mine, and more", File.ReadAllText(path));
        Assert.False(session.IsDirty);
    }

    [Fact]
    public void ResolvingDeletesTheRetainedSidecarOfTheOutsideSide()
    {
        var path = Doc();
        var session = Open(path);
        var service = Service();
        session.SetText("mine");
        File.WriteAllText(path, "outside");
        service.ReconcileExternalChange(session);
        var sidecar = _workspace[".clio-displaced-doc.md"];
        File.WriteAllText(sidecar, "displaced");
        var conflict = session.Conflict!;
        session.RegisterConflict(conflict with { External = conflict.External with { RetainedPaths = [sidecar] } });

        service.Resolve(ConflictChoice.KeepClio, session);
        Assert.False(File.Exists(sidecar));
    }

    [Fact]
    public void AdditionalOutsideVersionsAreKeptBeforeResolving()
    {
        var path = Doc();
        var session = Open(path);
        var service = Service();
        session.SetText("mine");
        File.WriteAllText(path, "outside");
        service.ReconcileExternalChange(session);
        var conflict = session.Conflict!;
        var displaced = new ConflictSide(DateTimeOffset.UtcNow, null, "older outside"u8.ToArray());
        session.RegisterConflict(conflict with { AdditionalExternalVersions = [displaced] });

        service.Resolve(ConflictChoice.KeepClio, session);
        var kept = Directory.EnumerateFiles(_support["recovery"]).Select(File.ReadAllText).Order().ToList();
        Assert.Equal(["older outside", "outside"], kept);
        Assert.Equal("mine", File.ReadAllText(path));
    }

    [Fact]
    public void DeletionKeepsEveryOutsideVersionAndDetaches()
    {
        var path = Doc();
        var session = Open(path);
        var service = Service();
        session.SetText("mine");
        File.WriteAllText(path, "outside");
        service.ReconcileExternalChange(session);
        File.Delete(path);

        service.DetachAfterExternalDeletion(session);
        Assert.True(session.RequiresExplicitRestore);
        Assert.Equal("mine", session.Text);
        Assert.Equal(["outside"], Directory.EnumerateFiles(_support["recovery"]).Select(File.ReadAllText));
        Assert.Contains(Journal.ValidRecords(), r => r.Reason == RecoveryReason.ExternalDeletion && Text(r.Data) == "mine");
    }

    [Fact]
    public void DeletionThatWasUndoneIsNotDetached()
    {
        var path = Doc();
        var session = Open(path);
        var service = Service();
        session.SetText("mine");
        // The file is back by the time deletion is confirmed.
        File.WriteAllText(path, "restored elsewhere");
        var ex = Assert.Throws<ConflictResolutionException>(() => service.DetachAfterExternalDeletion(session));
        Assert.Equal(ResolutionFailure.ConflictChanged, ex.Failure);
        Assert.True(session.IsBackedByFile);
        Assert.NotNull(session.Conflict);
    }

    // ---- autosave ------------------------------------------------------------------------------

    /// <summary>A save swaps files, so a concurrent reader can briefly find the path absent or locked.</summary>
    private static string? ReadOrNull(string path)
    {
        try { return File.ReadAllText(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static async Task Until(Func<bool> condition, string message)
    {
        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (DateTime.UtcNow < deadline)
        {
            if (condition()) return;
            await Task.Delay(10);
        }
        Assert.Fail(message);
    }

    [Fact]
    public async Task RapidEditsCoalesceIntoOneWrite()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromMilliseconds(80));
        for (var i = 0; i < 10; i++)
        {
            session.SetText($"edit {i}");
            autosaver.DocumentDidChange(session);
        }
        await Until(() => ReadOrNull(path) == "edit 9" && !autosaver.HasPendingSave, "autosave never wrote");
        Assert.Equal(1, autosaver.SaveAttemptCount);
        Assert.False(session.IsDirty);
        Assert.Null(autosaver.LastError);
    }

    [Fact]
    public async Task AnEditIsJournaledImmediatelyEvenBeforeTheDebounceFires()
    {
        var path = Doc();
        var session = Open(path);
        var journal = Journal;
        using var autosaver = new Autosaver(new DocumentService(Recovery, journal), TimeSpan.FromSeconds(30));
        session.SetText("protected text");
        autosaver.DocumentDidChange(session);
        journal.Flush();
        Assert.Equal("protected text", Text(Assert.Single(journal.ValidRecords()).Data));
        Assert.Equal("base", File.ReadAllText(path));
        await Task.CompletedTask;
    }

    [Fact]
    public async Task SuspendedAutosaveWaitsForResume()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromMilliseconds(30));
        autosaver.SuspendForFileOperation();
        session.SetText("during move");
        autosaver.DocumentDidChange(session);
        await Task.Delay(300);
        Assert.Equal("base", File.ReadAllText(path));
        Assert.Throws<AutosaveBusyException>(() => autosaver.Flush(session));

        autosaver.ResumeAfterFileOperation();
        await Until(() => ReadOrNull(path) == "during move", "autosave never resumed");
    }

    [Fact]
    public async Task ConflictStopsAutosaveUntilTheUserActs()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromMilliseconds(30));
        File.WriteAllText(path, "outside");
        session.SetText("mine");
        autosaver.DocumentDidChange(session);
        await Until(() => autosaver.LastError is ExternalConflictException && !autosaver.HasPendingSave, "no conflict reported");

        var attempts = autosaver.SaveAttemptCount;
        session.SetText("mine, still typing");
        autosaver.DocumentDidChange(session);
        await Task.Delay(300);
        Assert.Equal("outside", File.ReadAllText(path));
        Assert.Equal(attempts, autosaver.SaveAttemptCount);
        Assert.False(autosaver.HasPendingSave);
    }

    [Fact]
    public async Task DeletedFileStopsAutosaveAndStaysDeleted()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromMilliseconds(30));
        File.Delete(path);
        session.SetText("mine");
        autosaver.DocumentDidChange(session);
        await Until(() => autosaver.LastError is DocumentDeletedException, "deletion not reported");

        session.SetText("mine again");
        autosaver.DocumentDidChange(session);
        await Task.Delay(300);
        Assert.False(File.Exists(path));
        Assert.True(session.RequiresExplicitRestore);
    }

    [Fact]
    public async Task FlushWritesNowAndFlushAsyncAwaitsTheWrite()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromSeconds(30));
        session.SetText("sync flush");
        Assert.Equal(path, autosaver.Flush(session), ignoreCase: true);
        Assert.Equal("sync flush", File.ReadAllText(path));

        session.SetText("async flush");
        Assert.Equal(path, await autosaver.FlushAsync(session), ignoreCase: true);
        Assert.Equal("async flush", File.ReadAllText(path));
        Assert.False(autosaver.HasPendingSave);
    }

    [Fact]
    public async Task FlushReportsAConflictInsteadOfOverwriting()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromSeconds(30));
        File.WriteAllText(path, "outside");
        session.SetText("mine");
        Assert.Throws<ExternalConflictException>(() => autosaver.Flush(session));
        await Assert.ThrowsAsync<ExternalConflictException>(() => autosaver.FlushAsync(session));
        Assert.Equal("outside", File.ReadAllText(path));
    }

    [Fact]
    public async Task TypingThroughASaveEndsWithTheNewestTextOnDisk()
    {
        var path = Doc();
        var session = Open(path);
        using var autosaver = new Autosaver(Service(), TimeSpan.FromMilliseconds(15));
        for (var i = 0; i < 60; i++)
        {
            session.SetText($"keystroke {i}");
            autosaver.DocumentDidChange(session);
            await Task.Delay(4);
        }
        await Until(() => ReadOrNull(path) == "keystroke 59" && !autosaver.HasPendingSave, "newest text never reached disk");
        Assert.False(session.IsDirty);
    }

    [Fact]
    public async Task DocumentsWithoutAFileAreJournaledNotWritten()
    {
        var journal = Journal;
        using var autosaver = new Autosaver(new DocumentService(Recovery, journal), TimeSpan.FromMilliseconds(20));
        var session = new DocumentSession(workspaceRoot: _workspace.Path);
        session.SetText("new text");
        autosaver.DocumentDidChange(session);
        journal.Flush();
        await Task.Delay(200);
        Assert.Empty(Directory.EnumerateFiles(_workspace.Path));
        Assert.Equal("new text", Text(Assert.Single(journal.ValidRecords()).Data));
    }

    // ---- startup recovery ----------------------------------------------------------------------

    [Fact]
    public void StartupSettlesAnInterruptedSaveIntoARecoveryCopy()
    {
        var path = Doc("original");
        Assert.ThrowsAny<Exception>(() => AtomicFile.Write(path, "new bytes"u8, null, phase =>
        {
            if (phase == AtomicWritePhase.CandidateSynced) throw new InvalidOperationException("killed");
        }));
        var report = StartupRecovery.Run([_workspace.Path], Journal, Recovery);
        Assert.True(report.AtomicWritesRecovered >= 1);
        Assert.Equal(0, report.PendingBuffers);
        Assert.Empty(Journal.ValidRecords());
        Assert.Contains("new bytes", Directory.EnumerateFiles(_support["recovery"]).Select(File.ReadAllText));
        Assert.Equal("original", File.ReadAllText(path));
    }

    [Fact]
    public void StartupSettlesAnInterruptedMove()
    {
        var source = Doc("moving");
        var mover = new DocumentMover(Recovery, Journal, phaseHook: phase =>
        {
            if (phase == MovePhase.DestinationInstalled) throw new InvalidOperationException("killed");
        });
        Assert.Throws<InvalidOperationException>(() => mover.Move(new MoveRequest(source, _workspace.Path, _workspace.Path, Guid.NewGuid(), "n")));

        var report = StartupRecovery.Run([_workspace.Path], Journal, Recovery);
        Assert.Equal(1, report.MovesRecovered);
        Assert.False(File.Exists(source));
        Assert.Equal("moving", File.ReadAllText(Path.Combine(_workspace.Path, "n", "doc.md")));
    }

    [Fact]
    public void ARecordAlreadyOnDiskIsDroppedWithoutACopy()
    {
        var path = Doc("same bytes");
        var journal = Journal;
        journal.Checkpoint(CrashRecoveryRecord.Create(Guid.NewGuid(), default, "doc.md", path, RecoveryReason.DirtyBuffer, "same bytes"u8.ToArray()));
        var report = StartupRecovery.Run([_workspace.Path], journal, Recovery);
        Assert.Equal(0, report.RecoveredBuffers);
        Assert.Empty(journal.ValidRecords());
        Assert.False(Directory.Exists(_support["recovery"]) && Directory.EnumerateFiles(_support["recovery"]).Any());
    }

    [Fact]
    public void ARecordThatDiffersIsPreservedNeverRestoredOverTheFile()
    {
        var path = Doc("on disk");
        var journal = Journal;
        journal.Checkpoint(CrashRecoveryRecord.Create(Guid.NewGuid(), default, "doc.md", path, RecoveryReason.DirtyBuffer, "unsaved text"u8.ToArray()));
        var report = StartupRecovery.Run([_workspace.Path], journal, Recovery);
        Assert.Equal(1, report.RecoveredBuffers);
        Assert.Equal("on disk", File.ReadAllText(path));
        Assert.Equal(["unsaved text"], Directory.EnumerateFiles(_support["recovery"]).Select(File.ReadAllText));
        Assert.Empty(journal.ValidRecords());
    }

    [Fact]
    public void ARecordThatCannotBePreservedStaysInTheJournal()
    {
        var journal = Journal;
        journal.Checkpoint(CrashRecoveryRecord.Create(Guid.NewGuid(), default, "doc.md", null, RecoveryReason.DirtyBuffer, "precious"u8.ToArray()));
        File.WriteAllText(_support["blocked"], "a file where the recovery folder should be");
        var report = StartupRecovery.Run([_workspace.Path], journal, new RecoveryStore(_support["blocked"]));
        Assert.Equal(1, report.PendingBuffers);
        Assert.Equal("precious", Text(Assert.Single(journal.ValidRecords()).Data));
    }

    [Fact]
    public void ARecordTargetingALinkIsNotTreatedAsCanonical()
    {
        using var elsewhere = new TempDir();
        var target = Path.Combine(elsewhere.Path, "real.md");
        File.WriteAllText(target, "linked bytes");
        var link = _workspace["link.md"];
        if (!TempDir.TryCreateSymlink(link, target)) return; // needs the symlink privilege
        var journal = Journal;
        journal.Checkpoint(CrashRecoveryRecord.Create(Guid.NewGuid(), default, "link.md", link, RecoveryReason.DirtyBuffer, "linked bytes"u8.ToArray()));
        var report = StartupRecovery.Run([_workspace.Path], journal, Recovery);
        Assert.Equal(1, report.RecoveredBuffers);
    }
}

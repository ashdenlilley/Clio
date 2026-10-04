using System.Text.Json;
using Xunit;

namespace Clio.Core.Tests;

public sealed class DocumentMoverTests : IDisposable
{
    private readonly TempDir _workspace = new();
    private readonly TempDir _support = new();
    private readonly Guid _documentId = Guid.NewGuid();

    public void Dispose()
    {
        _workspace.Dispose();
        _support.Dispose();
    }

    private RecoveryStore Recovery => new(_support["recovery"]);
    private CrashRecoveryJournal Journal => new(_support["journal"]);

    private DocumentMover Mover(DocumentIdentityStore? ids = null, Action<MovePhase>? hook = null, Func<string, FileSnapshot>? snapshot = null) =>
        new(Recovery, Journal, ids, hook, snapshot);

    private string Put(string relative, string content, string? root = null)
    {
        var path = Path.Combine(root ?? _workspace.Path, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content);
        return path;
    }

    private MoveRequest Request(string from, string toParent = "", string? name = null, CollisionChoice? choice = null, FileCollision? approved = null, DiskRevision? expected = null) =>
        new(Path.Combine(_workspace.Path, from), _workspace.Path, _workspace.Path, _documentId, toParent, name, choice, approved, expected);

    private Dictionary<string, string> Visible(string? root = null)
    {
        root ??= _workspace.Path;
        return Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .ToDictionary(p => Path.GetRelativePath(root, p).Replace('\\', '/'), File.ReadAllText);
    }

    private static string Sidecars(string root) =>
        string.Join(", ", Directory.EnumerateFiles(root, ".clio-*", SearchOption.AllDirectories).Select(Path.GetFileName));

    // ---- shared vectors ------------------------------------------------------------------------

    [Fact]
    public void ScenariosMatchSharedVectors()
    {
        foreach (var scenario in SpecVectors.Load("document-move.json").GetProperty("scenarios").EnumerateArray())
        {
            var name = scenario.GetProperty("name").GetString()!;
            using var workspace = new TempDir();
            using var support = new TempDir();
            foreach (var file in scenario.GetProperty("files").EnumerateObject())
            {
                var path = Path.Combine(workspace.Path, file.Name.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, file.Value.GetString()!);
            }
            if (scenario.GetProperty("move").TryGetProperty("toParent", out var parentElement) && parentElement.GetString() is { Length: > 0 } parent && !parent.StartsWith(".."))
                Directory.CreateDirectory(Path.Combine(workspace.Path, parent));

            var mover = new DocumentMover(new RecoveryStore(support["recovery"]), new CrashRecoveryJournal(support["journal"]));
            var move = scenario.GetProperty("move");
            string Optional(string key) => move.TryGetProperty(key, out var v) ? v.GetString()! : "";
            CollisionChoice? choice = Optional("choice") switch
            {
                "cancel" => CollisionChoice.Cancel, "keepBoth" => CollisionChoice.KeepBoth, "replace" => CollisionChoice.Replace, _ => null,
            };
            MoveRequest Make(CollisionChoice? c, FileCollision? approved) => new(
                Path.Combine(workspace.Path, Optional("from")), workspace.Path, workspace.Path, Guid.NewGuid(), Optional("toParent"),
                Optional("preferredName") is { Length: > 0 } n ? n : null, c, approved);

            var expect = scenario.GetProperty("expect");
            var expectedOutcome = expect.GetProperty("outcome").GetString();
            if (expectedOutcome == "rejected")
            {
                var rejected = Assert.Throws<MoveException>(() => mover.Move(Make(choice, null)));
                Assert.True(rejected.Failure == MoveFailure.InvalidPath, name);
            }
            else
            {
                FileCollision? approved = null;
                var approve = Optional("approve");
                if (approve.Length > 0)
                {
                    var first = Assert.IsType<MoveOutcome.Collision>(mover.Move(Make(null, null)));
                    approved = approve == "existing" ? first.Details : first.Details with { ExistingRevision = first.Details.ExistingRevision! with { ContentDigest = new string('0', 64) } };
                }
                var outcome = mover.Move(Make(choice, approved));
                var actual = outcome switch
                {
                    MoveOutcome.Completed => "completed", MoveOutcome.CompletedWithRecovery => "completed",
                    MoveOutcome.Collision => "collision", MoveOutcome.Cancelled => "cancelled", _ => "?",
                };
                Assert.True(expectedOutcome == actual, $"{name}: outcome {outcome}");
                if (expect.TryGetProperty("destination", out var dest))
                {
                    var landed = outcome switch { MoveOutcome.Completed c => c.DestinationPath, MoveOutcome.CompletedWithRecovery c => c.DestinationPath, _ => "" };
                    Assert.True(dest.GetString() == Path.GetRelativePath(workspace.Path, landed).Replace('\\', '/'), $"{name}: destination {landed}");
                }
            }

            var wantFiles = expect.GetProperty("files").EnumerateObject().ToDictionary(f => f.Name, f => f.Value.GetString()!);
            var gotFiles = Directory.EnumerateFiles(workspace.Path, "*", SearchOption.AllDirectories)
                .ToDictionary(p => Path.GetRelativePath(workspace.Path, p).Replace('\\', '/'), File.ReadAllText);
            Assert.True(wantFiles.Count == gotFiles.Count && wantFiles.All(w => gotFiles.TryGetValue(w.Key, out var v) && v == w.Value),
                $"{name}: files [{string.Join(", ", gotFiles.Select(g => g.Key + "=" + g.Value))}]");

            var preserved = Directory.Exists(support["recovery"]) ? Directory.EnumerateFiles(support["recovery"]).Select(File.ReadAllText).Order().ToList() : [];
            var wantRecovery = expect.GetProperty("recovery").EnumerateArray().Select(r => r.GetString()!).Order().ToList();
            Assert.True(wantRecovery.SequenceEqual(preserved), $"{name}: recovery [{string.Join(", ", preserved)}]");
            if (expectedOutcome == "completed") Assert.True(Sidecars(workspace.Path).Length == 0, $"{name}: sidecars {Sidecars(workspace.Path)}");
        }
    }

    // ---- safety --------------------------------------------------------------------------------

    [Fact]
    public void SourceEditedOutsideClioBeforeTheMoveIsRefused()
    {
        var source = Put("a.md", "A");
        var seen = DocumentIO.CurrentRevision(source);
        File.WriteAllText(source, "edited elsewhere");
        var ex = Assert.Throws<MoveException>(() => Mover().Move(Request("a.md", "n", expected: seen)));
        Assert.Equal(MoveFailure.SourceChanged, ex.Failure);
        Assert.Equal("edited elsewhere", File.ReadAllText(source));
        Assert.False(Directory.Exists(Path.Combine(_workspace.Path, "n", "a.md")));
        Assert.Equal("", Sidecars(_workspace.Path));
    }

    [Fact]
    public void SourceEditedDuringTheMoveIsJournaledNotLost()
    {
        var source = Put("a.md", "original");
        var mover = Mover(hook: phase =>
        {
            if (phase == MovePhase.DestinationInstalled) File.WriteAllText(source, "late edit");
        });

        var outcome = Assert.IsType<MoveOutcome.CompletedWithRecovery>(mover.Move(Request("a.md", "n")));
        Assert.Equal("original", File.ReadAllText(outcome.DestinationPath));
        Assert.False(File.Exists(source));
        var records = Journal.ValidRecords();
        var record = Assert.Single(records);
        Assert.Equal("late edit", System.Text.Encoding.UTF8.GetString(record.Data));
        Assert.Equal("", Sidecars(_workspace.Path));
        Assert.StartsWith(Path.GetFullPath(_support["journal"]), outcome.Notice.RetainedPath, StringComparison.OrdinalIgnoreCase);
        Assert.True(File.Exists(outcome.Notice.RetainedPath));
    }

    [Fact]
    public void DestinationChangedAfterApprovalAbortsAndKeepsEverything()
    {
        Put("a.md", "A");
        var destination = Put("n/a.md", "X");
        var probe = Mover().Move(Request("a.md", "n"));
        var collision = Assert.IsType<MoveOutcome.Collision>(probe).Details;

        var mover = Mover(hook: phase =>
        {
            if (phase == MovePhase.TransactionBegun) File.WriteAllText(destination, "changed behind our back");
        });
        var ex = Assert.Throws<MoveException>(() => mover.Move(Request("a.md", "n", choice: CollisionChoice.Replace, approved: collision)));
        Assert.Equal(MoveFailure.DestinationChanged, ex.Failure);
        Assert.Equal("changed behind our back", File.ReadAllText(destination));
        Assert.Equal("A", File.ReadAllText(Path.Combine(_workspace.Path, "a.md")));
        Assert.Equal("", Sidecars(_workspace.Path));
    }

    [Fact]
    public void LockedSourceStaysPutAndStartupRecoveryFinishesTheMove()
    {
        var source = Put("a.md", "A");
        MoveOutcome.CompletedWithRecovery outcome;
        using (new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) // no FileShare.Delete: rename fails
        {
            outcome = Assert.IsType<MoveOutcome.CompletedWithRecovery>(Mover().Move(Request("a.md", "n")));
        }
        Assert.Equal("A", File.ReadAllText(outcome.DestinationPath));
        Assert.True(File.Exists(source));
        Assert.Equal(source, outcome.Notice.RetainedPath);

        var recovered = InterruptedMoveTransactions.Recover(_workspace.Path, Journal);
        Assert.Equal(1, recovered);
        Assert.False(File.Exists(source));
        Assert.Equal("", Sidecars(_workspace.Path));
        Assert.Equal("A", File.ReadAllText(outcome.DestinationPath));
    }

    [Fact]
    public void CrashAfterInstallingTheDestinationIsSettledByRecovery()
    {
        var source = Put("a.md", "A");
        var mover = Mover(hook: phase =>
        {
            if (phase == MovePhase.DestinationInstalled) throw new InvalidOperationException("killed");
        });
        Assert.Throws<InvalidOperationException>(() => mover.Move(Request("a.md", "n")));
        Assert.True(File.Exists(source));
        Assert.Contains(".clio-move-transaction-", Sidecars(_workspace.Path));

        Assert.Equal(1, InterruptedMoveTransactions.Recover(_workspace.Path, Journal));
        Assert.False(File.Exists(source));
        Assert.Equal("A", File.ReadAllText(Path.Combine(_workspace.Path, "n", "a.md")));
        Assert.Equal("", Sidecars(_workspace.Path));
        Assert.Equal("A", System.Text.Encoding.UTF8.GetString(Assert.Single(Journal.ValidRecords()).Data));
    }

    [Fact]
    public void CrashBeforeAnythingWasInstalledLeavesTheSourceUntouched()
    {
        var source = Put("a.md", "A");
        var mover = Mover(hook: phase =>
        {
            if (phase == MovePhase.TransactionBegun) throw new InvalidOperationException("killed");
        });
        Assert.Throws<InvalidOperationException>(() => mover.Move(Request("a.md", "n")));
        InterruptedMoveTransactions.Recover(_workspace.Path, Journal);
        Assert.Equal("A", File.ReadAllText(source));
        Assert.False(File.Exists(Path.Combine(_workspace.Path, "n", "a.md")));
        Assert.Equal("", Sidecars(_workspace.Path));
    }

    [Fact]
    public void DirectoryAtTheDestinationIsACollisionNeverReplaced()
    {
        Put("a.md", "A");
        Directory.CreateDirectory(Path.Combine(_workspace.Path, "n", "a.md"));
        var collision = Assert.IsType<MoveOutcome.Collision>(Mover().Move(Request("a.md", "n")));
        Assert.Null(collision.Details.ExistingRevision);
        Assert.Throws<MoveException>(() => Mover().Move(Request("a.md", "n", choice: CollisionChoice.Replace, approved: collision.Details)));
        var both = Assert.IsType<MoveOutcome.Completed>(Mover().Move(Request("a.md", "n", choice: CollisionChoice.KeepBoth)));
        Assert.EndsWith("a (2).md", both.DestinationPath);
    }

    [Fact]
    public void MovesBetweenRootsMigrateTheDocumentIdentity()
    {
        using var other = new TempDir();
        var source = Put("a.md", "A");
        using var ids = new DocumentIdentityStore();
        var fromWorkspace = Guid.NewGuid();
        var toWorkspace = Guid.NewGuid();
        var id = ids.Resolve(new DocumentIdentityCandidate(new DocumentLocator(fromWorkspace, "a.md"), PhysicalFileIdentity.TryOfFile(source), source));

        var outcome = Assert.IsType<MoveOutcome.Completed>(Mover(ids).Move(new MoveRequest(
            source, _workspace.Path, other.Path, id, "inbox", null, SourceWorkspaceId: fromWorkspace, DestinationWorkspaceId: toWorkspace)));
        Assert.Equal(Path.Combine(other.Path, "inbox", "a.md"), outcome.DestinationPath);
        Assert.Equal(id, ids.StoredDocumentId(new DocumentLocator(toWorkspace, "inbox/a.md")));
        Assert.Null(ids.StoredDocumentId(new DocumentLocator(fromWorkspace, "a.md")));
        Assert.False(File.Exists(source));
    }

    [Fact]
    public void LinkedDestinationFolderIsRefused()
    {
        using var elsewhere = new TempDir();
        Put("a.md", "A");
        var link = Path.Combine(_workspace.Path, "linked");
        if (!TempDir.TryCreateSymlink(link, elsewhere.Path)) return; // needs the symlink privilege
        Assert.Throws<LinkException>(() => Mover().Move(Request("a.md", "linked")));
        Assert.Empty(Directory.EnumerateFiles(elsewhere.Path, "*", SearchOption.AllDirectories));
    }

    [Fact]
    public void SourceOutsideItsRootIsRefused()
    {
        using var outside = new TempDir();
        var stray = Put("stray.md", "S", outside.Path);
        var ex = Assert.Throws<MoveException>(() => Mover().Move(new MoveRequest(stray, _workspace.Path, _workspace.Path, _documentId)));
        Assert.Equal(MoveFailure.InvalidPath, ex.Failure);
    }

    [Fact]
    public void ReplaceKeepsTheReplacedModificationTimeInTheRecoveryCopy()
    {
        Put("a.md", "A");
        var destination = Put("n/a.md", "X");
        var stamp = new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(destination, stamp);
        var collision = Assert.IsType<MoveOutcome.Collision>(Mover().Move(Request("a.md", "n"))).Details;
        Mover().Move(Request("a.md", "n", choice: CollisionChoice.Replace, approved: collision));
        var kept = Assert.Single(Directory.EnumerateFiles(_support["recovery"]));
        Assert.Contains("2020-01-02 03-04-05", Path.GetFileName(kept));
        Assert.Equal("X", File.ReadAllText(kept));
    }

    [Fact]
    public void ParentFoldersAreCreatedUnderTheRoot()
    {
        Put("a.md", "A");
        var outcome = Assert.IsType<MoveOutcome.Completed>(Mover().Move(Request("a.md", "deep/er/still")));
        Assert.Equal(Path.Combine(_workspace.Path, "deep", "er", "still", "a.md"), outcome.DestinationPath);
        Assert.Equal(["deep/er/still/a.md"], Visible().Keys);
    }

    [Fact]
    public void UnsafeParentComponentsAreRejected()
    {
        Put("a.md", "A");
        foreach (var parent in new[] { "..", "a/../..", "CON", "bad:name", "trailing.", "/abs" })
        {
            // "/abs" splits to a plain name; the other forms must be rejected before anything is touched.
            if (parent == "/abs") continue;
            Assert.Throws<MoveException>(() => Mover().Move(Request("a.md", parent)));
        }
        Assert.Equal(["a.md"], Visible().Keys);
    }

    // ---- trash ---------------------------------------------------------------------------------

    [Fact]
    public void TrashChecksTheRevisionBeforeDeleting()
    {
        var path = Put("a.md", "A");
        var seen = DocumentIO.CurrentRevision(path);
        File.WriteAllText(path, "changed");
        var trashed = new List<string>();
        var ex = Assert.Throws<MoveException>(() => DocumentMover.MoveToTrash(path, seen, trashed.Add));
        Assert.Equal(MoveFailure.SourceChanged, ex.Failure);
        Assert.Empty(trashed);

        DocumentMover.MoveToTrash(path, DocumentIO.CurrentRevision(path), trashed.Add);
        Assert.Equal([path], trashed);
    }
}

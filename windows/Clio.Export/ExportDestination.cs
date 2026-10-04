using Clio.Core;

namespace Clio.Export;

/// <summary>Where the bytes will land and whether that creates a new file or replaces one whose revision the user approved.</summary>
public sealed record ExportReservation(string Path, DiskRevision? ReplaceIf);

public static class ExportDestination
{
    public static ExportReservation Resolve(string requestedPath, ExportCollisionResolution? resolution)
    {
        var path = System.IO.Path.GetFullPath(requestedPath);
        // GetFullPath trims trailing dots and spaces, so the name is judged as the user typed it.
        var name = System.IO.Path.GetFileName(requestedPath);
        // Reserved device names (CON, NUL), trailing dots and illegal characters never become export destinations.
        if (name.Length == 0 || !FileNames.IsSafeComponent(name)) throw new UnsupportedDestinationException(path);
        var current = CollisionAt(path);
        if (resolution is null)
            return current is null ? new ExportReservation(path, null) : throw new DestinationExistsException(current);
        if (!SamePath(resolution.Collision.DestinationPath, path)) throw new InvalidCollisionResolutionException();

        switch (resolution.Choice)
        {
            case CollisionChoice.Cancel:
                throw new OperationCanceledException();
            case CollisionChoice.Replace:
                if (current is null || current.Revision != resolution.Collision.Revision)
                    throw new DestinationChangedException(path, current);
                return new ExportReservation(path, resolution.Collision.Revision);
            default:
                var directory = System.IO.Path.GetDirectoryName(path)!;
                var available = FileNames.Available(name, candidate => Occupied(System.IO.Path.Combine(directory, candidate)));
                return new ExportReservation(System.IO.Path.Combine(directory, available), null);
        }
    }

    /// <summary>The regular file at <paramref name="path"/>, or null. Directories, links and junctions are not destinations.</summary>
    public static ExportCollision? CollisionAt(string path)
    {
        if (Directory.Exists(path)) throw new UnsupportedDestinationException(path);
        FileAttributes attributes;
        try { attributes = File.GetAttributes(path); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        if (attributes.HasFlag(FileAttributes.ReparsePoint) || attributes.HasFlag(FileAttributes.Directory))
            throw new UnsupportedDestinationException(path);
        return new ExportCollision(path, DocumentIO.CurrentRevision(path));
    }

    public static void Commit(ExportReservation reservation, byte[] bytes)
    {
        var directory = System.IO.Path.GetDirectoryName(reservation.Path)!;
        if (!Directory.Exists(directory)) throw new UnsupportedDestinationException(reservation.Path);
        try
        {
            if (reservation.ReplaceIf is { } expected)
            {
                AtomicFile.Write(reservation.Path, bytes, expected);
            }
            else if (!AtomicFile.TryCreate(reservation.Path, bytes))
            {
                // Someone created the name after we looked: ask again rather than overwrite.
                var current = CollisionAt(reservation.Path);
                throw current is null
                    ? new DestinationChangedException(reservation.Path, null)
                    : new DestinationExistsException(current);
            }
        }
        catch (ConflictException)
        {
            ExportCollision? current = null;
            try { current = CollisionAt(reservation.Path); } catch (ClioException) { }
            throw new DestinationChangedException(reservation.Path, current);
        }
    }

    private static bool Occupied(string path) => File.Exists(path) || Directory.Exists(path);

    private static bool SamePath(string a, string b) =>
        string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    private static string Normalize(string path) => System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path));
}

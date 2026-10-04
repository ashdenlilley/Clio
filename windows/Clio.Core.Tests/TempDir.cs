namespace Clio.Core.Tests;

/// <summary>A throwaway directory under the system temp path. Tests never touch real documents.</summary>
internal sealed class TempDir : IDisposable
{
    public string Path { get; } = Directory.CreateTempSubdirectory("clio-test-").FullName;

    public string this[string name] => System.IO.Path.Combine(Path, name);

    public string Sub(string name)
    {
        var p = this[name];
        Directory.CreateDirectory(p);
        return p;
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>Symbolic links need a privilege most test machines lack; callers skip when this returns false.</summary>
    public static bool TryCreateSymlink(string link, string target)
    {
        try { File.CreateSymbolicLink(link, target); return true; }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return false; }
    }
}

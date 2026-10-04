using System.Text;

namespace Clio.McpBridge;

internal static class Program
{
    private static async Task<int> Main()
    {
        var token = Environment.GetEnvironmentVariable(StdioBridge.TokenVariable);
        StdioBridge bridge;
        try
        {
            bridge = new StdioBridge(token ?? "");
        }
        catch (ArgumentException)
        {
            // Never echo the value: it is a credential.
            Console.Error.WriteLine($"Set {StdioBridge.TokenVariable} using a token from Clio's MCP settings.");
            return 1;
        }
        using (bridge)
        {
            await bridge.RunAsync(Console.OpenStandardInput(), Console.OpenStandardOutput(), Console.OpenStandardError());
        }
        return 0;
    }
}

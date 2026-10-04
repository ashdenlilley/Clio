using Clio.Editor.Commands;
using Xunit;

namespace Clio.Intelligence.Tests;

public class IntelligenceServiceTests
{
    private static string Paste => string.Join("\n", Enumerable.Range(0, 30).Select(i => $"line number {i} of some wrapped prose that goes on"));

    private static (IntelligenceService Service, FakeHandler Handler, InMemoryApiKeyStore Keys, InMemoryIntelligenceSettings Settings) Make(bool enabled, string? key = "key")
    {
        var handler = new FakeHandler();
        var keys = new InMemoryApiKeyStore(key);
        var settings = new InMemoryIntelligenceSettings();
        var service = new IntelligenceService(settings, keys, handler.Client()) { IsEnabled = enabled };
        return (service, handler, keys, settings);
    }

    [Fact]
    public void IsOffOnAFreshInstall()
    {
        var service = new IntelligenceService(new InMemoryIntelligenceSettings(), new InMemoryApiKeyStore("key"), new FakeHandler().Client());
        Assert.False(service.IsEnabled);
        Assert.False(service.IsReady);
        Assert.Equal("Off. Clio makes no network requests.", service.StatusDescription);
        Assert.True(service.FormatsPastes);
    }

    [Fact]
    public async Task NoRequestIsMadeWhileTheFeatureIsOff()
    {
        var (service, handler, _, _) = Make(enabled: false);
        handler.Enqueue(200, Samples.ExportResponse);

        var match = await service.ResolveCommandAsync("save this as word", Samples.Context);
        var recovered = await service.RecoverStructureAsync(Paste);

        Assert.Null(match);
        Assert.Null(recovered);
        Assert.Empty(handler.Requests);
        var e = await Assert.ThrowsAsync<TypeSafeException>(() => service.EvaluateAsync(Samples.Sample()));
        Assert.Equal(TypeSafeErrorKind.Disabled, e.Kind);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task NoRequestIsMadeWithoutAKey()
    {
        var (service, handler, _, _) = Make(enabled: true, key: null);
        Assert.False(service.IsReady);
        var e = await Assert.ThrowsAsync<TypeSafeException>(() => service.EvaluateAsync(Samples.Sample()));
        Assert.Equal(TypeSafeErrorKind.MissingApiKey, e.Kind);
        Assert.Empty(handler.Requests);
        Assert.Null(await service.ResolveCommandAsync("make a new document", Samples.Context));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task ResolvesACommandOnceEnabled()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(200, Samples.ExportResponse);

        var match = await service.ResolveCommandAsync("send this to my editor in Word", Samples.Context);
        Assert.Equal(CommandId.Export, match?.Invocation.Command);
        Assert.Equal(["docx"], match?.Invocation.Arguments);
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task OnlyWindowStateAndTheTypedRequestAreSent()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(200, Samples.ExportResponse);
        await service.ResolveCommandAsync("  send this to my editor in Word  ", new CommandIntentContext(true, false, true, false, true));

        var body = System.Text.Json.Nodes.JsonNode.Parse(handler.Bodies[0])!;
        Assert.Equal("send this to my editor in Word", body["state"]!["request"]!.GetValue<string>());
        Assert.Equal(["request", "editor"], body["state"]!.AsObject().Select(p => p.Key).Order(StringComparer.Ordinal).Reverse());
        Assert.Equal(5, body["state"]!["editor"]!.AsObject().Count);
    }

    [Fact]
    public async Task ShortRequestsAreNeverSent()
    {
        var (service, handler, _, _) = Make(enabled: true);
        Assert.Null(await service.ResolveCommandAsync(" ab ", Samples.Context));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task AFailedResolutionFallsBackSilently()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(401);
        var match = await service.ResolveCommandAsync("make a new document", Samples.Context);
        Assert.Null(match);
        Assert.Equal(new TypeSafeException(TypeSafeErrorKind.Unauthorized).Message, service.LastError);
    }

    [Fact]
    public async Task ACancelledResolutionReturnsNothing()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(200, Samples.ExportResponse);
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        Assert.Null(await service.ResolveCommandAsync("send this to Word", Samples.Context, cts.Token));
    }

    [Fact]
    public async Task PasteFormattingCanBeTurnedOffIndependently()
    {
        var (service, handler, _, _) = Make(enabled: true);
        service.FormatsPastes = false;
        handler.Enqueue(200, Samples.ExportResponse);
        Assert.Null(await service.RecoverStructureAsync(Paste));
        Assert.Empty(handler.Requests);
        // Assisted commands are unaffected by the paste switch.
        Assert.Equal(CommandId.Export, (await service.ResolveCommandAsync("send this to Word", Samples.Context))?.Invocation.Command);
    }

    [Fact]
    public async Task PastesThatAlreadyCarryMarkupNeverReachTheNetwork()
    {
        var (service, handler, _, _) = Make(enabled: true);
        var markdown = string.Join("\n", Enumerable.Range(0, 30).Select(i => $"- bullet number {i} with enough words to pass the length gate"));
        Assert.Null(await service.RecoverStructureAsync(markdown));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task StructureIsRecoveredInTwoSequentialRequests()
    {
        var (service, handler, _, _) = Make(enabled: true);
        var memo = Spec.Load("intelligence-structure-recovery.json").GetProperty("memo").GetString()!;
        handler.Enqueue(200, """
            {"model":"m","answers":{"L002":{"type":"noul","noul":0.9},"L003":{"type":"noul","noul":0.9},"L004":{"type":"noul","noul":0.9}},"usage":{"input_tokens":1,"output_tokens":1}}
            """);
        handler.Enqueue(200, """
            {"model":"m","answers":{
              "type_B000":{"type":"choice","choice":"heading","probabilities":{"heading":1.0},"confidence":0.9},
              "hlevel_B000":{"type":"choice","choice":"title","probabilities":{"title":1.0},"confidence":0.9}
            },"usage":{"input_tokens":1,"output_tokens":1}}
            """);

        var markdown = await service.RecoverStructureAsync(memo);

        Assert.NotNull(markdown);
        Assert.StartsWith("# Migration to the new build system\n\nHi everyone, quick heads up", markdown);
        Assert.Contains("make the switch for real.", markdown);
        Assert.Equal(2, handler.Requests.Count);
        Assert.Contains("L000|", handler.Bodies[0]);
        Assert.Contains("B000|", handler.Bodies[1]);
    }

    [Fact]
    public async Task AFailedPassLeavesThePasteAlone()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(401);
        Assert.Null(await service.RecoverStructureAsync(Paste));
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task KeyCheckConfirmsAWorkingKey()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(200, Samples.ExportResponse);
        await service.VerifyKeyAsync();
        Assert.Equal(IntelligenceService.KeyVerificationState.Valid, service.KeyVerification);
        Assert.Equal("Key checked and working.", service.StatusDescription);
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task KeyCheckReportsARejectedKey()
    {
        var (service, handler, _, _) = Make(enabled: true);
        handler.Enqueue(401);
        await service.VerifyKeyAsync();
        Assert.Equal(IntelligenceService.KeyVerificationState.Invalid, service.KeyVerification);
        Assert.Equal(new TypeSafeException(TypeSafeErrorKind.Unauthorized).Message, service.StatusDescription);
    }

    [Fact]
    public async Task KeyCheckStaysBehindTheOptIn()
    {
        var (service, handler, _, _) = Make(enabled: false);
        handler.Enqueue(200, Samples.ExportResponse);
        await service.VerifyKeyAsync();
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task StoringANewKeyDiscardsTheOldResult()
    {
        var (service, handler, keys, _) = Make(enabled: true);
        handler.Enqueue(200, Samples.ExportResponse);
        await service.VerifyKeyAsync();
        Assert.Equal(IntelligenceService.KeyVerificationState.Valid, service.KeyVerification);

        service.SetApiKey("  a-different-key \n");
        Assert.Equal("a-different-key", keys.Load());
        Assert.True(service.HasApiKey);
        Assert.Equal(IntelligenceService.KeyVerificationState.Unchecked, service.KeyVerification);
    }

    [Fact]
    public void RemovingTheKeyClearsItFromTheStoreAndTheUi()
    {
        var (service, _, keys, _) = Make(enabled: true);
        Assert.True(service.IsReady);
        service.ClearApiKey();
        Assert.Null(keys.Load());
        Assert.False(service.HasApiKey);
        Assert.False(service.IsReady);
        Assert.Equal("No key stored. Add your own TypeSafe API key to finish setting this up.", service.StatusDescription);
    }

    [Fact]
    public void AnEmptyKeyRemovesTheStoredOne()
    {
        var (service, _, keys, _) = Make(enabled: true);
        service.SetApiKey("   ");
        Assert.Null(keys.Load());
    }

    [Fact]
    public void AFailedStoreIsReported()
    {
        var settings = new InMemoryIntelligenceSettings { Enabled = true };
        var service = new IntelligenceService(settings, new RefusingStore(), new FakeHandler().Client());
        service.SetApiKey("key");
        Assert.False(service.HasApiKey);
        Assert.Contains("Credential Manager", service.StatusDescription + service.LastError);
    }

    private sealed class RefusingStore : IApiKeyStore
    {
        public string? Load() => null;
        public bool Store(string? key) => false;
    }

    [Fact]
    public void EachKeyStoreIsIndependent()
    {
        Assert.True(Make(enabled: true, key: "mine").Service.IsReady);
        Assert.False(Make(enabled: true, key: null).Service.IsReady);
    }

    [Fact]
    public void SettingsAreRememberedByTheStoreTheyLiveIn()
    {
        var (service, _, keys, settings) = Make(enabled: true);
        service.FormatsPastes = false;
        var reloaded = new IntelligenceService(settings, keys, new FakeHandler().Client());
        Assert.True(reloaded.IsEnabled);
        Assert.False(reloaded.FormatsPastes);
    }

    [Fact]
    public void ChangesAreAnnounced()
    {
        var (service, _, _, _) = Make(enabled: false);
        var count = 0;
        service.Changed += () => count++;
        service.IsEnabled = true;
        service.FormatsPastes = false;
        service.SetApiKey("x");
        service.ClearApiKey();
        Assert.True(count >= 4);
    }
}

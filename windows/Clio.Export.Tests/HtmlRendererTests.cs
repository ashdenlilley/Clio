using Xunit;

namespace Clio.Export.Tests;

public class HtmlRendererTests
{
    private static string Html(string markdown, string title = "Doc") =>
        HtmlRenderer.Render(MarkdownModelBuilder.Build(markdown), title, "en");

    private static TextInline T(string value) => new(value);

    [Fact]
    public void ExportIsSemanticSelfContainedAndEscapesHostileInput()
    {
        var model = new MarkdownDocument([
            new HeadingBlock(1, [T("Notes & ideas")]),
            new ParagraphBlock([
                new StrongInline([T("Readable")]),
                T(" and "),
                new LinkInline("javascript:alert(1)", null, [T("safe")]),
                new ImageInline("data:image/svg+xml,<svg onload='alert(1)'>", null, [T("diagram")]),
            ]),
            new RawHtmlBlock("<script>alert('x')</script>"),
        ]);

        var html = HtmlRenderer.Render(model, "Notes.md", "en");

        Assert.Contains("<!doctype html>", html);
        Assert.Contains("<h1>Notes &amp; ideas</h1>", html);
        Assert.Contains("<strong>Readable</strong>", html);
        Assert.DoesNotContain("href=\"javascript:", html);
        Assert.DoesNotContain("data:image/svg+xml", html);
        Assert.DoesNotContain("<script>", html);
        Assert.Contains("&lt;script&gt;", html);
        Assert.Contains("Content-Security-Policy", html);
        Assert.Contains("@media print", html);
        Assert.DoesNotContain("<link ", html);
        Assert.DoesNotContain("<script src=", html);
    }

    [Fact]
    public void RendererSanitizesControlsScopesTablesAndUsesSafeFootnoteIds()
    {
        var hostileLabel = "bad\" onclick=\"alert(1) ❤️";
        var text = "before\u0000after\u0085done";
        var footnoteBody = new MarkdownBlock[] { new ParagraphBlock([T("Footnote body")]) };
        TableCell Cell(string value) => new([T(value)]);
        var model = new MarkdownDocument([
            new ParagraphBlock([
                T(text),
                new LinkInline("java\u0000script:alert(1)", "\" onmouseover=\"alert(1)", [T("unsafe link")]),
                new LinkInline(" \tjavascript:alert(2)", null, [T("padded link")]),
                new ImageInline("data:image/png;text/html;base64,PHNjcmlwdD4=", null, [T("fallback")]),
                new FootnoteReferenceInline(hostileLabel),
            ]),
            new TableBlock(new MarkdownTable(
                [TableAlignment.Leading, TableAlignment.Trailing],
                [Cell("Name"), Cell("Value")],
                [[Cell("one"), Cell("two")]])),
            new FootnoteDefinitionBlock(hostileLabel, footnoteBody),
            new FootnoteDefinitionBlock(hostileLabel, footnoteBody),
        ]);

        var html = HtmlRenderer.Render(model, "Hostile\u0000title", "en");
        var safeId = ExportContentPolicy.SafeFootnoteId(hostileLabel);

        Assert.Contains("default-src 'none'", html);
        Assert.Contains("base-uri 'none'", html);
        Assert.Contains("<th scope=\"col\">Name</th>", html);
        Assert.Contains("<td class=\"align-trailing\">two</td>", html);
        Assert.Contains($"href=\"#{safeId}\"", html);
        Assert.Contains($"id=\"{safeId}\"", html);
        Assert.Contains($"id=\"{safeId}-2\"", html);
        Assert.DoesNotContain($"id=\"fn-{hostileLabel}", html);
        Assert.DoesNotContain("java\u0000script", html);
        Assert.DoesNotContain("javascript:alert(2)", html);
        Assert.DoesNotContain("data:image/png;text/html", html);
        Assert.DoesNotContain(html, ch => ch == '\0' || ch == '\u0085');
        Assert.Contains("before�after�done", html);
        Assert.Contains("<span role=\"img\" aria-label=\"fallback\">fallback</span>", html);
        Assert.DoesNotContain("onmouseover=\"alert", html.Replace("&quot; onmouseover=&quot;alert", ""));
    }

    [Fact]
    public void MarkdownRoundTripKeepsStructure()
    {
        var html = Html("""
            # Stream & verify

            > Quoted **body**

            - [x] finished
            - [ ] pending

            3. three
            4. four

            | Name | Value |
            | --- | ---: |
            | café | <safe> |

            [link](https://example.com?a=1&b=2) and ~~gone~~ and `code`

            ```csharp
            var x = "<tag>";
            ```

            Footnote[^1]

            [^1]: The note.
            """);

        Assert.Contains("<h1>Stream &amp; verify</h1>", html);
        Assert.Contains("<blockquote>", html);
        Assert.Contains("<strong>body</strong>", html);
        Assert.Contains("<li class=\"task\"><span class=\"task-marker\" aria-label=\"Completed\">☑</span>", html);
        Assert.Contains("aria-label=\"Not completed\">☐", html);
        Assert.Contains("<ol start=\"3\">", html);
        Assert.Contains("<th scope=\"col\" class=\"align-trailing\">Value</th>", html);
        Assert.Contains("<td>café</td>", html);
        Assert.Contains("&lt;safe&gt;", html);
        Assert.Contains("<a href=\"https://example.com?a=1&amp;b=2\">link</a>", html);
        Assert.Contains("<del>gone</del>", html);
        Assert.Contains("<code>code</code>", html);
        Assert.Contains("<pre><code class=\"language-csharp\">var x = &quot;&lt;tag&gt;&quot;;\n</code></pre>", html);
        Assert.Contains($"href=\"#{ExportContentPolicy.SafeFootnoteId("1")}\"", html);
        Assert.Contains($"id=\"{ExportContentPolicy.SafeFootnoteId("1")}\"", html);
        Assert.Contains("The note.", html);
    }

    [Fact]
    public void FrontMatterAndRawHtmlAreShownAsText()
    {
        var html = Html("---\ntitle: <b>Hi</b>\n---\n\n<div onclick=\"x()\">raw</div>\n");

        Assert.Contains("<aside class=\"frontmatter\"", html);
        Assert.Contains("title: &lt;b&gt;Hi&lt;/b&gt;", html);
        Assert.Contains("<pre class=\"raw-html\"", html);
        Assert.DoesNotContain("<div onclick", html);
    }

    [Fact]
    public void TitleAndLanguageAreEscaped()
    {
        var html = HtmlRenderer.Render(new MarkdownDocument([]), "</title><script>x</script>", "e\"n");

        Assert.Contains("<title>&lt;/title&gt;&lt;script&gt;x&lt;/script&gt;</title>", html);
        Assert.Contains("<html lang=\"e&quot;n\">", html);
    }

    [Fact]
    public void RenderingHonoursCancellation()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var model = new MarkdownDocument([new ParagraphBlock([T("x")])]);

        Assert.Throws<OperationCanceledException>(() => HtmlRenderer.Render(model, "t", "en", cts.Token));
    }
}

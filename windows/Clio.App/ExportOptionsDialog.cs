using Clio.Export;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Clio.App;

/// <summary>
/// The export options sheet (macOS <c>ExportOptionsView</c>): format, and for PDF the page setup. WinUI cannot stack a
/// second dialog on a ContentDialog and has no system page-layout panel, so the page setup is inline here, drawn from
/// <see cref="PageSetupChoices"/>. Nothing is saved unless the writer confirms.
/// </summary>
public static class ExportOptionsDialog
{
    private sealed record Item<T>(string Label, T Value, bool Custom = false)
    {
        public override string ToString() => Label;
    }

    private static readonly ExportFormat[] Formats = [ExportFormat.Pdf, ExportFormat.Html, ExportFormat.Docx, ExportFormat.Txt];

    /// <summary>Shows the sheet. Returns the chosen format, or null when cancelled. A confirmed PDF page setup is saved to <paramref name="store"/>.</summary>
    public static async Task<ExportFormat?> ShowAsync(Dialogs dialogs, ExportFormat initial, PdfPrintSettingsStore store)
    {
        var working = store.Current;
        var format = initial;

        var formatChoice = new RadioButtons { Header = "Format", MaxColumns = 4 };
        foreach (var f in Formats) formatChoice.Items.Add(new RadioButton { Content = ExportCommandRoute.DisplayName(f), Tag = f });
        formatChoice.SelectedIndex = Array.IndexOf(Formats, initial);
        AutomationProperties.SetAutomationId(formatChoice, "export.format");

        var description = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75 };
        var note = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75,
            Text = "Remote content is never loaded while exporting. Your source Markdown is unchanged.",
        };

        var summary = new TextBlock { FontSize = 12, Opacity = 0.75 };
        var paper = new ComboBox { Header = "Paper", MinWidth = 150 };
        var orientation = new ComboBox { Header = "Orientation", MinWidth = 150 };
        var margins = new ComboBox { Header = "Margins", MinWidth = 150 };
        AutomationProperties.SetAutomationId(paper, "export.paper");
        AutomationProperties.SetAutomationId(orientation, "export.orientation");
        AutomationProperties.SetAutomationId(margins, "export.margins");
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed), Visibility = Visibility.Collapsed };
        var reset = new HyperlinkButton { Content = "Use the regional default", Padding = new Thickness(0) };

        var pageSetup = new StackPanel { Spacing = 8 };
        pageSetup.Children.Add(new TextBlock { Text = "Page setup", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        pageSetup.Children.Add(summary);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(paper);
        row.Children.Add(orientation);
        row.Children.Add(margins);
        pageSetup.Children.Add(row);
        pageSetup.Children.Add(reset);
        pageSetup.Children.Add(error);

        var syncing = false;

        void FillPageSetup()
        {
            syncing = true;
            try
            {
                paper.Items.Clear();
                var currentPaper = PageSetupChoices.PaperFor(working);
                if (currentPaper is null) paper.Items.Add(new Item<PaperSize?>($"Custom ({working.PaperName ?? "current"})", null, Custom: true));
                foreach (var p in PageSetupChoices.Papers) paper.Items.Add(new Item<PaperSize?>(p.Name, p));
                paper.SelectedIndex = currentPaper is null ? 0 : PageSetupChoices.Papers.ToList().FindIndex(p => p == currentPaper) + (paper.Items.Count - PageSetupChoices.Papers.Count);

                orientation.Items.Clear();
                orientation.Items.Add(new Item<PaperOrientation>("Portrait", PaperOrientation.Portrait));
                orientation.Items.Add(new Item<PaperOrientation>("Landscape", PaperOrientation.Landscape));
                orientation.SelectedIndex = working.Orientation == PaperOrientation.Portrait ? 0 : 1;

                margins.Items.Clear();
                var currentMargin = PageSetupChoices.MarginFor(working);
                if (currentMargin is null) margins.Items.Add(new Item<MarginPreset?>("Custom", null, Custom: true));
                foreach (var m in PageSetupChoices.Margins) margins.Items.Add(new Item<MarginPreset?>(m.Name, m));
                margins.SelectedIndex = currentMargin is null ? 0 : PageSetupChoices.Margins.ToList().FindIndex(m => m == currentMargin) + (margins.Items.Count - PageSetupChoices.Margins.Count);

                summary.Text = PageSetupChoices.Summary(working);
            }
            finally { syncing = false; }
        }

        var dialog = new ContentDialog
        {
            Title = "Export document",
            PrimaryButtonText = "Choose destination…",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };

        void Validate()
        {
            try
            {
                PdfPrintGeometry.Resolve(working, PdfPrintSettings.RegionalDefault());
                error.Visibility = Visibility.Collapsed;
                dialog.IsPrimaryButtonEnabled = true;
            }
            catch (InvalidPrintSettingsException e)
            {
                error.Text = e.Message;
                error.Visibility = Visibility.Visible;
                dialog.IsPrimaryButtonEnabled = false;
            }
        }

        void ShowFormat()
        {
            description.Text = ExportCommandRoute.Description(format);
            pageSetup.Visibility = format == ExportFormat.Pdf ? Visibility.Visible : Visibility.Collapsed;
            note.Visibility = format == ExportFormat.Pdf ? Visibility.Collapsed : Visibility.Visible;
            if (format == ExportFormat.Pdf) Validate(); else dialog.IsPrimaryButtonEnabled = true;
        }

        formatChoice.SelectionChanged += (_, _) =>
        {
            if (formatChoice.SelectedItem is RadioButton { Tag: ExportFormat f }) { format = f; ShowFormat(); }
        };
        paper.SelectionChanged += (_, _) =>
        {
            if (syncing || paper.SelectedItem is not Item<PaperSize?> { Custom: false, Value: { } p }) return;
            working = PageSetupChoices.With(working, paper: p);
            FillPageSetup(); Validate();
        };
        orientation.SelectionChanged += (_, _) =>
        {
            if (syncing || orientation.SelectedItem is not Item<PaperOrientation> o) return;
            working = PageSetupChoices.With(working, orientation: o.Value);
            FillPageSetup(); Validate();
        };
        margins.SelectionChanged += (_, _) =>
        {
            if (syncing || margins.SelectedItem is not Item<MarginPreset?> { Custom: false, Value: { } m }) return;
            working = PageSetupChoices.With(working, margin: m);
            FillPageSetup(); Validate();
        };
        reset.Click += (_, _) => { working = PdfPrintSettings.RegionalDefault(); FillPageSetup(); Validate(); };

        var content = new StackPanel { Spacing = 16, MinWidth = 440 };
        content.Children.Add(formatChoice);
        content.Children.Add(pageSetup);
        content.Children.Add(note);
        content.Children.Add(description);
        dialog.Content = content;

        FillPageSetup();
        ShowFormat();

        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary) return null;
        if (format == ExportFormat.Pdf)
        {
            try { store.Update(working); }
            catch (InvalidPrintSettingsException) { /* Validate() already disabled confirmation for these. */ }
        }
        return format;
    }
}

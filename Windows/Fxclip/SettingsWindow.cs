using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Fxclip.Engine;

namespace Fxclip;

internal sealed class SettingsWindow : Window
{
    private readonly SettingsStore store;
    private readonly ClipboardService clipboard;
    private readonly StackPanel page = new();
    private readonly Dictionary<string, Button> navigation = [];
    private string selected = "Overview";
    public SettingsWindow(SettingsStore store, ClipboardService clipboard)
    {
        this.store = store;
        this.clipboard = clipboard;
        Title = "fxclip";
        Width = 950; Height = 700; MinWidth = 800; MinHeight = 560;
        Ui.Setup(this);
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = new DockPanel { LastChildFill = true };
        sidebar.SetResourceReference(BackgroundProperty, "Sidebar");
        var logo = Ui.Text("fxclip", 24, true);
        logo.Margin = new Thickness(24, 24, 20, 26);
        DockPanel.SetDock(logo, Dock.Top);
        sidebar.Children.Add(logo);
        var settings = Nav("Settings", "⚙", "#777E8C");
        settings.Margin = new Thickness(12, 10, 12, 20);
        DockPanel.SetDock(settings, Dock.Bottom);
        sidebar.Children.Add(settings);
        var links = new StackPanel();
        links.Children.Add(Nav("Overview", "◉", "#E98A28"));
        links.Children.Add(Nav("Preview links", "↗", "#1684EF"));
        links.Children.Add(Nav("Trackers", "⊘", "#EF5464"));
        links.Children.Add(Nav("Never clean", "✋", "#7B72EE"));
        sidebar.Children.Add(links);
        root.Children.Add(sidebar);
        var scroll = new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(30, 25, 30, 24), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(scroll, 1);
        root.Children.Add(scroll);
        Content = root;
        clipboard.Changed += ClipboardChanged;
        Closed += (_, _) => clipboard.Changed -= ClipboardChanged;
        Refresh();
    }
    private void ClipboardChanged() { if (selected == "Overview") Refresh(); }
    private Button Nav(string name, string glyph, string color)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        var tile = new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(5), Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)), Margin = new Thickness(0, 0, 10, 0) };
        var icon = Ui.Text(glyph, 15, true); icon.Foreground = Brushes.White; icon.HorizontalAlignment = HorizontalAlignment.Center;
        tile.Child = icon;
        label.Children.Add(tile); label.Children.Add(Ui.Text(name, 14, true));
        var button = Ui.Button(name, () => { selected = name; Refresh(); });
        button.Content = label;
        button.HorizontalContentAlignment = HorizontalAlignment.Left;
        button.Margin = new Thickness(12, 3, 12, 3);
        button.Padding = new Thickness(10, 7, 10, 7);
        button.MinHeight = 40;
        navigation[name] = button;
        return button;
    }
    public void Refresh()
    {
        foreach (var (name, button) in navigation)
            if (selected == name) button.Background = new SolidColorBrush(Color.FromArgb(65, 40, 133, 236));
            else button.SetResourceReference(BackgroundProperty, "Sidebar");
        page.Children.Clear();
        switch (selected)
        {
            case "Overview": Overview(); break;
            case "Preview links": Previews(); break;
            case "Trackers": Trackers(); break;
            case "Never clean": NeverClean(); break;
            case "Settings": Settings(); break;
        }
    }
    private void Header(string title, string info)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 26) };
        row.Children.Add(Ui.Text(title, 30, true));
        var tip = Ui.Button("ⓘ", () => MessageBox.Show(this, info, title));
        tip.ToolTip = new TextBlock { Text = info, TextWrapping = TextWrapping.Wrap, MaxWidth = 280 };
        tip.Margin = new Thickness(10, 0, 0, 0); tip.Padding = new Thickness(5, 0, 5, 0);
        row.Children.Add(tip);
        page.Children.Add(row);
    }
    private void Section(string name)
    {
        var label = Ui.Text(name, 13, true, true);
        label.Margin = new Thickness(4, 18, 0, 10);
        page.Children.Add(label);
    }
    private void Overview()
    {
        Header("Overview", "fxclip watches what you copy. Trackers are removed from every link, and in the apps you choose, X and Instagram links become preview-friendly mirrors. Nothing leaves your PC.");
        var status = new StackPanel();
        status.Children.Add(Ui.Text(clipboard.Status, 15, true));
        if (clipboard.SkipNext) status.Children.Add(Ui.Text("The next copy will be left as is", 12, secondary: true));
        page.Children.Add(Ui.Card(Ui.Row(status,
            Ui.Button(clipboard.SkipNext ? "Don't skip" : "Skip next copy", clipboard.ToggleSkip),
            Ui.Button(clipboard.Paused ? "Resume" : "Pause", clipboard.TogglePause))));
        var stats = new Grid();
        stats.ColumnDefinitions.Add(new ColumnDefinition()); stats.ColumnDefinitions.Add(new ColumnDefinition());
        Border Stat(string value, string label)
        {
            var panel = new StackPanel(); panel.Children.Add(Ui.Text(value, 28, true)); panel.Children.Add(Ui.Text(label, 12, secondary: true)); return Ui.Card(panel);
        }
        var total = Stat($"{store.Preferences.TrackersRemoved:N0}", "trackers removed"); total.Margin = new Thickness(0, 0, 6, 0); stats.Children.Add(total);
        var last = Stat(clipboard.LastClean?.ToShortTimeString() ?? "—", clipboard.LastClean is null ? "no link cleaned since fxclip started" : "last link cleaned"); last.Margin = new Thickness(6, 0, 0, 0); Grid.SetColumn(last, 1); stats.Children.Add(last);
        page.Children.Add(stats);
        Section("Preview links in use");
        var active = store.Effective.Previews.Where(p => p.Apps.Length > 0).ToArray();
        if (active.Length == 0) page.Children.Add(Ui.Card(Ui.Text("No preview links on.", secondary: true)));
        foreach (var p in active)
        {
            var content = new StackPanel(); content.Children.Add(Ui.Text(p.Name + " → " + p.To, 15, true)); content.Children.Add(Chips(p.Apps)); page.Children.Add(Ui.Card(content));
        }
    }
    private WrapPanel Chips(IEnumerable<string> ids)
    {
        var panel = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var id in ids)
        {
            var app = store.KnownApps.FirstOrDefault(a => a.Id == id);
            if (app is null) continue;
            var chip = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 6, 4), Child = Ui.Text(app.Name, 12) };
            chip.SetResourceReference(Border.BorderBrushProperty, "Line");
            panel.Children.Add(chip);
        }
        return panel;
    }
    private void Previews()
    {
        Header("Preview links", "In the apps you pick, links are swapped for a mirror that shows the full post in the chat preview. Switch to any other app and the clean link is put back. Mirrors are run by third parties: they see a link only when someone opens it.");
        foreach (var p in store.Builtins.Previews)
        {
            var setting = store.Setting(p);
            var panel = new StackPanel();
            var label = new StackPanel(); label.Children.Add(Ui.Text(p.Name, 17, true));
            label.Children.Add(Ui.Text(string.Join(", ", p.From.Where(h => !h.StartsWith("www.") && !h.StartsWith("mobile."))) + " → " + p.To, 13, secondary: true));
            panel.Children.Add(Ui.Row(label, Ui.Toggle("Enable " + p.Name + " preview links", setting.Enabled, on => { store.User.Previews[p.Id] = store.Setting(p) with { Enabled = on }; store.Save(); })));
            var apps = Chips(setting.Apps);
            apps.Children.Add(Ui.Button(setting.Apps.Length == 0 ? "Choose apps…" : "＋ Change apps", () => new ChooseAppsWindow(store, p) { Owner = this }.ShowDialog()));
            panel.Children.Add(apps);
            page.Children.Add(Ui.Card(panel));
        }
    }
    private void Trackers()
    {
        Header("Trackers", "What fxclip removes from the links you copy. Useful parts of a link (a YouTube timestamp, an Amazon size or colour, a search) are always kept.");
        var rules = store.Builtins.Trackers;
        void Tracker(string name, int count, string detail, bool on, Action<bool> change)
        {
            var countLabel = Ui.Text($"{count} trackers", 12, secondary: true); countLabel.Margin = new Thickness(12, 0, 8, 0); countLabel.ToolTip = detail;
            var row = Ui.Row(Ui.Text(name, bold: name == "All websites"), countLabel, Ui.Toggle("Clean " + name, on, change));
            row.ToolTip = new TextBlock { Text = detail, MaxWidth = 280, TextWrapping = TextWrapping.Wrap };
            var card = Ui.Card(row); card.Margin = new Thickness(0, 0, 0, 6); card.Padding = new Thickness(14, 5, 10, 5); page.Children.Add(card);
        }
        Tracker("All websites", rules.Everywhere.Params.Length + rules.Everywhere.Prefixes.Length,
            string.Join(", ", rules.Everywhere.Prefixes.Select(p => p + "*").Concat(rules.Everywhere.Params)), store.User.TrackersEverywhere,
            on => { store.User.TrackersEverywhere = on; store.Save(); });
        foreach (var site in rules.Sites)
            Tracker(site.Name, site.Params.Length + (site.StripRefPath == true ? 1 : 0), string.Join(", ", site.Params) + (site.StripRefPath == true ? ", /ref=… at the end of the address" : ""),
                !store.User.DisabledSites.Contains(site.Id), on => { if (on) store.User.DisabledSites.Remove(site.Id); else store.User.DisabledSites.Add(site.Id); store.Save(); });
    }
    private void NeverClean()
    {
        Header("Never clean", "Links from these websites are left exactly as you copied them. Preview links are set separately.");
        foreach (var skip in store.User.NeverClean.ToArray())
        {
            var label = new StackPanel(); label.Children.Add(Ui.Text(skip.Host, 14, true));
            if (skip.Subdomains) label.Children.Add(Ui.Text("and its subdomains", 12, secondary: true));
            page.Children.Add(Ui.Card(Ui.Row(label, Ui.Button("Remove", () => { store.User.NeverClean.Remove(skip); store.Save(); }))));
        }
        var panel = new StackPanel();
        var input = new TextBox { ToolTip = "Add a website, e.g. example.com", MinWidth = 220 };
        System.Windows.Automation.AutomationProperties.SetName(input, "Website hostname or URL");
        panel.Children.Add(Ui.Text("Add a website", 14, true)); input.Margin = new Thickness(0, 10, 0, 4); panel.Children.Add(input);
        var subdomains = new CheckBox { Content = "Include subdomains", IsChecked = true };
        void Add()
        {
            var value = input.Text.Trim();
            var host = Fxclip.Engine.Engine.Host(value.Contains("://") ? value : "https://" + value);
            if (host is null || !host.Contains('.') || host.Contains('@') || host.Any(char.IsWhiteSpace))
            {
                MessageBox.Show(this, "Enter a website such as example.com, or paste a full link.", "Add a website"); return;
            }
            var skip = new SkipHost(SkipHost.Canonical(host), subdomains.IsChecked == true);
            if (!store.User.NeverClean.Contains(skip)) store.User.NeverClean.Add(skip);
            store.Save();
        }
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) Add(); };
        panel.Children.Add(Ui.Row(subdomains, Ui.Button("Add", Add)));
        page.Children.Add(Ui.Card(panel));
    }
    private void Settings()
    {
        Header("Settings", "Where fxclip shows up, and what it keeps.");
        Section("Where fxclip shows up");
        var presence = new StackPanel();
        presence.Children.Add(Ui.Row(Ui.Text("Show tray icon"), Ui.Toggle("Show tray icon", store.Preferences.ShowTrayIcon, on => { store.Preferences.ShowTrayIcon = on; store.SavePreferences(); })));
        presence.Children.Add(Ui.Row(Ui.Text("Open at login"), Ui.Toggle("Open at login", SettingsStore.OpenAtLogin, on => { SettingsStore.SetLogin(on); Refresh(); })));
        page.Children.Add(Ui.Card(presence));
        if (!store.Preferences.ShowTrayIcon) page.Children.Add(Ui.Text("Open fxclip again from Start or File Explorer to come back here.", 12, secondary: true));
        Section("Privacy");
        var privacy = new StackPanel();
        privacy.Children.Add(Ui.Text("Links are cleaned on this PC. Nothing is stored or sent, apart from a count of trackers removed. No network, no account, no analytics.", secondary: true));
        privacy.Children.Add(Ui.Row(Ui.Text($"{store.Preferences.TrackersRemoved:N0} trackers removed"), Ui.Button("Reset counter", () => { store.Preferences.TrackersRemoved = 0; store.SavePreferences(); })));
        page.Children.Add(Ui.Card(privacy));
        Section("About");
        page.Children.Add(Ui.Card(Ui.Row(Ui.Text("Version"), Ui.Text(Program.Version, secondary: true))));
    }
}

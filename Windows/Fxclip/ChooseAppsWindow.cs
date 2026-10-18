using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Fxclip.Engine;
using Microsoft.Win32;

namespace Fxclip;

internal sealed class ChooseAppsWindow : Window
{
    private readonly SettingsStore store;
    private readonly PreviewRule preview;
    private readonly List<AppRule> candidates;
    private readonly HashSet<string> selected;
    private readonly StackPanel list = new();
    public ChooseAppsWindow(SettingsStore store, PreviewRule preview)
    {
        this.store = store; this.preview = preview;
        candidates = store.KnownApps.Concat(AppDiscovery.Suggestions.Where(AppDiscovery.Installed)).DistinctBy(a => a.Id).ToList();
        selected = store.Setting(preview).Apps.ToHashSet();
        Title = "Choose apps"; Width = 460; Height = 480; ResizeMode = ResizeMode.CanResize;
        Ui.Setup(this); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new DockPanel { Margin = new Thickness(24), LastChildFill = true };
        var title = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        title.Children.Add(Ui.Text(preview.Name + " → " + preview.To, 20, true));
        title.Children.Add(Ui.Text("Apply in these apps:", secondary: true));
        DockPanel.SetDock(title, Dock.Top); panel.Children.Add(title);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(Ui.Button("Cancel", () => Close()));
        var save = Ui.Button("Save", () =>
        {
            foreach (var app in candidates.Where(a => selected.Contains(a.Id))) store.AddApp(app);
            store.User.Previews[preview.Id] = store.Setting(preview) with { Apps = selected.Order(StringComparer.Ordinal).ToArray() };
            store.Save(); DialogResult = true;
        }); save.IsDefault = true; buttons.Children.Add(save);
        DockPanel.SetDock(buttons, Dock.Bottom); panel.Children.Add(buttons);
        var add = Ui.Button("Add another app…", Browse); add.HorizontalAlignment = HorizontalAlignment.Left;
        DockPanel.SetDock(add, Dock.Bottom); panel.Children.Add(add);
        panel.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = panel; Refresh();
    }
    private void Refresh()
    {
        list.Children.Clear();
        foreach (var app in candidates)
        {
            var check = Ui.Toggle(app.Name, selected.Contains(app.Id), on => { if (on) selected.Add(app.Id); else selected.Remove(app.Id); }, false);
            check.ToolTip = string.Join(", ", app.Windows ?? []);
            list.Children.Add(check);
        }
    }
    private void Browse()
    {
        var dialog = new OpenFileDialog { Title = "Choose an app", Filter = "Windows apps (*.exe)|*.exe", CheckFileExists = true };
        if (dialog.ShowDialog(this) != true) return;
        var exe = Path.GetFileName(dialog.FileName);
        var app = candidates.Concat(AppDiscovery.Suggestions).FirstOrDefault(a => (a.Windows ?? []).Contains(exe, StringComparer.OrdinalIgnoreCase))
            ?? new AppRule(exe.ToLowerInvariant(), Path.GetFileNameWithoutExtension(exe), [], Windows: [exe]);
        if (!candidates.Any(a => a.Id == app.Id)) candidates.Add(app);
        selected.Add(app.Id); Refresh();
    }
}

internal static class AppDiscovery
{
    public static readonly AppRule[] Suggestions = [
        new("discord", "Discord", [], Windows: ["Discord.exe"]),
        new("whatsapp", "WhatsApp", [], Windows: ["WhatsApp.exe"]),
        new("slack", "Slack", [], Windows: ["Slack.exe"]),
        new("signal", "Signal", [], Windows: ["Signal.exe"])
    ];
    public static bool Installed(AppRule app)
    {
        var exe = app.Windows![0];
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var key = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\" + exe);
            if (key?.GetValue("") is string path && File.Exists(path.Trim('"'))) return true;
        }
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe));
        var running = processes.Length > 0;
        foreach (var process in processes) process.Dispose();
        if (running) return true;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roots = new[] { Path.Combine(local, app.Name), Path.Combine(local, "Programs", app.Name), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), app.Name), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), app.Name) };
        foreach (var root in roots)
        {
            if (File.Exists(Path.Combine(root, exe))) return true;
            try { if (Directory.Exists(root) && Directory.GetDirectories(root, "app-*").Any(d => File.Exists(Path.Combine(d, exe)))) return true; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        // Store-distributed WhatsApp exposes its executable under a package directory.
        if (app.Id == "whatsapp")
        {
            var packages = Path.Combine(local, "Packages");
            try { if (Directory.Exists(packages) && Directory.GetDirectories(packages, "*WhatsApp*").Length > 0) return true; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return false;
    }
}

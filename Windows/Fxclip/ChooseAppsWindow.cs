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
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            label.Children.Add(AppIcons.View(app)); label.Children.Add(Ui.Text(app.Name)); check.Content = label;
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
        AppDiscovery.RememberPath(app, dialog.FileName);
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
    private static readonly Dictionary<string, string> chosenPaths = [];
    public static void RememberPath(AppRule app, string path) => chosenPaths[app.Id] = path;
    public static bool Installed(AppRule app) => ExecutablePath(app) is not null || StoreInstalled(app);
    public static string? ExecutablePath(AppRule app)
    {
        if (chosenPaths.TryGetValue(app.Id, out var chosen) && File.Exists(chosen)) return chosen;
        foreach (var exe in app.Windows ?? [])
        {
            var path = FindExecutable(app, exe);
            if (path is not null) return path;
        }
        return null;
    }
    private static string? FindExecutable(AppRule app, string exe)
    {
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            using var key = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\" + exe);
            if (key?.GetValue("") is string path && File.Exists(path.Trim('"'))) return path.Trim('"');
        }
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe));
        try
        {
            foreach (var process in processes)
            {
                try { if (process.MainModule?.FileName is string path && File.Exists(path)) return path; }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException) { }
            }
        }
        finally { foreach (var process in processes) process.Dispose(); }
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roots = new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), app.Name + " Desktop"), Path.Combine(local, app.Name), Path.Combine(local, "Programs", app.Name), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), app.Name), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), app.Name) };
        foreach (var root in roots)
        {
            if (File.Exists(Path.Combine(root, exe))) return Path.Combine(root, exe);
            try
            {
                if (Directory.Exists(root))
                    foreach (var directory in Directory.GetDirectories(root, "app-*"))
                        if (File.Exists(Path.Combine(directory, exe))) return Path.Combine(directory, exe);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return null;
    }
    private static bool StoreInstalled(AppRule app)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
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

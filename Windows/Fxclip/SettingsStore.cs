using System.Text.Json;
using Fxclip.Engine;
using Microsoft.Win32;

namespace Fxclip;

internal sealed class SettingsStore
{
    private readonly string directory = Path.Combine(Environment.GetEnvironmentVariable("APPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "fxclip");
    public Rules Builtins { get; } = Rules.BuiltIn();
    public UserSettings User { get; private set; } = new();
    public Preferences Preferences { get; private set; } = new();
    public bool FirstRun { get; private set; }
    public bool Recovered { get; private set; }
    public event Action? Changed;
    public Rules Effective => Builtins.Applying(User);
    public AppRule[] KnownApps => Builtins.Apps.Concat(User.AddedApps.Where(a => !Builtins.Apps.Any(b => b.Id == a.Id))).ToArray();

    public SettingsStore()
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "settings.json");
        FirstRun = !File.Exists(path);
        if (!FirstRun)
        {
            try { User = UserSettings.Parse(File.ReadAllText(path)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
            {
                File.Move(path, Path.Combine(directory, "settings.unreadable.json"), true);
                FirstRun = Recovered = true;
            }
        }
        try { Preferences = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(directory, "preferences.json")), UserSettings.Json) ?? new(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
    }
    private void AtomicWrite(string name, string json)
    {
        var path = Path.Combine(directory, name);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, json);
        File.Move(temporary, path, true);
    }
    public void Save()
    {
        AtomicWrite("settings.json", User.ToJson());
        FirstRun = false;
        Changed?.Invoke();
    }
    public void SavePreferences()
    {
        AtomicWrite("preferences.json", JsonSerializer.Serialize(Preferences, UserSettings.Json));
        Changed?.Invoke();
    }
    public void Record(int removed)
    {
        Preferences.TrackersRemoved += removed;
        AtomicWrite("preferences.json", JsonSerializer.Serialize(Preferences, UserSettings.Json));
    }
    public PreviewSetting Setting(PreviewRule rule) => User.Previews.GetValueOrDefault(rule.Id) ?? new(true, rule.Apps);
    public void AddApp(AppRule app) { if (!KnownApps.Any(a => a.Id == app.Id)) User.AddedApps.Add(app); }
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool OpenAtLogin
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(RunKey); return key?.GetValue("fxclip") as string == "\"" + Environment.ProcessPath + "\""; }
    }
    public static void SetLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue("fxclip", "\"" + Environment.ProcessPath + "\"");
        else key.DeleteValue("fxclip", false);
    }
}
internal sealed class Preferences
{
    public bool ShowTrayIcon { get; set; } = true;
    public long TrackersRemoved { get; set; }
}

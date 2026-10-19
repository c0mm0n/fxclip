using System.Windows;
using System.Windows.Threading;
using Velopack;
using Velopack.Sources;

namespace Fxclip;

internal sealed class AppUpdater
{
    private readonly SettingsStore store;
    private readonly UpdateManager manager;
    private readonly Dispatcher dispatcher = Application.Current.Dispatcher;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromHours(1) };
    private CancellationTokenSource? download;
    private UpdateInfo? available;
    public event Action? Changed;
    public string Status { get; private set; } = "Check GitHub for a newer version.";
    public string Notes => available?.TargetFullRelease.NotesMarkdown ?? "";
    public bool Busy { get; private set; }
    public bool Downloading => download is not null;
    public bool CanDownload => available is not null && !Busy && manager.UpdatePendingRestart is null;
    public bool Ready => manager.IsInstalled && manager.UpdatePendingRestart is not null;
    public AppUpdater(SettingsStore store) : this(store, new UpdateManager(new GithubSource("https://github.com/c0mm0n/fxclip", null, false))) { }
    internal AppUpdater(SettingsStore store, UpdateManager manager)
    {
        this.store = store;
        this.manager = manager;
        if (Ready) Status = "Update downloaded. Restart to install it when you are ready.";
        timer.Tick += async (_, _) => await CheckAutomatically();
    }
    public void Start() { timer.Start(); _ = CheckAutomatically(); }
    public void Stop() { timer.Stop(); download?.Cancel(); }
    private void Notify() => Changed?.Invoke();
    public void SetAutomatic(bool enabled)
    {
        store.Preferences.AutomaticUpdateChecks = enabled;
        store.SavePreferences();
        if (enabled) _ = CheckAutomatically();
    }
    private Task CheckAutomatically() => store.Preferences.AutomaticUpdateChecks && DateTimeOffset.UtcNow - store.Preferences.LastUpdateCheck >= TimeSpan.FromDays(1) ? Check() : Task.CompletedTask;
    public async Task Check()
    {
        if (Busy) return;
        if (!manager.IsInstalled) { Status = "Install the latest Windows download once to enable in-app updates."; Notify(); return; }
        Busy = true; Status = "Checking GitHub…"; Notify();
        try
        {
            store.Preferences.LastUpdateCheck = DateTimeOffset.UtcNow;
            store.SavePreferences();
            available = await manager.CheckForUpdatesAsync();
            // Stable releases only; never allow a downgrade or a prerelease package.
            if (available is not null && (available.IsDowngrade || available.TargetFullRelease.Version.IsPrerelease)) available = null;
            Status = Ready ? "Update downloaded. Restart to install it when you are ready." : available is null ? "You’re up to date." : $"Version {available.TargetFullRelease.Version} is available.";
        }
        catch (Exception) { Status = "Couldn’t check for updates. Check your connection and try again."; }
        finally { Busy = false; Notify(); }
    }
    public async Task Download()
    {
        if (!CanDownload) return;
        if (MessageBox.Show("Download this update from GitHub? Installation will wait for Restart to Update.", "fxclip update", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        Busy = true; download = new CancellationTokenSource(); Status = "Downloading…"; Notify();
        try
        {
            await manager.DownloadUpdatesAsync(available!, percent => dispatcher.BeginInvoke(() => { Status = $"Downloading… {percent}%"; Notify(); }), download.Token);
            Status = "Update verified and downloaded. Restart to install it when you are ready.";
        }
        catch (OperationCanceledException) { Status = "Download cancelled. Your installed version is unchanged."; }
        catch (Exception) { Status = "Couldn’t download or verify this update. Your installed version is unchanged; try again."; }
        finally { download.Dispose(); download = null; Busy = false; Notify(); }
    }
    public void Cancel() => download?.Cancel();
    public async Task Install(Func<Task> prepareToQuit)
    {
        if (!Ready || Busy) return;
        if (MessageBox.Show("Install the downloaded update and restart fxclip now?", "Restart to Update", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        Busy = true; Notify();
        try
        {
            await prepareToQuit();
            // Launch the updater before normal WPF shutdown, so the mutex and clipboard are released gracefully.
            manager.WaitExitThenApplyUpdates(manager.UpdatePendingRestart, silent: false, restart: true);
            Application.Current.Shutdown();
        }
        catch (Exception) { Status = "Couldn’t start the installer. Try again when you’re ready."; Busy = false; Notify(); }
    }
}

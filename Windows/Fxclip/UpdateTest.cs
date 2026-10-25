#if UPDATE_TESTING
using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using Velopack;

namespace Fxclip;

// Compiled only into isolated CI fixtures. Uses real Velopack packages and Update.exe.
internal static class UpdateTest
{
    public static async Task Run(SettingsStore store, string[] args)
    {
        var phase = args[1]; var source = args[2]; var output = args[3];
        try
        {
            var manager = new UpdateManager(source);
            if (!manager.IsInstalled) throw new Exception("Fixture is not a real Velopack install");
            if (store.Preferences.TrackersRemoved != 42 || store.User.TrackersEverywhere) throw new Exception("Settings were not preserved");
            if (phase == "offline-default")
            {
                var updater = new AppUpdater(store, manager); updater.Start();
                await Task.Delay(1500); updater.Stop();
                if (store.Preferences.LastUpdateCheck != DateTimeOffset.MinValue || store.Preferences.AutomaticUpdateChecks) throw new Exception("Unexpected automatic network check");
            }
            else if (phase == "network")
            {
                var updater = new AppUpdater(store, manager);
                await updater.Check();
                if (!updater.Status.StartsWith("Couldn’t check")) throw new Exception("Network error not explained");
            }
            else if (phase == "automatic")
            {
                var updater = new AppUpdater(store, manager);
                store.Preferences.LastUpdateCheck = DateTimeOffset.MinValue;
                updater.SetAutomatic(true);
                for (var i = 0; i < 100 && updater.Busy; i++) await Task.Delay(100);
                var checkedAt = store.Preferences.LastUpdateCheck;
                if (checkedAt == DateTimeOffset.MinValue || updater.Busy) throw new Exception("Automatic check did not complete");
                updater.Start(); await Task.Delay(1500); updater.Stop();
                if (store.Preferences.LastUpdateCheck != checkedAt) throw new Exception("Checked more than daily");
                updater.SetAutomatic(false);
            }
            else if (phase == "migrate-login")
            {
                SettingsStore.MigrateLoginPath();
                if (!SettingsStore.OpenAtLogin) throw new Exception("Login path not migrated");
            }
            else if (phase == "verify")
            {
                if (Process.GetProcessesByName("fxclip").Length != 1) throw new Exception("Duplicate app instances");
                if (Program.Version != "1.0.1" || manager.UpdatePendingRestart is not null) throw new Exception("Update was not installed");
                if (await manager.CheckForUpdatesAsync() is not null) throw new Exception("Equal version offered again");
            }
            else if (phase == "pending")
            {
                if (Program.Version != "1.0.0" || manager.UpdatePendingRestart is null) throw new Exception("Pending update was applied without consent");
                if (manager.UpdatePendingRestart.FileName != "fxclip-1.0.1-full.nupkg" || manager.UpdatePendingRestart.PackageId != "FxclipUpdateQA")
                    throw new Exception("Restart lost the neutral package filename or installed identity");
                manager.WaitExitThenApplyUpdates(manager.UpdatePendingRestart, silent: true, restart: true, restartArgs: ["--update-test", "verify", source, output]);
                Application.Current.Shutdown(); return;
            }
            else
            {
                var info = await manager.CheckForUpdatesAsync();
                if (phase == "older") { if (info is not null) throw new Exception("Older version offered"); }
                else
                {
                    if (info is null || info.TargetFullRelease.Version.ToString() != "1.0.1") throw new Exception("Missing update");
                    if (info.TargetFullRelease.FileName != "fxclip-1.0.1-full.nupkg" || info.TargetFullRelease.PackageId != "FxclipUpdateQA")
                        throw new Exception("Feed changed the internal identity or exposed the legacy filename");
                    if (phase == "download") await manager.DownloadUpdatesAsync(info);
                    else if (phase is "cancel" or "corrupt")
                    {
                        using var cancel = new CancellationTokenSource();
                        try
                        {
                            await manager.DownloadUpdatesAsync(info, p => { if (phase == "cancel" && p > 0) cancel.Cancel(); }, cancel.Token);
                            throw new Exception("Invalid or cancelled download succeeded");
                        }
                        catch (OperationCanceledException) when (phase == "cancel") { }
                        catch (Velopack.Exceptions.ChecksumFailedException) when (phase == "corrupt") { }
                        if (manager.UpdatePendingRestart is not null) throw new Exception("Invalid download became installable");
                    }
                    // 'decline' intentionally stops after checking: no download, no replacement.
                }
            }
            File.WriteAllText(output, JsonSerializer.Serialize(new { phase, version = Program.Version, pid = Environment.ProcessId, status = "passed" }));
            Application.Current.Shutdown();
        }
        catch (Exception e) { File.WriteAllText(output, e.ToString()); Application.Current.Shutdown(1); }
    }
}
#endif

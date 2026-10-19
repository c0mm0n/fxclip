using System.IO.Pipes;
using System.Reflection;
using System.Security.Principal;
using System.Windows;
using System.Windows.Interop;
using Velopack;
using Forms = System.Windows.Forms;

namespace Fxclip;

internal static class Program
{
    private static Application app = null!;
    private static SettingsStore store = null!;
    private static ClipboardService? clipboard;
    private static SettingsWindow? settings;
    private static AppUpdater updates = null!;
    private static WelcomeWindow? welcome;
    private static Forms.NotifyIcon? tray;
    private static readonly CancellationTokenSource shutdown = new();
    private static bool quitting;
    private static string pipeName = "";
    public static string Version => typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0-dev";

    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        pipeName = "fxclip-" + sid;
        using var mutex = new Mutex(true, @"Local\" + pipeName, out var first);
        if (!first)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                client.Connect(5000);
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                var processId = new byte[4];
                client.ReadExactlyAsync(processId, timeout.Token).AsTask().GetAwaiter().GetResult();
                // The user launched this second process: grant the running instance foreground access.
                Native.AllowSetForegroundWindow(BitConverter.ToUInt32(processId));
                client.WriteByte(1);
            }
            catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
            return;
        }
        app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            MessageBox.Show("fxclip couldn't complete this action. Check that its settings folder is writable, then try again.", "fxclip", MessageBoxButton.OK, MessageBoxImage.Warning);
            e.Handled = true;
        };
        app.Startup += (_, _) =>
        {
            Theme.Initialize();
            try { store = new SettingsStore(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                MessageBox.Show("fxclip couldn't read or preserve its settings. Check access to the fxclip folder in Application Data and open the app again.", "fxclip");
                app.Shutdown(1);
                return;
            }
#if UPDATE_TESTING
            if (args.Length == 4 && args[0] == "--update-test") { _ = UpdateTest.Run(store, args); return; }
#endif
            var capture = Array.IndexOf(args, "--capture-ui");
            if (capture >= 0)
            {
                if (capture + 1 >= args.Length) { app.Shutdown(2); return; }
                _ = UiSnapshots.Capture(store, args[capture + 1]);
                return;
            }
            SettingsStore.MigrateLoginPath();
            updates = new AppUpdater(store);
            _ = Listen();
            if (store.FirstRun && !args.Contains("--no-welcome"))
            {
                welcome = new WelcomeWindow(store, () => { welcome = null; Start(); });
                welcome.Show();
            }
            else { if (store.FirstRun) store.Save(); Start(); }
        };
        app.Exit += (_, _) => { shutdown.Cancel(); updates?.Stop(); clipboard?.Dispose(); tray?.Dispose(); Theme.Dispose(); };
        app.Run();
        mutex.ReleaseMutex();
    }
    private static async Task Listen()
    {
        while (!shutdown.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(shutdown.Token);
                var buffer = new byte[1];
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(3));
                await server.WriteAsync(BitConverter.GetBytes(Environment.ProcessId), timeout.Token);
                if (await server.ReadAsync(buffer, timeout.Token) > 0) app.Dispatcher.Invoke(ShowSettings);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
        }
    }
    private static void Start()
    {
        clipboard = new ClipboardService(store);
        tray = new Forms.NotifyIcon
        {
            Text = "fxclip · Cleaning links",
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!),
            Visible = store.Preferences.ShowTrayIcon
        };
        tray.DoubleClick += (_, _) => ShowSettings();
        clipboard.Changed += UpdateTray;
        store.Changed += () =>
        {
            clipboard.Engine = new(store.Effective);
            clipboard.Request();
            tray.Visible = store.Preferences.ShowTrayIcon;
            settings?.Refresh();
            UpdateTray();
        };
        UpdateTray();
        updates.Start();
    }
    private static void UpdateTray()
    {
        if (tray is null || clipboard is null) return;
        tray.Text = clipboard.Paused ? "fxclip · Paused" : "fxclip · Cleaning links";
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(clipboard.Status).Enabled = false;
        menu.Items.Add($"{store.Preferences.TrackersRemoved:N0} trackers removed").Enabled = false;
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(clipboard.Paused ? "Resume" : "Pause", null, (_, _) => clipboard.TogglePause());
        menu.Items.Add(clipboard.SkipNext ? "Don't skip next copy" : "Skip next copy", null, (_, _) => clipboard.ToggleSkip());
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        menu.Items.Add("Check for Updates…", null, (_, _) => { ShowSettings(); settings?.SelectPage("Settings"); _ = updates.Check(); });
        menu.Items.Add("About", null, (_, _) => MessageBox.Show($"fxclip {Version}\n\nClean links, ready to share.\nCleaning stays local. Optional updates contact GitHub.\nNo account or analytics.\nLinks are never saved.", "About fxclip"));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => _ = Quit());
        var old = tray.ContextMenuStrip;
        tray.ContextMenuStrip = menu;
        old?.Dispose();
    }
    private static async Task Quit()
    {
        if (quitting) return;
        quitting = true;
        if (clipboard is not null) await clipboard.RestoreBeforeQuit();
        app.Shutdown();
    }
    private static void ShowSettings()
    {
        if (welcome is not null) { welcome.Activate(); Native.SetForegroundWindow(new WindowInteropHelper(welcome).Handle); return; }
        if (clipboard is null) return;
        if (settings is null)
        {
            settings = new SettingsWindow(store, clipboard, updates);
            settings.Closed += (_, _) => settings = null;
        }
        settings.Show();
        if (settings.WindowState == WindowState.Minimized) settings.WindowState = WindowState.Normal;
        settings.Activate();
        Native.SetForegroundWindow(new WindowInteropHelper(settings).Handle);
    }
}

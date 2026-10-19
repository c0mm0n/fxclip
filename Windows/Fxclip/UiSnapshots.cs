using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Fxclip;

// Opt-in build verification on the disposable CI desktop; never used in normal startup.
internal static class UiSnapshots
{
    public static async Task Capture(SettingsStore store, string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            using var clipboard = new ClipboardService(store);
            foreach (var dark in new[] { false, true })
            {
                Theme.CaptureTheme(dark);
                var themeDirectory = Path.Combine(directory, dark ? "dark" : "light");
                Directory.CreateDirectory(themeDirectory);
                var window = new SettingsWindow(store, clipboard);
                window.Show();
                foreach (var name in new[] { "Overview", "Link cleaning", "App previews", "Never clean", "Settings" })
                {
                    window.SelectPage(name);
                    await Save(window, Path.Combine(themeDirectory, name.ToLowerInvariant().Replace(' ', '-') + ".png"));
                }
                window.SelectPage("Overview");
                clipboard.TogglePause();
                await Save(window, Path.Combine(themeDirectory, "overview-paused.png"));
                clipboard.TogglePause();
                var chooser = new ChooseAppsWindow(store, store.Builtins.Previews[0]) { Owner = window };
                chooser.Show();
                await Save(chooser, Path.Combine(themeDirectory, "choose-apps.png"));
                chooser.Close();
                var welcome = new WelcomeWindow(store, () => { });
                welcome.Show();
                await Save(welcome, Path.Combine(themeDirectory, "welcome.png"));
                // Welcome cannot close before Start; hide this capture-only window.
                welcome.Hide();
                window.Close();
            }
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            File.WriteAllText(Path.Combine(directory, "capture-error.txt"), e.GetType().Name + ": " + e.Message);
            Application.Current.Shutdown(1);
        }
    }
    private static async Task Save(Window window, string path)
    {
        await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        window.UpdateLayout();
        var width = (int)Math.Ceiling(window.ActualWidth);
        var height = (int)Math.Ceiling(window.ActualHeight);
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            var bounds = new Rect(0, 0, width, height);
            drawing.DrawRectangle(window.Background, null, bounds);
            // Capture the full window visual, including its background and content margins.
            drawing.DrawRectangle(new VisualBrush(window) { Stretch = Stretch.Fill }, null, bounds);
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}

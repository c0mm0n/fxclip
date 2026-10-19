using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;

namespace Fxclip;

internal sealed class WelcomeWindow : Window
{
    private bool started;
    public WelcomeWindow(SettingsStore store, Action done)
    {
        Title = "Welcome to fxclip";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Ui.Setup(this);
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            Native.SetWindowLong(handle, -16, Native.GetWindowLong(handle, -16) & ~0x80000);
        };
        Closing += (_, e) => { if (!started) e.Cancel = true; };
        var panel = new StackPanel { Margin = new Thickness(28) };
        panel.Children.Add(Ui.Text("Clean links, ready to share", 24, true));
        var intro = Ui.Text("fxclip removes trackers (utm_*, fbclid, YouTube si…) from every link you copy. Nothing leaves your PC.");
        intro.Margin = new Thickness(0, 16, 0, 12);
        panel.Children.Add(intro);
        var previews = new CheckBox { Content = "Also adapt links for Telegram previews", IsChecked = true };
        panel.Children.Add(previews);
        var detail = Ui.Text("Optional: use preview-friendly versions of X and Instagram links in Telegram. Other apps get the clean original. Choose other destination apps in App previews. Preview mirrors are run by third parties.", 12, secondary: true);
        detail.Margin = new Thickness(23, 0, 0, 14);
        panel.Children.Add(detail);
        var login = new CheckBox { Content = "Open fxclip at login", IsChecked = true };
        panel.Children.Add(login);
        panel.Children.Add(Ui.Text("You can change all of this later in Settings.", 12, secondary: true));
        if (store.Recovered)
        {
            var recovered = Ui.Text("Your previous settings couldn't be read. They have been kept in settings.unreadable.json. Choose your preferences to start again.", 12);
            recovered.Margin = new Thickness(0, 16, 0, 0);
            panel.Children.Add(recovered);
        }
        var start = Ui.Button("Start", () =>
        {
            foreach (var p in store.Builtins.Previews) store.User.Previews[p.Id] = new(previews.IsChecked == true, store.Setting(p).Apps);
            SettingsStore.SetLogin(login.IsChecked == true);
            store.Save();
            started = true;
            Close();
            done();
        });
        start.IsDefault = true;
        start.HorizontalAlignment = HorizontalAlignment.Right;
        start.Margin = new Thickness(0, 24, 0, 0);
        panel.Children.Add(start);
        Content = panel;
    }
}

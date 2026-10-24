using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Fxclip.Engine;

namespace Fxclip;

internal sealed class PreviewProviderWindow : Window
{
    public PreviewProviderWindow(SettingsStore store, PreviewRule preview)
    {
        Title = preview.Name + " preview domain";
        Width = 460; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Ui.Setup(this);
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(Title, 20, true));
        var domain = new TextBox { Text = store.PreviewTargetHost(preview), Margin = new Thickness(0, 16, 0, 8) };
        AutomationProperties.SetName(domain, "Preview domain");
        panel.Children.Add(domain);
        panel.Children.Add(Ui.Text("Default: " + preview.To, 12, secondary: true));
        var error = Ui.Text("Enter a domain only, such as preview.example.", 12);
        error.Foreground = Brushes.Firebrick; error.Visibility = Visibility.Collapsed;
        panel.Children.Add(error);
        void Save(string? host)
        {
            store.User.Previews[preview.Id] = store.Setting(preview) with { TargetHost = host };
            store.Save(); DialogResult = true;
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 16, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(Ui.Button("Use Default", () => Save(null)));
        var cancel = Ui.Button("Cancel", () => Close()); cancel.IsCancel = true; buttons.Children.Add(cancel);
        var save = Ui.Button("Save", () =>
        {
            var raw = domain.Text.Trim(' ', '\t', '\r', '\n', '\v', '\f');
            var host = Rules.CanonicalPreviewHost(raw);
            if (raw.Length > 0 && host is null) { error.Visibility = Visibility.Visible; return; }
            Save(host);
        });
        save.IsDefault = true; buttons.Children.Add(save);
        panel.Children.Add(buttons); Content = panel;
        Loaded += (_, _) => { domain.Focus(); domain.SelectAll(); };
    }
}

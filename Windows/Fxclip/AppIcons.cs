using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Fxclip.Engine;

namespace Fxclip;

internal static class AppIcons
{
    private static readonly Dictionary<string, ImageSource> icons = [];
    public static FrameworkElement View(AppRule app)
    {
        var path = AppDiscovery.ExecutablePath(app);
        if (path is not null)
        {
            try
            {
                if (!icons.TryGetValue(path, out var source))
                {
                    using var icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
                    if (icon is not null)
                    {
                        var bitmap = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(16, 16));
                        bitmap.Freeze(); source = bitmap; icons[path] = source;
                    }
                }
                if (source is not null) return new Image { Source = source, Width = 16, Height = 16, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            }
            catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.ExternalException) { }
        }
        var glyph = Ui.Text("\uE8A5", 14, secondary: true);
        glyph.FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");
        glyph.Width = 16; glyph.Margin = new Thickness(0, 0, 6, 0);
        return glyph;
    }
}

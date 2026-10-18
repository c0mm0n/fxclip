using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using Microsoft.Win32;

namespace Fxclip;

internal static class Theme
{
    public static bool Dark { get; private set; }
    public static void Initialize()
    {
        var styles = (ResourceDictionary)XamlReader.Parse("""
        <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
          <Style TargetType="Window"><Setter Property="FontFamily" Value="Segoe UI Variable, Segoe UI"/><Setter Property="FontSize" Value="14"/><Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/></Style>
          <Style TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="Background" Value="{DynamicResource Control}"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="Padding" Value="14,7"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="32"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="body" CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource Line}" BorderThickness="1" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="body" Property="Opacity" Value="0.78"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="body" Property="BorderBrush" Value="#438EE8"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="body" Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
          </Style>
          <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="Margin" Value="4,8"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
          <Style x:Key="Switch" TargetType="CheckBox">
            <Setter Property="Margin" Value="10,4"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><Border x:Name="track" Width="42" Height="22" Background="{DynamicResource Muted}" CornerRadius="11" BorderBrush="{DynamicResource Line}" BorderThickness="1"><Ellipse x:Name="thumb" Width="14" Height="14" Fill="White" HorizontalAlignment="Left" Margin="3"/></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="track" Property="Background" Value="#1675DC"/><Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="track" Property="BorderBrush" Value="#65A9FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
          </Style>
          <Style TargetType="TextBox"><Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="Background" Value="{DynamicResource Control}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/><Setter Property="Padding" Value="10,8"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="CaretBrush" Value="{DynamicResource Ink}"/></Style>
          <Style TargetType="ToolTip"><Setter Property="MaxWidth" Value="320"/></Style>
        </ResourceDictionary>
        """);
        Application.Current.Resources.MergedDictionaries.Add(styles);
        Refresh();
        SystemEvents.UserPreferenceChanged += Changed;
    }
    private static void Changed(object sender, UserPreferenceChangedEventArgs e) => Application.Current.Dispatcher.BeginInvoke(Refresh);
    private static void Refresh()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        Dark = key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        var colors = new Dictionary<string, string>
        {
            ["Surface"] = Dark ? "#202020" : "#F7F7F7", ["Sidebar"] = Dark ? "#292929" : "#EEEEEE",
            ["Card"] = Dark ? "#2C2C2C" : "#FFFFFF", ["Control"] = Dark ? "#363636" : "#FAFAFA",
            ["Ink"] = Dark ? "#F3F3F3" : "#202020", ["Secondary"] = Dark ? "#B7B7B7" : "#626262",
            ["Line"] = Dark ? "#454545" : "#DEDEDE", ["Muted"] = Dark ? "#656565" : "#999999"
        };
        foreach (var (name, hex) in colors) Application.Current.Resources[name] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        foreach (Window window in Application.Current.Windows) TitleBar(window);
    }
    public static void TitleBar(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == 0) return;
        var dark = Dark ? 1 : 0;
        Native.DwmSetWindowAttribute(hwnd, 20, ref dark, 4);
        var corners = 2;
        Native.DwmSetWindowAttribute(hwnd, 33, ref corners, 4);
    }
    public static void Dispose() => SystemEvents.UserPreferenceChanged -= Changed;
}

internal static class Ui
{
    public static TextBlock Text(string text, double size = 14, bool bold = false, bool secondary = false)
    {
        var view = new TextBlock { Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        if (secondary) view.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        return view;
    }
    public static Button Button(string text, Action click)
    {
        var button = new Button { Content = text };
        button.Click += (_, _) => click();
        return button;
    }
    public static CheckBox Toggle(string label, bool value, Action<bool> change, bool asSwitch = true)
    {
        var check = new CheckBox { Content = label, IsChecked = value, ToolTip = label };
        System.Windows.Automation.AutomationProperties.SetName(check, label);
        if (asSwitch) check.SetResourceReference(FrameworkElement.StyleProperty, "Switch");
        check.Checked += (_, _) => change(true);
        check.Unchecked += (_, _) => change(false);
        return check;
    }
    public static Border Card(UIElement content)
    {
        var border = new Border { Child = content, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(16), Margin = new Thickness(0, 0, 0, 12) };
        border.SetResourceReference(Border.BackgroundProperty, "Card");
        border.SetResourceReference(Border.BorderBrushProperty, "Line");
        return border;
    }
    public static DockPanel Row(UIElement label, params UIElement[] right)
    {
        var row = new DockPanel { LastChildFill = true, MinHeight = 38 };
        foreach (var child in right.Reverse()) { DockPanel.SetDock(child, Dock.Right); row.Children.Add(child); }
        row.Children.Add(label);
        return row;
    }
    public static void Setup(Window window)
    {
        window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        window.Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Assets/fxclip.ico"));
        window.SourceInitialized += (_, _) => Theme.TitleBar(window);
    }
}

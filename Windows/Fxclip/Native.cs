using System.Runtime.InteropServices;
using System.Text;

namespace Fxclip;

internal static class Native
{
    internal delegate void WinEventProc(nint hook, uint evt, nint hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll", SetLastError = true)] internal static extern bool AddClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll")] internal static extern bool RemoveClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] internal static extern bool OpenClipboard(nint hwnd);
    [DllImport("user32.dll")] internal static extern bool CloseClipboard();
    [DllImport("user32.dll")] internal static extern bool EmptyClipboard();
    [DllImport("user32.dll")] internal static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll")] internal static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] internal static extern nint GetClipboardData(uint format);
    [DllImport("user32.dll")] internal static extern nint SetClipboardData(uint format, nint data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern uint RegisterClipboardFormat(string format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClipboardFormatName(uint format, StringBuilder name, int count);
    [DllImport("kernel32.dll")] internal static extern nint GlobalAlloc(uint flags, nuint size);
    [DllImport("kernel32.dll")] internal static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")] internal static extern bool GlobalUnlock(nint memory);
    [DllImport("kernel32.dll")] internal static extern nint GlobalFree(nint memory);
    [DllImport("kernel32.dll")] internal static extern nuint GlobalSize(nint memory);
    [DllImport("user32.dll")] internal static extern nint SetWinEventHook(uint min, uint max, nint module, WinEventProc callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] internal static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint process);
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] internal static extern int GetWindowLong(nint hwnd, int index);
    [DllImport("user32.dll")] internal static extern int SetWindowLong(nint hwnd, int index, int value);
    [DllImport("dwmapi.dll")] internal static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}

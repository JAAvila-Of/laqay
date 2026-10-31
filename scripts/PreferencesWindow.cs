// Locate and close only an owned Laqay tray window. No input is synthesized.
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LaqayPreferencesWindow {
    private delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, StringBuilder name, int count);
    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    public static IntPtr Find(uint process) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != process) return true;
            var name = new StringBuilder(128);
            if (GetClassNameW(window, name, name.Capacity) > 0 && name.ToString() == "LaqayTrayWindow") {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool Close(uint process) {
        IntPtr window = Find(process);
        return window != IntPtr.Zero && PostMessageW(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
}

using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace ComposerBubbles;

internal static class CodexStartup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunName = "Composer Bubbles with Codex";
    private const string WatcherInstance = @"Local\ComposerBubbles.CodexWatcher";
    private const string StopEvent = @"Local\ComposerBubbles.StopCodexWatcher";
    // Microsoft Store product 9PLM9XGG6VKS is the unified ChatGPT/Codex app.
    private const string CodexPackage = "OpenAI.Codex_2p2nqsd0c76g0";
    private const uint ForegroundEvent = 0x0003;
    private const uint QueryLimitedInformation = 0x1000;

    private static string Executable => Environment.ProcessPath ?? throw new InvalidOperationException();
    private static string Command => $"\"{Executable}\" --watch-codex";

    internal static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return string.Equals(key?.GetValue(RunName) as string, Command, StringComparison.OrdinalIgnoreCase);
    }

    internal static void SetEnabled(bool enabled)
    {
        if (!string.Equals(Path.GetFileNameWithoutExtension(Executable), "ComposerBubbles", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Open ComposerBubbles.exe to change automatic launch.");
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        var previous = key.GetValue(RunName) as string;
        if (!enabled)
        {
            if (string.Equals(previous, Command, StringComparison.OrdinalIgnoreCase))
                key.DeleteValue(RunName, throwOnMissingValue: false);
            if (EventWaitHandle.TryOpenExisting(StopEvent, out var stop))
            {
                using (stop)
                    stop.Set();
            }
            return;
        }

        key.SetValue(RunName, Command, RegistryValueKind.String);
        try
        {
            using var child = Open("--watch-codex");
        }
        catch (Win32Exception)
        {
            if (previous is null)
                key.DeleteValue(RunName, throwOnMissingValue: false);
            else
                key.SetValue(RunName, previous, RegistryValueKind.String);
            throw;
        }
    }

    private static Process? Open(string mode)
    {
        var start = new ProcessStartInfo(Executable) { UseShellExecute = false };
        start.ArgumentList.Add(mode);
        return Process.Start(start);
    }

    private static bool IsCodexWindow(IntPtr window)
    {
        if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out var processId) == 0)
            return false;
        using var process = OpenProcess(QueryLimitedInformation, false, processId);
        if (process.IsInvalid)
            return false;
        var package = new StringBuilder(128);
        var length = (uint)package.Capacity;
        return GetPackageFamilyName(process, ref length, package) == 0 &&
            string.Equals(package.ToString(), CodexPackage, StringComparison.OrdinalIgnoreCase);
    }

    internal sealed class Watcher : IDisposable
    {
        private readonly Mutex singleton;
        private readonly EventWaitHandle stopSignal;
        private readonly RegisteredWaitHandle stopWait;
        private readonly WinEventProc callback;
        private readonly IntPtr hook;
        private Process? opening;

        private Watcher(Application app, Mutex singleton)
        {
            this.singleton = singleton;
            stopSignal = new EventWaitHandle(false, EventResetMode.AutoReset, StopEvent);
            stopWait = ThreadPool.RegisterWaitForSingleObject(stopSignal,
                (_, _) => app.Dispatcher.InvokeAsync(() => app.Shutdown()), null, Timeout.Infinite, true);
            callback = (_, _, window, _, _, _, _) => OpenIfNeeded(window);
            // Out-of-context hooks deliver events on this UI dispatcher.
            hook = SetWinEventHook(ForegroundEvent, ForegroundEvent, IntPtr.Zero, callback, 0, 0, 0);
        }

        internal static Watcher? Start(Application app)
        {
            if (!IsEnabled())
                return null;
            var singleton = new Mutex(true, WatcherInstance, out var first);
            if (!first)
            {
                singleton.Dispose();
                return null;
            }
            var watcher = new Watcher(app, singleton);
            if (watcher.hook == IntPtr.Zero)
            {
                watcher.Dispose();
                return null;
            }
            watcher.OpenIfNeeded(GetForegroundWindow());
            return watcher;
        }

        private void OpenIfNeeded(IntPtr window)
        {
            if (Mutex.TryOpenExisting(App.ShelfInstanceName, out var shelf))
            {
                shelf.Dispose();
                return;
            }
            if (opening is { HasExited: false } || !IsCodexWindow(window))
                return;
            opening?.Dispose();
            opening = null;
            try { opening = Open("--from-codex"); }
            catch (Win32Exception) { }
        }

        public void Dispose()
        {
            if (hook != IntPtr.Zero)
                UnhookWinEvent(hook);
            stopWait.Unregister(null);
            stopSignal.Dispose();
            opening?.Dispose();
            singleton.Dispose();
        }
    }

    private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId,
                                       uint eventThread, uint eventTime);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc callback,
                                                  uint process, uint thread, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWinEvent(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

    [DllImport("kernel32.dll")]
    private static extern SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint process);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackageFamilyName(SafeProcessHandle process, ref uint length, StringBuilder name);
}

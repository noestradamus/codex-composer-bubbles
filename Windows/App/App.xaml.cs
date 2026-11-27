using System.Windows;

namespace ComposerBubbles;

public partial class App : Application
{
    internal const string ShelfInstanceName = @"Local\ComposerBubbles.Shelf";
    private Mutex? shelfInstance;
    private CodexStartup.Watcher? watcher;

    protected override void OnStartup(StartupEventArgs args)
    {
        base.OnStartup(args);
        if (args.Args is ["--watch-codex"])
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            watcher = CodexStartup.Watcher.Start(this);
            if (watcher is null)
                Shutdown();
            return;
        }

        shelfInstance = new Mutex(true, ShelfInstanceName, out var firstInstance);
        if (!firstInstance)
        {
            Shutdown();
            return;
        }
        MainWindow = new ShelfWindow { ShowActivated = args.Args is not ["--from-codex"] };
        MainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs args)
    {
        watcher?.Dispose();
        shelfInstance?.Dispose();
        base.OnExit(args);
    }
}

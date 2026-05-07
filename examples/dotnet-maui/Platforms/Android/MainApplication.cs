using Android.App;
using Android.Runtime;

namespace DvaiBridgeMauiSample;

[Application]
public class MainApplication : MauiApplication
{
    public MainApplication(IntPtr handle, JniHandleOwnership ownership)
        : base(handle, ownership)
    {
    }

    public override void OnCreate()
    {
        base.OnCreate();
#if ANDROID
        // Required for the MediaPipe / LiteRT backends and for
        // DownloadModelAsync. Idempotent. Until the AAR is fetched (CI step)
        // this is a no-op via the placeholder Bootstrap class — see
        // DVAIBridge.Android/AndroidNativeBridge.cs.
        DVAIBridge.Android.Bootstrap.Init(ApplicationContext!);
#endif
    }

    protected override MauiApp CreateMauiApp() => MauiProgram.CreateMauiApp();
}

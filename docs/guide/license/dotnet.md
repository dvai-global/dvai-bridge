# License setup — .NET

You added `DVAIBridge` to your .NET MAUI, Avalonia, WinUI, or console
project and want to ship a release. Here's the licensing path.

## TL;DR

Add `dvai-license.jwt` to your `.csproj` as content with
`CopyToOutputDirectory="PreserveNewest"`. The SDK reads it from the
app's working directory at startup. In `Debug` configurations the SDK
ignores license problems.

## Where the file goes

Add the file next to your `.csproj`:

```
MyApp/
  MyApp.csproj
  dvai-license.jwt
```

Then mark it as content so it ends up next to the binary:

```xml
<ItemGroup>
  <None Update="dvai-license.jwt">
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </None>
</ItemGroup>
```

For MAUI / mobile build profiles, also include it as a MAUI asset:

```xml
<ItemGroup Condition="'$(TargetFramework)' == 'net10.0-android' or '$(TargetFramework)' == 'net10.0-ios'">
  <MauiAsset Include="dvai-license.jwt" />
</ItemGroup>
```

Alternative locations the SDK also checks (in priority order):

1. Inline JWT via `StartOptions { LicenseToken = "..." }`.
2. Explicit path via `StartOptions { LicenseKeyPath = "..." }`.
3. `DVAI_LICENSE_PATH` environment variable.
4. `DVAI_LICENSE_TOKEN` environment variable.
5. `dvai-license.jwt` in `AppContext.BaseDirectory` (auto-discovered).

## Code: with vs. without

Default (license deployed next to binary):

```csharp
using DVAIBridge;

var bound = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Llama,
    ModelPath = modelPath
});

Console.WriteLine(bound.BaseUrl);          // http://127.0.0.1:38883/v1
Console.WriteLine(bound.LicenseStatus);    // Commercial { Licensee = "Acme", ... }
```

Inline JWT (e.g. read from a config service):

```csharp
var token = Environment.GetEnvironmentVariable("DVAI_LICENSE_JWT")
            ?? throw new InvalidOperationException("missing license env");

var bound = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Llama,
    ModelPath = modelPath,
    LicenseToken = token
});
```

Explicit path:

```csharp
var bound = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Llama,
    ModelPath = modelPath,
    LicenseKeyPath = Path.Combine(FileSystem.AppDataDirectory, "dvai-license.jwt")
});
```

::: tip Native license fields land in v3.3
In v3.2.x, the .NET SDK ships without `LicenseToken` /
`LicenseKeyPath` on `StartOptions`. The Capacitor-wrapped path runs
the JS validator automatically; pure-native .NET apps in v3.2 ship
under a "dev preview" allowance. Native .NET validation arrives in
v3.3 — pin to v3.3+ to enforce on .NET.
:::

## What happens without a license

In `Release` configurations, `StartAsync(...)` throws
`LicenseRequiredException`:

```csharp
try
{
    var bound = await DVAIBridge.Shared.StartAsync(...);
}
catch (LicenseRequiredException ex)
{
    // ex.Message is a multi-line, user-presentable string with
    // remediation steps. ex.Reason carries the machine-readable
    // failure kind ("FreeProd" or "FreeExpired").
    Console.Error.WriteLine(ex.Message);
    Environment.Exit(1);
}
```

## Testing locally without a license

`Debug` builds skip license checks automatically. The SDK detects
debug mode via `Debugger.IsAttached` and `#if DEBUG`.

To force dev mode explicitly:

```bash
DVAI_FORCE_DEV=1 dotnet run -c Release
```

To rehearse the production code path:

```bash
DVAI_FORCE_PROD=1 dotnet run -c Release
```

## Per-flavour notes

- **MAUI iOS / Android**: the file is loaded from the bundled
  `MauiAsset` path on mobile and from `AppContext.BaseDirectory` on
  Catalyst.
- **Avalonia / WinUI desktop**: the file lives next to the binary in
  `bin/<config>/<tfm>/`.
- **Console / server**: same discovery rules as
  [Node](./node) (env vars, cwd, etc.).

## When validation fails

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `no license token found` | File didn't make it into the output dir | Verify `CopyToOutputDirectory="PreserveNewest"` in `.csproj` |
| `signature did not verify` | Wrong key or tampered token | Re-download from your licensor |
| `does not authorise platform "dotnet"` | License missing `"dotnet"` in `platforms` | Re-issue covering .NET |
| `audience entries ... do not match` | Assembly identity doesn't match `aud` | Re-issue, or use a wildcard |
| `expired` | Past `exp` | Renew |

The runtime audience on .NET is the executing assembly's name, or the
value of the `DVAI_AUDIENCE` env var if set. Most licenses include a
`"*"` fallback.

## See also

- [License setup index](./index)
- [Pre-init inspection](./pre-init-inspection) — run `LicenseValidator`
  standalone for a license-status badge in a MAUI / WPF dashboard
  without `StartAsync()`.
- [.NET SDK](/guide/dotnet-sdk) — full SDK reference.

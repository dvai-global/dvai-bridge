# `dvai_bridge` example

This package follows the project-wide convention of **scripted samples
only** — there is no in-tree example app. To exercise the plugin against a
real Flutter app:

1. Create a fresh app:
   ```bash
   flutter create my_dvai_app
   cd my_dvai_app
   flutter pub add dvai_bridge
   ```
2. Follow the [Flutter SDK guide](https://bridge.deepvoiceai.co/guide/flutter-sdk)
   for the iOS Podfile + Android `settings.gradle.kts` snippets.
3. Drop the snippet from the README into `lib/main.dart` and
   `flutter run` against an iOS simulator or Android emulator.

The CI smoke workflow at `.github/workflows/test-flutter.yml` builds a
scripted minimal example app to keep the integration honest without
checking it into the package source.

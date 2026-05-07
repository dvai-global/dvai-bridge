// Widget-level smoke test for the DVAI-Bridge Flutter example.
//
// Mounts the app and verifies the static surface — the home page renders
// the title, the backend dropdown, and the Start / Stop / Send buttons.
// Nothing here exercises the platform channel; that requires a real
// device (covered by the platform-side build smokes).

import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home page renders the bridge controls', (WidgetTester tester) async {
    await tester.pumpWidget(const DvaiBridgeExampleApp());
    await tester.pump();

    expect(find.text('DVAI-Bridge — Flutter'), findsOneWidget);
    expect(find.text('Backend'), findsOneWidget);
    expect(find.text('Model path'), findsOneWidget);
    expect(find.text('Prompt'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
  });
}

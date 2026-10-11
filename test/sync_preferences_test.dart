import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/preferences_screen.dart';
import 'package:turbonotes/services/preferences.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('turbonotes-sync-prefs');
    SharedPreferences.setMockInitialValues({'flutter.Directory': dir.path});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PreferencesScreen(preferences: PreferencesService()),
                ),
              ),
              child: const Text('Open preferences'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preferences'));
    for (
      var i = 0;
      i < 30 &&
          find.byKey(const ValueKey('prefs.directory')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('prefs.s3-enabled')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('prefs.s3-enabled')));
    await tester.pumpAndSettle();
  }

  testWidgets('S3 form saves enabled settings and obscures the secret', (
    tester,
  ) async {
    await open(tester);
    for (final field in [
      ('endpoint', 'https://s3.example.org/'),
      ('region', 'test-region'),
      ('bucket', 'test-notes'),
      ('access-key', 'access'),
      ('secret-key', 'secret'),
    ]) {
      final finder = find.byKey(ValueKey('prefs.s3-${field.$1}'));
      await tester.scrollUntilVisible(
        finder,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(finder, field.$2);
    }
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('prefs.s3-secret-key')))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('prefs.save')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    final saved = await PreferencesService().syncConfig();
    expect(saved.enabled, isTrue);
    expect(saved.endpoint, 'https://s3.example.org');
    expect(saved.region, 'test-region');
    expect(saved.bucket, 'test-notes');
    expect(saved.accessKey, 'access');
    expect(saved.secretKey, 'secret');
    expect(find.text('Open preferences'), findsOneWidget);
  });

  testWidgets(
    'enabling sync with missing credentials keeps the form and settings intact',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('prefs.save')));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter the S3 access key and secret key.'),
        findsOneWidget,
      );
      expect(find.text('Preferences'), findsOneWidget);
      expect((await PreferencesService().syncConfig()).enabled, isFalse);
    },
  );
}

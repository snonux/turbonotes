// Recreate documentation phone shots with real fonts:
// TURBONOTES_SCREENSHOT_FONT=/path/to/sans.ttf flutter test tool/sync_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/home_screen.dart';
import 'package:turbonotes/screens/preferences_screen.dart';
import 'package:turbonotes/services/preferences.dart';
import 'package:turbonotes/services/scoped_folder_service.dart';

import '../test/support/memory_note_store.dart';

void main() {
  testWidgets('render optional sync documentation', (tester) async {
    tester.view.physicalSize = const Size(400, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    final font = Platform.environment['TURBONOTES_SCREENSHOT_FONT'];
    if (font == null) {
      fail('Set TURBONOTES_SCREENSHOT_FONT to a real sans font.');
    }
    final dir = await tester.runAsync(() async {
      final loader = FontLoader('DocSans')
        ..addFont(
          File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      return Directory.systemTemp.createTemp('turbonotes-shots');
    });
    addTearDown(() => dir!.deleteSync(recursive: true));
    // This tool runs under flutter test, outside the default test/ directory.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'flutter.Directory': dir!.path,
      'flutter.S3SyncEnabled': true,
      'flutter.S3Endpoint': 'https://garage.f3s.buetow.org',
      'flutter.S3Region': 'garage',
      'flutter.S3Bucket': 'my-notes',
      'flutter.S3AccessKey': 'example-access-key',
      'flutter.S3SecretKey': 'example-secret',
    });
    final boundary = GlobalKey();
    Widget app(Widget home) => RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'DocSans',
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: home,
      ),
    );
    Future<void> shot(String path) async {
      await tester.pump();
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pumpWidget(
      app(
        PreferencesScreen(
          preferences: PreferencesService(),
          scopedFolderService: const ScopedFolderService(),
        ),
      ),
    );
    for (
      var i = 0;
      i < 30 &&
          find.byKey(const ValueKey('prefs.s3-enabled')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('prefs.s3-enabled')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const ValueKey('prefs.s3-enabled'))),
      alignment: 0.03,
    );
    await tester.pumpAndSettle();
    await shot('docs/images/phone-sync-preferences.png');
    debugPrint('Rendered sync preferences');
    await tester.pumpWidget(
      app(
        HomeScreen(
          preferences: PreferencesService(),
          storeFactory: () async => MemoryNoteStore({
            'TurboNote.md': '# Inbox',
            'ideas.md': '# Ideas',
            'todo.md': '- Write a note',
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    debugPrint('Loaded sync tree');
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    await shot('docs/images/phone-sync-menu.png');
    debugPrint('Rendered sync menu');
    debugDisableShadows = true;
  });
}

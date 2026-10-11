import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/home_screen.dart';
import 'package:turbonotes/screens/preferences_screen.dart';
import 'package:turbonotes/services/preferences.dart';

import 'support/memory_note_store.dart';

void main() {
  late MemoryNoteStore store;

  setUp(() {
    store = MemoryNoteStore({
      'inbox.md': '# Inbox\n',
      'projects/ideas.md': 'one two three\nfour\n',
      'projects/plan.md': 'plan',
    });
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    bool vi = false,
    Size size = const Size(1200, 800),
  }) async {
    SharedPreferences.setMockInitialValues({if (vi) 'flutter.ViKeys': true});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          preferences: PreferencesService(),
          storeFactory: () async => store,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> keys(WidgetTester tester, String typed) async {
    for (final c in typed.split('')) {
      final shift = c != c.toLowerCase();
      final key = switch (c.toLowerCase()) {
        '/' => LogicalKeyboardKey.slash,
        ':' => LogicalKeyboardKey.semicolon,
        final l => LogicalKeyboardKey(
          LogicalKeyboardKey.keyA.keyId + l.codeUnitAt(0) - 0x61,
        ),
      };
      if (shift || c == ':') {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.sendKeyEvent(key, character: c);
      if (shift || c == ':') {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.pump();
    }
  }

  Finder cursor() => find.byKey(const ValueKey('tree-cursor'));
  Finder underCursor(String id) =>
      find.descendant(of: cursor(), matching: find.byKey(ValueKey(id)));
  Finder field() => find.byKey(const ValueKey('note-editor-field'));
  bool editorFocused(WidgetTester tester) =>
      tester.widget<TextField>(field()).focusNode!.hasFocus;

  group('the sidebar', () {
    testWidgets('j, k, l and h move through the tree and open folders', (
      tester,
    ) async {
      await pumpHome(tester);
      await keys(tester, 'j');
      // Rows: folder:projects, note:inbox.md; the cursor starts on the first.
      expect(underCursor('note:inbox.md'), findsOneWidget);
      await keys(tester, 'k');
      expect(underCursor('folder:projects'), findsOneWidget);
      await keys(tester, 'l');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note:projects/plan.md')), findsOne);
      await keys(tester, 'l');
      expect(underCursor('note:projects/ideas.md'), findsOneWidget);
      await keys(tester, 'G');
      expect(underCursor('note:inbox.md'), findsOneWidget);
      await keys(tester, 'gg');
      expect(underCursor('folder:projects'), findsOneWidget);
      await keys(tester, 'jh');
      expect(underCursor('folder:projects'), findsOneWidget);
      await keys(tester, 'h');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note:projects/plan.md')), findsNothing);
    });

    testWidgets('Enter opens a note in the editor, Esc comes back', (
      tester,
    ) async {
      await pumpHome(tester);
      await keys(tester, 'G');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('inbox.md'), findsWidgets);
      expect(editorFocused(tester), isTrue);
      expect(
        tester.widget<TextField>(field()).controller!.selection,
        const TextSelection.collapsed(offset: 0),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(editorFocused(tester), isFalse);
      expect(underCursor('note:inbox.md'), findsOneWidget);
      // i goes back without moving the caret.
      await keys(tester, 'i');
      expect(editorFocused(tester), isTrue);
      // Ctrl+W h is the other way out.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await keys(tester, 'h');
      expect(editorFocused(tester), isFalse);
      expect(
        tester.widget<TextField>(field()).controller!.text,
        '# Inbox\n',
        reason: 'the h of Ctrl+W h is not typed',
      );
    });

    testWidgets('/ opens the finder, typed letters do nothing else', (
      tester,
    ) async {
      await pumpHome(tester);
      await keys(tester, 'q');
      expect(find.byKey(const ValueKey('fuzzy-query')), findsNothing);
      await keys(tester, '/');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fuzzy-query')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('fuzzy-query')), 'pl');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.text('projects/plan.md'), findsWidgets);
    });

    testWidgets('on a phone, Enter opens the note page and Esc closes it', (
      tester,
    ) async {
      await pumpHome(tester, size: const Size(400, 760));
      await keys(tester, 'G');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(field(), findsOneWidget);
      await tester.enterText(field(), '# Inbox\nmore\n');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(field(), findsNothing);
      expect(await store.read('inbox.md'), '# Inbox\nmore\n');
    });
  });

  group('vi mode in the editor', () {
    testWidgets('normal mode takes keys as commands', (tester) async {
      await pumpHome(tester, vi: true);
      await keys(tester, 'lj');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('-- NORMAL --'), findsOneWidget);
      final controller = tester.widget<TextField>(field()).controller!;
      expect(controller.text, 'one two three\nfour\n');
      expect(tester.widget<TextField>(field()).readOnly, isTrue);

      await keys(tester, 'dw');
      expect(controller.text, 'two three\nfour\n');
      await keys(tester, 'd');
      expect(find.byKey(const ValueKey('vi-pending')), findsOneWidget);
      expect(find.text('d'), findsOneWidget);
      await keys(tester, 'd');
      expect(controller.text, 'four\n');
      await keys(tester, 'u');
      expect(controller.text, 'two three\nfour\n');

      await keys(tester, 'A');
      expect(find.text('-- INSERT --'), findsOneWidget);
      expect(tester.widget<TextField>(field()).readOnly, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('-- NORMAL --'), findsOneWidget);
      // Esc in normal mode stays in the note.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(editorFocused(tester), isTrue);
    });

    testWidgets('formatting shortcuts do not edit in normal mode', (
      tester,
    ) async {
      await pumpHome(tester, vi: true);
      await keys(tester, 'lj');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(field()).controller!;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, 'one two three\nfour\n');

      await keys(tester, 'i');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, '****one two three\nfour\n');
    });

    testWidgets(':w saves, :q goes back to the tree', (tester) async {
      await pumpHome(tester, vi: true);
      await keys(tester, 'lj');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await keys(tester, 'x');
      await keys(tester, ':');
      await tester.pump();
      final prompt = find.byKey(const ValueKey('vi-prompt'));
      expect(prompt, findsOneWidget);
      await tester.enterText(prompt, 'w');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 100));
      expect(await store.read('projects/ideas.md'), 'ne two three\nfour\n');
      expect(editorFocused(tester), isTrue);

      await keys(tester, ':');
      await tester.pump();
      await tester.enterText(prompt, 'q');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(editorFocused(tester), isFalse);
      expect(underCursor('note:projects/ideas.md'), findsOneWidget);
    });

    testWidgets('on a phone, :wq saves and closes the note', (tester) async {
      await pumpHome(tester, vi: true, size: const Size(400, 760));
      await keys(tester, 'G');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await keys(tester, 'x:');
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('vi-prompt')), 'wq');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(field(), findsNothing);
      expect(await store.read('inbox.md'), ' Inbox\n');
    });

    testWidgets('/ searches the note', (tester) async {
      await pumpHome(tester, vi: true);
      await keys(tester, 'lj');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await keys(tester, '/');
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('vi-prompt')), 'four');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final controller = tester.widget<TextField>(field()).controller!;
      expect(controller.selection, const TextSelection.collapsed(offset: 14));
      expect(editorFocused(tester), isTrue);
    });
  });

  testWidgets('Preferences turns vi keys on', (tester) async {
    final dir = Directory.systemTemp.createTempSync('turbonotes-vi');
    addTearDown(() => dir.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({'flutter.Directory': dir.path});
    final prefs = PreferencesService();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Preferences checks the folder with dart:io, off the fake clock.
    Future<void> settle() => tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: PreferencesScreen(preferences: prefs),
      ),
    );
    final toggle = find.byKey(const ValueKey('prefs.vi-keys'));
    for (var i = 0; i < 20 && toggle.evaluate().isEmpty; i++) {
      await settle();
      await tester.pump();
    }
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prefs.save')));
    await settle();
    await tester.pump();
    expect(await prefs.viKeys(), isTrue);
  });
}

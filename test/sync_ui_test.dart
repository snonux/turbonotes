import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/home_screen.dart';
import 'package:turbonotes/services/note_store.dart';
import 'package:turbonotes/services/note_sync.dart';
import 'package:turbonotes/services/preferences.dart';
import 'package:turbonotes/services/sync_config.dart';

import 'support/memory_note_store.dart';

void main() {
  Future<void> home(
    WidgetTester tester,
    MemoryNoteStore store,
    Future<SyncResult> Function(NoteStore, SyncConfig) runner, {
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({'flutter.S3SyncEnabled': enabled});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          preferences: PreferencesService(),
          storeFactory: () async => store,
          syncRunner: runner,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> sync(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('disabled sync makes no calls and has no sync menu action', (
    tester,
  ) async {
    var calls = 0;
    await home(tester, MemoryNoteStore({}), (_, _) async {
      calls++;
      return SyncResult();
    }, enabled: false);
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    expect(find.text('Sync now'), findsNothing);
    expect(calls, 0);
  });

  testWidgets(
    'sync saves and closes the editor, blocks shortcuts and refreshes cached notes',
    (tester) async {
      final store = MemoryNoteStore({'note.md': 'before'});
      final gate = Completer<void>();
      var calls = 0;
      await home(tester, store, (notes, _) async {
        calls++;
        expect(await notes.read('note.md'), 'unsaved');
        await gate.future;
        await notes.write('note.md', 'remote #synced');
        await notes.create('new.md', 'new');
        return SyncResult()..notes = 2;
      });
      await tester.tap(find.byKey(const ValueKey('note:note.md')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('note-editor-field'));
      await tester.enterText(field, 'unsaved');
      await sync(tester);
      expect(field, findsNothing);
      expect(find.text('Syncing notes…'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('New note'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const ValueKey('note:new.md')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('note:note.md')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'remote #synced',
      );
    },
  );

  testWidgets(
    'cancelled save conflict aborts sync and leaves edits in the editor',
    (tester) async {
      final store = MemoryNoteStore({'note.md': 'before'});
      var calls = 0;
      await home(tester, store, (_, _) async {
        calls++;
        return SyncResult();
      });
      await tester.tap(find.byKey(const ValueKey('note:note.md')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('note-editor-field'));
      await tester.enterText(field, 'local');
      store.notes['note.md'] = 'other writer';
      await sync(tester);
      expect(find.text('Changed on disk'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.widget<TextField>(field).controller!.text, 'local');
      expect(store.notes['note.md'], 'other writer');
    },
  );

  testWidgets(
    'failed sync reports a safe error and refreshes any partially downloaded notes',
    (tester) async {
      final store = MemoryNoteStore({'note.md': 'before'});
      await home(tester, store, (notes, _) async {
        await notes.create('partial.md', 'kept');
        throw StateError('secret credentials must not appear');
      });
      await sync(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Sync could not finish'), findsOneWidget);
      expect(find.textContaining('secret credentials'), findsNothing);
      expect(find.byKey(const ValueKey('note:partial.md')), findsOneWidget);
      expect(store.notes['note.md'], 'before');
    },
  );
  testWidgets(
    'an unusable note path gives a filename correction instead of a connection error',
    (tester) async {
      await home(tester, MemoryNoteStore({' note.md': 'local'}), (_, _) async {
        throw const UnsyncableNotePathException(' note.md');
      });
      await sync(tester);
      expect(find.textContaining('Sync cannot use " note.md"'), findsOneWidget);
      expect(find.textContaining('Check the connection'), findsNothing);
    },
  );
}

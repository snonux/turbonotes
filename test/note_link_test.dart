import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/home_screen.dart';
import 'package:turbonotes/services/note_link.dart';
import 'package:turbonotes/services/preferences.dart';

import 'support/memory_note_store.dart';

/// Notes other apps ask for (Player's "Note in TurboNotes"), against a fake
/// channel: the Kotlin half (NoteLinks.kt) cannot run off-device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryNoteStore store;
  late StreamController<NoteLink> links;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemoryNoteStore({
      'inbox.md': '# Inbox\n',
      'Book-And-Podcast-Notes/Dune.md': '# Dune\n\nSpice.\n',
    });
    links = StreamController<NoteLink>();
  });

  // Not awaited: without a listener the close never completes.
  tearDown(() {
    links.close();
  });

  Finder field() => find.byKey(const ValueKey('note-editor-field'));

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          preferences: PreferencesService(),
          storeFactory: () async => store,
          links: links.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('links from the channel', () async {
    const channel = MethodChannel('org.buetow.turbonotes/links');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'initialLink') return null;
      return {'path': 'Book-And-Podcast-Notes/Dune.md', 'title': ' Dune\n'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final link = await NoteLink.initial(channel: channel);
    expect(link!.path, 'Book-And-Podcast-Notes/Dune.md');
    expect(link.title, 'Dune');
    expect(NoteLink.fromMap(null), isNull);
    expect(NoteLink.fromMap({'path': ' '}), isNull);
    expect(NoteLink.fromMap({'path': 'a.md', 'title': ''})!.title, isNull);
  });

  testWidgets('a link to a missing note creates it with the title', (
    tester,
  ) async {
    // Arrives before the folder is open, as when it started the app.
    links.add(
      const NoteLink(
        path: 'Book-And-Podcast-Notes/Episode 12_ Rust & Go.md',
        title: 'Episode 12: Rust & Go',
      ),
    );
    await pumpHome(tester);
    expect(
      store.notes['Book-And-Podcast-Notes/Episode 12_ Rust & Go.md'],
      '# Episode 12: Rust & Go\n\n',
    );
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('# Episode 12: Rust & Go\n\n'), findsOneWidget);
  });

  testWidgets('a link to an existing note opens it unchanged', (tester) async {
    await pumpHome(tester);
    links.add(
      const NoteLink(path: 'Book-And-Podcast-Notes/Dune.md', title: 'Other'),
    );
    await tester.pumpAndSettle();
    expect(store.notes['Book-And-Podcast-Notes/Dune.md'], '# Dune\n\nSpice.\n');
    expect(find.text('# Dune\n\nSpice.\n'), findsOneWidget);
  });

  testWidgets('a link saves and closes the note open on a phone', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('note:inbox.md')));
    await tester.pumpAndSettle();
    await tester.enterText(field(), 'edited');
    await tester.pump();
    links.add(const NoteLink(path: 'Book-And-Podcast-Notes/Dune.md'));
    await tester.pumpAndSettle();
    expect(store.notes['inbox.md'], 'edited');
    expect(find.text('# Dune\n\nSpice.\n'), findsOneWidget);
    // Only the linked note's page is open: Back leads to the tree.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('a link opens the note next to the tree on a wide window', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(1200, 800));
    links.add(const NoteLink(path: 'Book-And-Podcast-Notes/New', title: 'N'));
    await tester.pumpAndSettle();
    expect(store.notes['Book-And-Podcast-Notes/New.md'], '# N\n\n');
    expect(find.text('# N\n\n'), findsOneWidget);
  });

  testWidgets('a link outside the notes folder is refused', (tester) async {
    await pumpHome(tester);
    links.add(const NoteLink(path: '../escape.md'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cannot open ../escape.md'), findsOneWidget);
    expect(store.notes.keys, ['inbox.md', 'Book-And-Podcast-Notes/Dune.md']);
  });
}

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/screens/home_screen.dart';
import 'package:turbonotes/services/preferences.dart';
import 'package:turbonotes/services/share_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'inline_image_test.dart' show kPng;
import 'support/memory_note_store.dart';

/// Records what would have been shared instead of touching the system.
class FakeShareService extends ShareService {
  final List<String> texts = [];
  final List<(String, String, int)> files = [];

  @override
  Future<ShareOutcome> shareText(String text, {required String subject}) async {
    texts.add(text);
    return const CopiedToClipboard();
  }

  @override
  Future<ShareOutcome> shareFile(
    Uint8List bytes, {
    required String fileName,
    required String mime,
    required String subject,
  }) async {
    files.add((fileName, mime, bytes.length));
    return SavedFile('/downloads/$fileName');
  }
}

void main() {
  late MemoryNoteStore store;
  late FakeShareService share;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    share = FakeShareService();
    store = MemoryNoteStore({
      'inbox.md': '# Inbox\n\nBuy milk #shopping\n',
      'work/plan.md': '# Plan\n\nShip the release. #work/quicknote\n',
      'work/meeting.md': '# Meeting\n\nTeam meeting notes. #work\n',
    });
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          preferences: PreferencesService(),
          storeFactory: () async => store,
          shareService: share,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field() => find.byKey(const ValueKey('note-editor-field'));
  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(field()).controller!.text;

  Future<void> noteMenu(WidgetTester tester, String key, String item) async {
    await tester.tap(find.byKey(ValueKey(key)), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  testWidgets('opened notes show under Recent, newest first', (tester) async {
    await pumpHome(tester);
    expect(find.text('RECENT'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('note:inbox.md')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder:work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note:work/plan.md')));
    await tester.pumpAndSettle();
    expect(find.text('RECENT'), findsOneWidget);
    final plan = tester.getTopLeft(
      find.byKey(const ValueKey('recent:work/plan.md')),
    );
    final inbox = tester.getTopLeft(
      find.byKey(const ValueKey('recent:inbox.md')),
    );
    expect(plan.dy, lessThan(inbox.dy));
    // Remembered across restarts.
    expect(await PreferencesService().recent(), ['work/plan.md', 'inbox.md']);
  });

  testWidgets('pinning from the note menu adds a Pinned section', (
    tester,
  ) async {
    await pumpHome(tester);
    await noteMenu(tester, 'note:inbox.md', 'Pin');
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.byKey(const ValueKey('pinned:inbox.md')), findsOneWidget);
    expect(await PreferencesService().pinned(), ['inbox.md']);

    await noteMenu(tester, 'pinned:inbox.md', 'Unpin');
    expect(find.text('PINNED'), findsNothing);
  });

  testWidgets('pins follow a rename and go with a delete', (tester) async {
    await pumpHome(tester);
    await noteMenu(tester, 'note:inbox.md', 'Pin');
    await noteMenu(tester, 'note:inbox.md', 'Rename / move');
    await tester.enterText(
      find.byKey(const ValueKey('path-field')),
      'later.md',
    );
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pinned:later.md')), findsOneWidget);

    await noteMenu(tester, 'note:later.md', 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('PINNED'), findsNothing);
    expect(await PreferencesService().pinned(), isEmpty);
  });

  testWidgets('tags list with counts and filter the tree', (tester) async {
    await pumpHome(tester);
    // The Tags section starts folded away, so a large tag list costs
    // nothing at startup.
    expect(find.byKey(const ValueKey('section:tags')), findsOneWidget);
    expect(find.byKey(const ValueKey('tag:shopping')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('section:tags')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tag:shopping')), findsOneWidget);
    expect(find.byKey(const ValueKey('tag:work')), findsOneWidget);
    // Nested tags fold under their parent.
    expect(find.byKey(const ValueKey('tag:work/quicknote')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tag-toggle:work')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tag:work/quicknote')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tag:work')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tag-filter')), findsOneWidget);
    // Filtered folders open by themselves.
    expect(find.byKey(const ValueKey('note:work/plan.md')), findsOneWidget);
    expect(find.byKey(const ValueKey('note:work/meeting.md')), findsOneWidget);
    expect(find.byKey(const ValueKey('note:inbox.md')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tag:work/quicknote')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note:work/meeting.md')), findsNothing);

    await tester.tap(find.byTooltip('Show all notes'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note:inbox.md')), findsOneWidget);
  });

  testWidgets('a saved #tag shows up in the tag list', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('section:tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note:inbox.md')));
    await tester.pumpAndSettle();
    await tester.enterText(field(), '# Inbox\n\n#errands now\n');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('note-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tag:errands')), findsOneWidget);
    expect(find.byKey(const ValueKey('tag:shopping')), findsNothing);
  });

  testWidgets('full-text search forgives typos and selects the match', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('search-text')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('search-query')),
      'relase',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('search-hit:work/plan.md')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-hit:inbox.md')), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    final controller = tester.widget<TextField>(field()).controller!;
    expect(controller.text, startsWith('# Plan'));
    expect(controller.selection.textInside(controller.text), 'release');
  });

  testWidgets('Ctrl+Shift+F opens search; #tags filter it', (tester) async {
    await pumpHome(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('search-query')),
      '#work team',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('search-hit:work/meeting.md')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-hit:work/plan.md')), findsNothing);
  });

  testWidgets('sharing as text hands over the editor\'s current text', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('note:inbox.md')));
    await tester.pumpAndSettle();
    await tester.enterText(field(), '# Inbox\n\nunsaved line\n');
    await tester.pump();
    await noteMenu(tester, 'note:inbox.md', 'Share…');
    await tester.tap(find.byKey(const ValueKey('share:text')));
    await tester.pumpAndSettle();
    expect(share.texts, ['# Inbox\n\nunsaved line\n']);
    expect(find.text('Copied inbox.md to the clipboard'), findsOneWidget);
  });

  testWidgets('sharing as PDF and image renders the note', (tester) async {
    await pumpHome(tester);
    var shared = 0;
    for (final (key, name, mime) in [
      ('share:pdf', 'inbox.pdf', 'application/pdf'),
      ('share:image', 'inbox.png', 'image/png'),
    ]) {
      await noteMenu(tester, 'note:inbox.md', 'Share…');
      await tester.tap(find.byKey(ValueKey(key)));
      // Rendering runs outside the fake clock.
      for (var i = 0; i < 50 && share.files.length == shared; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      shared++;
      await tester.pumpAndSettle();
      expect(share.files.last.$1, name);
      expect(share.files.last.$2, mime);
      expect(share.files.last.$3, greaterThan(100));
      expect(find.text('Saved /downloads/$name'), findsOneWidget);
    }
  });

  testWidgets('pasting an image stores it and links it in the note', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('org.buetow.turbonotes/clipboard'),
      (call) async => {'bytes': kPng, 'mime': 'image/png'},
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? null : null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('org.buetow.turbonotes/clipboard'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('folder:work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note:work/plan.md')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WYSIWYG'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Insert image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clipboard'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    final stored = store.files.keys.single;
    expect(stored, startsWith('work/plan-'));
    expect(store.files[stored], kPng);
    expect(fieldText(tester), contains('![](${stored.substring(5)})'));

    // Ctrl+V with no text on the clipboard pastes the image too.
    await tester.tap(field());
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    // Even within the same second, the second image gets its own file.
    expect(store.files, hasLength(2));
  });

  testWidgets('the gallery and the camera add images in the Raw editor', (
    tester,
  ) async {
    const images = MethodChannel('org.buetow.turbonotes/images');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(images, (
      call,
    ) async {
      calls.add(call.method);
      return switch (call.method) {
        'pickImages' => [
          {'bytes': kPng, 'mime': 'image/png'},
          {'bytes': kPng, 'mime': 'image/jpeg'},
        ],
        _ => {'bytes': kPng, 'mime': 'image/jpeg'},
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        images,
        null,
      ),
    );
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('folder:work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note:work/plan.md')));
    await tester.pumpAndSettle();

    Future<void> insertFrom(String source) async {
      await tester.tap(find.byTooltip('Insert image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(source));
      // Storing and decoding each image runs outside the fake clock.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }
    }

    await insertFrom('Gallery');
    expect(calls, ['pickImages']);
    final picked = store.files.keys.toList()..sort();
    expect(picked, hasLength(2));
    expect(picked.where((p) => p.endsWith('.jpg')), hasLength(1));
    expect(picked.where((p) => p.endsWith('.png')), hasLength(1));
    for (final path in picked) {
      expect(fieldText(tester), contains('![](${path.substring(5)})'));
    }

    await insertFrom('Camera');
    expect(calls, ['pickImages', 'takePhoto']);
    expect(store.files, hasLength(3));
    expect(fieldText(tester).split('![](plan-'), hasLength(4));
  });

  testWidgets('cancelling the camera adds nothing', (tester) async {
    const images = MethodChannel('org.buetow.turbonotes/images');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      images,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        images,
        null,
      ),
    );
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('folder:work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note:work/plan.md')));
    await tester.pumpAndSettle();
    final before = fieldText(tester);
    await tester.tap(find.byTooltip('Insert image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    expect(store.files, isEmpty);
    expect(fieldText(tester), before);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the desktop image button pastes right away', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('folder:work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note:work/plan.md')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Insert image'), findsNothing);
    expect(find.byTooltip('Paste image from clipboard'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/services/player_control.dart';
import 'package:turbonotes/services/preferences.dart';
import 'package:turbonotes/widgets/note_editor.dart';

import 'support/memory_note_store.dart';

void main() {
  const channel = MethodChannel('test/player');
  late List<MethodCall> calls;
  late Map<String, Object?> status;
  late PlayerControl player;

  setUp(() {
    calls = [];
    status = {'access': true, 'player': null};
    player = PlayerControl(channel: channel, supported: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'status' ? status : true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    player.dispose();
  });

  /// Player's session reporting a change, as the Android side does.
  Future<void> report(WidgetTester tester, Object? playerStatus) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('changed', playerStatus),
      ),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteEditor(
            store: MemoryNoteStore({'book.md': '# Book\n'}),
            path: 'book.md',
            initialMode: EditorMode.raw,
            player: player,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('controls stay hidden while Player has no title open', (
    tester,
  ) async {
    await pumpEditor(tester);
    expect(calls.map((c) => c.method), contains('status'));
    expect(find.byKey(const ValueKey('player-bar')), findsNothing);
  });

  testWidgets('controls appear with the title and drive Player', (
    tester,
  ) async {
    status['player'] = {'title': 'Dune, chapter 3', 'playing': true};
    await pumpEditor(tester);
    expect(find.text('Dune, chapter 3'), findsOneWidget);
    expect(find.byTooltip('Pause (Alt+P)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-rewind')));
    await tester.pump();
    expect(calls.last.method, 'rewind');
    expect(calls.last.arguments, {'seconds': 10});

    await tester.tap(find.byKey(const ValueKey('player-play-pause')));
    await tester.pump();
    expect(calls.last.method, 'pause');
    expect(find.byTooltip('Continue (Alt+P)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-play-pause')));
    await tester.pump();
    expect(calls.last.method, 'play');

    // Player closed the title.
    await report(tester, null);
    expect(find.byKey(const ValueKey('player-bar')), findsNothing);
  });

  testWidgets('tapping the controls keeps the keyboard in the note', (
    tester,
  ) async {
    status['player'] = {'title': 'Dune', 'playing': true};
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('note-editor-field')));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('note-editor-field')),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.tap(find.byKey(const ValueKey('player-rewind')));
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('Alt+P and Alt+R work only while a title is open', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('note-editor-field')));
    await tester.pump();
    calls.clear();
    await _alt(tester, LogicalKeyboardKey.keyP);
    expect(calls, isEmpty);

    await report(tester, {'title': 'Dune', 'playing': false});
    await _alt(tester, LogicalKeyboardKey.keyP);
    expect(calls.single.method, 'play');
    await _alt(tester, LogicalKeyboardKey.keyR);
    expect(calls.last.method, 'rewind');
    // Nothing typed into the note.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note-editor-field')))
          .controller!
          .text,
      '# Book\n',
    );
  });

  test('unsupported platforms never call the channel', () async {
    final off = PlayerControl(channel: channel, supported: false);
    off.start();
    await off.refresh();
    await off.rewind();
    expect(calls, isEmpty);
    expect(off.status, isNull);
    off.dispose();
  });

  test('a status without a title counts as nothing open', () {
    expect(PlayerStatus.fromMap({'title': ' ', 'playing': true}), isNull);
    expect(PlayerStatus.fromMap(null), isNull);
    expect(
      PlayerStatus.fromMap({'title': 'Dune', 'playing': true}),
      const PlayerStatus(title: 'Dune', playing: true),
    );
  });
}

Future<void> _alt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
}

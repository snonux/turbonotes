import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/services/note_store.dart';
import 'package:turbonotes/services/saf_note_store.dart';

/// The Dart half of the Android folder store, against a fake channel: the
/// Kotlin half (SafNotes.kt) cannot run off-device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.buetow.turbonotes/saf-notes');
  final calls = <MethodCall>[];
  late Future<Object?> Function(MethodCall call) handler;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return handler(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  final store = SafNoteStore('content://tree/notes', 'Notes');

  test('list keeps notes only, sorted', () async {
    handler = (_) async => ['b.md', 'a/x.markdown', 'c.txt'];
    expect(await store.list(), ['a/x.markdown', 'b.md']);
    expect(calls.single.arguments, {'treeUri': 'content://tree/notes'});
  });

  test('paths are normalized before they reach the provider', () async {
    handler = (_) async => null;
    await store.write('/a\\b', 'text');
    expect(calls.single.method, 'write');
    expect(calls.single.arguments, {
      'treeUri': 'content://tree/notes',
      'path': 'a/b.md',
      'text': 'text',
    });
    expect(
      () => store.read('../x.md'),
      throwsA(isA<InvalidNotePathException>()),
    );
  });

  test(
    'sync replacement sends its expected text and does not fall back to write',
    () async {
      handler = (_) async =>
          throw PlatformException(code: 'io', message: 'Rename unsupported');
      await expectLater(
        store.replaceForSync('a\\b', 'before', 'after'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.single.method, 'replaceForSync');
      expect(calls.single.arguments, {
        'treeUri': 'content://tree/notes',
        'path': 'a/b.md',
        'expected': 'before',
        'text': 'after',
      });
    },
  );

  test('provider errors map to the store exceptions', () async {
    handler = (call) async => throw PlatformException(
      code: call.method == 'read' ? 'not_found' : 'exists',
      message: 'nope',
    );
    expect(store.read('a.md'), throwsA(isA<PathNotFoundException>()));
    expect(
      store.create('a.md', ''),
      throwsA(isA<NoteExistsException>().having((e) => e.path, 'path', 'a.md')),
    );
    expect(
      store.rename('a.md', 'b.md'),
      throwsA(isA<NoteExistsException>().having((e) => e.path, 'path', 'b.md')),
    );
  });

  test('other provider errors pass through', () async {
    handler = (_) async =>
        throw PlatformException(code: 'access_denied', message: 'expired');
    expect(store.list(), throwsA(isA<PlatformException>()));
  });
}

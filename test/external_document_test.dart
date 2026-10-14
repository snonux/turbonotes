import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/external_note_page.dart';
import 'package:turbonotes/services/external_document.dart';
import 'package:turbonotes/services/preferences.dart';

/// Editing a file another app (File Browser) handed over, against a fake
/// channel: the Kotlin half (ExternalDocuments.kt) cannot run off-device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.buetow.turbonotes/external');
  const uri = 'content://org.buetow.filebrowser.edit/edit/1/todo.md';
  final calls = <MethodCall>[];
  late String onDisk;

  setUp(() {
    calls.clear();
    onDisk = '# Todo\n';
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final args = call.arguments as Map?;
          switch (call.method) {
            case 'initialDocument':
              return {'uri': uri, 'name': 'todo.md', 'writable': true};
            case 'read':
              if (args!['uri'] != uri) throw PlatformException(code: 'io');
              return onDisk;
            case 'write':
              if (args!['uri'] != uri) throw PlatformException(code: 'io');
              onDisk = args['text'] as String;
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the document the app was started with', () async {
    final document = await ExternalDocument.initial(channel: channel);
    expect(document!.uri, uri);
    expect(document.name, 'todo.md');
    expect(document.writable, isTrue);
    expect(document.isMarkdown, isTrue);
    expect(ExternalDocument.fromMap(null), isNull);
    expect(ExternalDocument.fromMap({'uri': ''}), isNull);
    expect(
      ExternalDocument.fromMap({'uri': uri, 'name': 'notes.txt'})!.isMarkdown,
      isFalse,
    );
  });

  test('the store reads and writes the one document, nothing else', () async {
    final store = ExternalNoteStore(
      const ExternalDocument(uri: uri, name: 'todo.md', writable: true),
    );
    expect(await store.list(), ['todo.md']);
    expect(await store.read('todo.md'), '# Todo\n');
    await store.write('todo.md', 'done');
    expect(onDisk, 'done');
    expect(() => store.read('other.md'), throwsUnsupportedError);
    expect(
      () => store.create('todo (conflict).md', 'x'),
      throwsUnsupportedError,
    );
  });

  testWidgets('saving writes back, leaving saves and closes', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ExternalNotePage(
          document: const ExternalDocument(
            uri: uri,
            name: 'todo.md',
            writable: true,
          ),
          preferences: PreferencesService(),
          onClose: () => closed++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('todo.md'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '# Todo\n- milk\n');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('note-save')));
    await tester.pumpAndSettle();
    expect(onDisk, '# Todo\n- milk\n');

    await tester.enterText(find.byType(TextField), '# Todo\n- milk\n- eggs\n');
    await tester.pump();
    final pop = tester.state<NavigatorState>(find.byType(Navigator));
    await pop.maybePop();
    await tester.pumpAndSettle();
    expect(onDisk, '# Todo\n- milk\n- eggs\n');
    expect(closed, 1);
  });
}

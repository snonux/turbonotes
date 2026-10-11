import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:turbonotes/services/note_sync.dart';
import 'package:turbonotes/services/note_store.dart';

import 'support/memory_note_store.dart';
import 'support/memory_sync.dart';

void main() {
  late MemorySyncObjects objects;
  late MemoryNoteStore a;
  late MemoryNoteStore b;
  late MemorySyncState stateA;
  late MemorySyncState stateB;
  late NoteSync syncA;
  late NoteSync syncB;

  setUp(() {
    objects = MemorySyncObjects();
    a = MemoryNoteStore({
      'work/note.markdown': 'a\nb\nc\n',
      'inbox.md': '# Inbox\r\n',
    });
    b = MemoryNoteStore({});
    stateA = MemorySyncState();
    stateB = MemorySyncState();
    syncA = NoteSync(store: a, objects: objects, state: stateA);
    syncB = NoteSync(store: b, objects: objects, state: stateB);
  });

  Future<void> seed() async {
    await syncA.run();
    await syncB.run();
  }

  test(
    'uploads all notes, restores another device, and unchanged sync is idempotent',
    () async {
      await seed();
      expect(b.notes, a.notes);
      final writes = objects.writes;
      await syncA.run();
      await syncB.run();
      expect(objects.writes, writes);
      expect(stateA.heads, stateB.heads);
    },
  );

  test('new notes on both devices and missing files are retained', () async {
    await seed();
    a.notes['new.md'] = 'new';
    b.notes['remote.md'] = 'remote';
    a.notes.remove('inbox.md');
    await syncB.run();
    await syncA.run();
    await syncB.run();
    expect(a.notes, b.notes);
    expect(a.notes['inbox.md'], '# Inbox\r\n');
    expect(a.notes['new.md'], 'new');
    expect(a.notes['remote.md'], 'remote');
  });

  test('offline independent edits merge on both devices', () async {
    await seed();
    a.notes['work/note.markdown'] = 'A\nb\nc\n';
    b.notes['work/note.markdown'] = 'a\nb\nC\n';
    await syncA.run();
    expect((await syncB.run()).conflicts, isEmpty);
    await syncA.run();
    expect(a.notes['work/note.markdown'], 'A\nb\nC\n');
    expect(b.notes, a.notes);
  });

  test(
    'unresolved edits keep the local note and sync a never-overwritten conflict copy',
    () async {
      await seed();
      a.notes['work/note.markdown'] = 'remote';
      b.notes['work/note.markdown'] = 'local';
      b.notes['work/note-sync-conflict.md'] = 'existing';
      await syncA.run();
      final result = await syncB.run();
      expect(result.conflicts, ['work/note-2-sync-conflict.md']);
      expect(b.notes['work/note.markdown'], 'local');
      expect(b.notes['work/note-sync-conflict.md'], 'existing');
      expect(b.notes['work/note-2-sync-conflict.md'], 'remote');
      await syncA.run();
      expect(a.notes, b.notes);
      final count = b.notes.length;
      expect((await syncB.run()).conflicts, isEmpty);
      expect(b.notes.length, count);
    },
  );

  test(
    'first sync with divergent pre-existing notes preserves both without an ancestor',
    () async {
      await syncA.run();
      b.notes['work/note.markdown'] = 'unrelated local';
      expect((await syncB.run()).conflicts, ['work/note-sync-conflict.md']);
      expect(b.notes['work/note.markdown'], 'unrelated local');
      expect(b.notes['work/note-sync-conflict.md'], 'a\nb\nc\n');
    },
  );

  test(
    'simultaneous uploads retain both branches and converge on the next sync',
    () async {
      await seed();
      a.notes['work/note.markdown'] = 'A\nb\nc\n';
      b.notes['work/note.markdown'] = 'a\nb\nC\n';
      var waiting = 0;
      final ready = Completer<void>();
      objects.beforeWrite = () async {
        waiting++;
        if (waiting == 2) ready.complete();
        await ready.future;
      };
      await Future.wait([syncA.run(), syncB.run()]);
      objects.beforeWrite = null;
      await syncA.run();
      await syncB.run();
      expect(a.notes['work/note.markdown'], 'A\nb\nC\n');
      expect(b.notes, a.notes);
    },
  );

  test(
    'failed uploads do not advance the note baseline and can be retried',
    () async {
      await seed();
      final previous = Map.of(stateA.heads);
      a.notes['work/note.markdown'] = 'changed';
      objects.beforeWrite = () async => throw const SocketException('offline');
      await expectLater(syncA.run(), throwsA(isA<SocketException>()));
      expect(stateA.heads, previous);
      expect(a.notes['work/note.markdown'], 'changed');
      objects.beforeWrite = null;
      await syncA.run();
      await syncB.run();
      expect(b.notes['work/note.markdown'], 'changed');
    },
  );

  test('failed checkpoint can retry without losing the merged text', () async {
    await seed();
    a.notes['work/note.markdown'] = 'A\nb\nc\n';
    b.notes['work/note.markdown'] = 'a\nb\nC\n';
    await syncA.run();
    stateB.failSave = true;
    await expectLater(syncB.run(), throwsStateError);
    stateB.failSave = false;
    await syncB.run();
    await syncA.run();
    expect(a.notes['work/note.markdown'], 'A\nb\nC\n');
    expect(b.notes, a.notes);
  });

  test('a local edit during upload is never overwritten', () async {
    await seed();
    a.notes['work/note.markdown'] = 'a\nb\nC\n';
    b.notes['work/note.markdown'] = 'A\nb\nc\n';
    await syncA.run();
    objects.beforeWrite = () async {
      b.notes['work/note.markdown'] = 'late edit';
    };
    await expectLater(syncB.run(), throwsA(isA<FileSystemException>()));
    expect(b.notes['work/note.markdown'], 'late edit');
  });

  test(
    'damaged data, invalid paths, and lost history fail without touching notes',
    () async {
      await seed();
      final key = objects.data.keys.first;
      final valid = objects.data[key]!;
      objects.data[key] = utf8.encode('broken');
      final notes = Map.of(b.notes);
      await expectLater(syncB.run(), throwsFormatException);
      expect(b.notes, notes);
      objects.data[key] = valid;
      final invalid = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(valid)) as Map,
      );
      invalid['path'] = '../escape.md';
      final bytes = utf8.encode(jsonEncode(invalid));
      final invalidKey =
          '$kSyncPrefix${sha256.convert(utf8.encode('../escape.md'))}/${sha256.convert(bytes)}.json';
      objects.data[invalidKey] = bytes;
      await expectLater(syncB.run(), throwsA(isA<InvalidNotePathException>()));
      objects.data.remove(invalidKey);
      objects.data.clear();
      await expectLater(syncB.run(), throwsFormatException);
      expect(b.notes, notes);
    },
  );

  test('a sync instance refuses overlapping runs', () async {
    final gate = Completer<void>();
    objects.afterList = () => gate.future;
    final first = syncA.run();
    await expectLater(syncA.run(), throwsStateError);
    gate.complete();
    await first;
  });

  test(
    'a parent absent from a paginated listing is fetched by its immutable key',
    () async {
      await seed();
      final roots = objects.data.keys.toSet();
      a.notes['work/note.markdown'] = 'new head';
      await syncA.run();
      objects.omitFromList.addAll(roots);
      // The untouched Inbox has no listed head, so keep its root in the listing.
      objects.omitFromList.removeWhere(
        (key) =>
            (jsonDecode(utf8.decode(objects.data[key]!)) as Map)['path'] ==
            'inbox.md',
      );
      await syncB.run();
      expect(b.notes['work/note.markdown'], 'new head');
    },
  );

  test(
    'retrying a failed conflict upload reuses the copy and preserves both versions',
    () async {
      await seed();
      a.notes['work/note.markdown'] = 'remote';
      b.notes['work/note.markdown'] = 'local';
      await syncA.run();
      var writes = 0;
      objects.beforeWrite = () async {
        if (++writes == 2) {
          throw const SocketException('conflict upload failed');
        }
      };
      await expectLater(syncB.run(), throwsA(isA<SocketException>()));
      expect(b.notes['work/note.markdown'], 'local');
      expect(b.notes['work/note-sync-conflict.md'], 'remote');
      objects.beforeWrite = null;
      await syncB.run();
      await syncA.run();
      expect(a.notes, b.notes);
      expect(
        b.notes.keys.where((path) => path.endsWith('-sync-conflict.md')).length,
        1,
      );
    },
  );

  test(
    'oversized revisions are refused without advancing their baseline',
    () async {
      await seed();
      final previous = Map.of(stateA.heads);
      a.notes['work/note.markdown'] = 'x' * (8 * 1024 * 1024);
      await expectLater(syncA.run(), throwsA(isA<FileSystemException>()));
      expect(stateA.heads, previous);
      expect(a.notes['work/note.markdown']!.length, 8 * 1024 * 1024);
    },
  );
  test('deep Unicode paths use bounded keys and restore exactly', () async {
    final path = '${List.filled(4, 'ü' * 90).join('/')}.md';
    a.notes[path] = 'deep note';
    await seed();
    expect(b.notes[path], 'deep note');
    expect(
      objects.data.keys.every((key) => utf8.encode(key).length < 1024),
      isTrue,
    );
  });
}

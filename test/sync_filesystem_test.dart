import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/services/directory_note_store.dart';
import 'package:turbonotes/services/note_store.dart';
import 'package:turbonotes/services/note_sync.dart';

import 'support/memory_sync.dart';

class _LateWriterStore extends DirectoryNoteStore {
  _LateWriterStore(super.root);
  bool inject = false;

  @override
  Future<void> replaceForSync(String path, String expected, String text) async {
    if (inject) {
      inject = false;
      await File('$root/$path').writeAsString('native capture');
    }
    await super.replaceForSync(path, expected, text);
  }
}

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('sync-races-'),
  );
  tearDown(() => root.delete(recursive: true));

  test(
    'a native edit at replacement entry stops sync and survives retry',
    () async {
      final a = DirectoryNoteStore('${root.path}/a');
      final b = _LateWriterStore('${root.path}/b');
      await Directory(a.root).create();
      await Directory(b.root).create();
      await a.create('note.md', 'original');
      final objects = MemorySyncObjects();
      final stateA = MemorySyncState();
      final stateB = MemorySyncState();
      final syncA = NoteSync(store: a, objects: objects, state: stateA);
      final syncB = NoteSync(store: b, objects: objects, state: stateB);
      await syncA.run();
      await syncB.run();
      await a.write('note.md', 'remote');
      await syncA.run();
      b.inject = true;
      final baseline = Map.of(stateB.heads);
      await expectLater(syncB.run(), throwsA(isA<FileSystemException>()));
      expect(await b.read('note.md'), 'native capture');
      expect(stateB.heads, baseline);
      await syncB.run();
      expect(await b.read('note.md'), 'native capture');
      expect(await b.read('note-sync-conflict.md'), 'remote');
    },
  );

  test(
    'replacement preserves edits through an already-open descriptor',
    () async {
      final store = DirectoryNoteStore(root.path);
      await store.create('note.md', 'before');
      final writer = await File(
        '${root.path}/note.md',
      ).open(mode: FileMode.append);
      try {
        await store.replaceForSync('note.md', 'before', 'remote');
        await writer.writeString(' native capture');
        await writer.flush();
        expect(await store.read('note.md'), 'remote');
        final backup = root.listSync().whereType<File>().singleWhere(
          (file) => file.path.contains('.turbonotes-sync-backup-'),
        );
        expect(await backup.readAsString(), 'before native capture');
        expect(await store.list(), ['note.md']);
      } finally {
        await writer.close();
      }
    },
  );

  test(
    'remote restoration rejects symlink parents without touching outside files',
    () async {
      final a = DirectoryNoteStore('${root.path}/a');
      final b = DirectoryNoteStore('${root.path}/b');
      final outside = Directory('${root.path}/outside');
      await Directory(a.root).create();
      await Directory(b.root).create();
      await outside.create();
      await Link('${b.root}/sub').create(outside.path);
      await a.create('sub/restore.md', 'remote');
      final objects = MemorySyncObjects();
      await NoteSync(
        store: a,
        objects: objects,
        state: MemorySyncState(),
      ).run();
      await expectLater(
        NoteSync(store: b, objects: objects, state: MemorySyncState()).run(),
        throwsA(isA<InvalidNotePathException>()),
      );
      expect(outside.listSync(), isEmpty);
      expect(await b.list(), isEmpty);
    },
  );
  for (final basename in ['${'x' * 250}.md', '${'ü' * 125}.md']) {
    test(
      'long filename conflicts retain their suffix within the byte limit (${basename.substring(0, 1)})',
      () async {
        final path = basename;
        final a = DirectoryNoteStore('${root.path}/a');
        final b = DirectoryNoteStore('${root.path}/b');
        await Directory(a.root).create();
        await Directory(b.root).create();
        await a.create(path, 'original');
        final objects = MemorySyncObjects();
        final syncA = NoteSync(
          store: a,
          objects: objects,
          state: MemorySyncState(),
        );
        final syncB = NoteSync(
          store: b,
          objects: objects,
          state: MemorySyncState(),
        );
        await syncA.run();
        await syncB.run();
        for (var i = 1; i <= 2; i++) {
          // Model edits by other tools; the older editor temp-file naming limit
          // is separate from sync's incoming writes and conflict creation.
          await File('${a.root}/$path').writeAsString('remote $i');
          await File('${b.root}/$path').writeAsString('local $i');
          await syncA.run();
          final result = await syncB.run();
          final copy = result.conflicts.single;
          expect(utf8.encode(copy).length, lessThanOrEqualTo(255));
          expect(copy, endsWith('-sync-conflict.md'));
          expect(await b.read(copy), 'remote $i');
          expect(await b.read(path), 'local $i');
          await syncA.run();
          expect(await a.read(copy), 'remote $i');
          expect(await a.read(path), 'local $i');
        }
        final copies = (await b.list()).where(
          (name) => name.endsWith('-sync-conflict.md'),
        );
        expect(copies.length, 2);
        expect(await b.read(copies.first), isIn(['remote 1', 'remote 2']));
      },
    );
  }
  test(
    'noncanonical filesystem names are rejected before any publication',
    () async {
      final store = DirectoryNoteStore(root.path);
      final canonical = File('${root.path}/note.md');
      final spaced = File('${root.path}/ note.md');
      await canonical.writeAsString('canonical note');
      await spaced.writeAsString('spaced note');
      final objects = MemorySyncObjects();
      final state = MemorySyncState();
      final sync = NoteSync(store: store, objects: objects, state: state);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          sync.run(),
          throwsA(isA<UnsyncableNotePathException>()),
        );
        expect(objects.data, isEmpty);
        expect(state.heads, isEmpty);
        expect(await canonical.readAsString(), 'canonical note');
        expect(await spaced.readAsString(), 'spaced note');
      }
      await spaced.rename('${root.path}/spaced.md');
      await sync.run();
      expect(objects.data.length, 2);
    },
  );
}

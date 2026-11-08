// Startup benchmark on a large generated notes folder. Not part of the
// regular suite: run with `flutter test tool/startup_bench_test.dart`.
// NOTES=20000 TAGS=3000 pick the size.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/services/directory_note_store.dart';
import 'package:turbonotes/services/index_cache.dart';
import 'package:turbonotes/services/note_index.dart';
import 'package:turbonotes/services/note_tree.dart';

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

/// Writes [count] notes in nested folders, each with a few of [tagCount]
/// nested tags and a couple of KB of text.
Future<Directory> generateFolder(int count, int tagCount) async {
  final root = await Directory.systemTemp.createTemp('turbonotes-bench');
  final random = Random(42);
  final tags = [
    for (var i = 0; i < tagCount; i++)
      i % 3 == 0 ? 'topic$i' : 'area${i % 40}/sub$i',
  ];
  const words =
      'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod '
      'tempor incididunt ut labore et dolore magna aliqua enim minim veniam';
  final vocabulary = words.split(' ');
  for (var i = 0; i < count; i++) {
    final folder = 'f${i % 60}/g${i % 7}';
    final dir = Directory('${root.path}/$folder');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final b = StringBuffer('# Note $i\n\n');
    for (var t = 0; t < 5; t++) {
      b.write('#${tags[random.nextInt(tags.length)]} ');
    }
    b.writeln();
    for (var l = 0; l < 30; l++) {
      for (var w = 0; w < 10; w++) {
        b
          ..write(vocabulary[random.nextInt(vocabulary.length)])
          ..write(random.nextInt(1000))
          ..write(' ');
      }
      b.writeln();
    }
    File('${dir.path}/note$i.md').writeAsStringSync(b.toString());
  }
  return root;
}

void main() {
  test('startup phases', () async {
    final count = _env('NOTES', 5000);
    final root = await generateFolder(count, _env('TAGS', 1000));
    addTearDown(() => root.delete(recursive: true));
    final store = DirectoryNoteStore(root.path);
    final sw = Stopwatch()..start();
    void lap(String what) {
      // ignore: avoid_print
      print('${what.padRight(28)} ${sw.elapsedMilliseconds} ms');
      sw.reset();
    }

    final versions = await store.listVersions();
    final paths = versions.keys.toList()..sort();
    lap('scan ($count notes)');
    NoteFolder.build(paths).folders;
    lap('note tree');
    final index = await NoteIndex.load(store, paths, versions: versions);
    lap('index (cold)');
    index.hasTags;
    lap('hasTags');
    index.tagTree.children;
    lap('tag tree');
    index.notesTagged('area1');
    lap('notesTagged');
    index.vocabulary;
    lap('vocabulary');
    await NoteIndex.load(store, paths, versions: versions, previous: index);
    lap('index (refresh)');

    final support = await Directory.systemTemp.createTemp('turbonotes-bsup');
    addTearDown(() => support.delete(recursive: true));
    final cache = FileIndexCache(directory: () async => support);
    await cache.save(root.path, index);
    lap('cache save');
    final ui = Stopwatch()..start();
    final cached = cache.load(root.path);
    final uiMs = ui.elapsedMilliseconds;
    final loaded = await cached;
    lap('cache load (UI part $uiMs ms)');
    final warm = await NoteIndex.load(
      store,
      paths,
      versions: versions,
      previous: loaded,
    );
    lap('index from cache (${warm.changes} read)');
    warm.vocabulary;
    lap('vocabulary (carried)');
    // ignore: avoid_print
    print(
      'cache file ${File('${support.path}/index/notes.bin').lengthSync() ~/ 1024} KB',
    );
  }, timeout: Timeout.none);
}

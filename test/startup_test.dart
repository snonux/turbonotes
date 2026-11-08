import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/screens/home_screen.dart';
import 'package:turbonotes/services/directory_note_store.dart';
import 'package:turbonotes/services/index_cache.dart';
import 'package:turbonotes/services/listing_cache.dart';
import 'package:turbonotes/services/note_index.dart';
import 'package:turbonotes/services/note_store.dart';
import 'package:turbonotes/services/preferences.dart';

import 'support/memory_note_store.dart';

/// What makes a start quick on a large folder: a cached listing, a scan
/// and index built off the UI isolate, and refreshes that only read what
/// changed.
void main() {
  group('DirectoryNoteStore versions', () {
    late Directory root;
    late DirectoryNoteStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('turbonotes-versions');
      store = DirectoryNoteStore(root.path);
      await Directory('${root.path}/a/.hidden').create(recursive: true);
      await File('${root.path}/one.md').writeAsString('one #tag');
      await File('${root.path}/a/two.md').writeAsString('two');
      await File('${root.path}/a/.hidden/x.md').writeAsString('hidden');
      await File('${root.path}/a/pic.png').writeAsBytes([1, 2, 3]);
    });

    tearDown(() => root.delete(recursive: true));

    test('lists notes with a version that changes with the note', () async {
      final before = await store.listVersions();
      expect(before.keys.toSet(), {'one.md', 'a/two.md'});
      await File('${root.path}/a/two.md').writeAsString('two, longer');
      final after = await store.listVersions();
      expect(after['one.md'], before['one.md']);
      expect(after['a/two.md'], isNot(before['a/two.md']));
    });

    test('a missing folder fails the listing', () {
      expect(
        DirectoryNoteStore('${root.path}/missing').listVersions(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('readMany reads in order, null for what is unreadable', () async {
      expect(await store.readMany(['a/two.md', 'gone.md', 'one.md']), [
        'two',
        null,
        'one #tag',
      ]);
    });

    test('the index is read in the background and refreshed '
        'by reading only changed notes', () async {
      var versions = await store.listVersions();
      final first = await NoteIndex.load(
        store,
        versions.keys.toList()..sort(),
        versions: versions,
      );
      expect(first.paths.toList(), ['a/two.md', 'one.md']);
      expect(first.tagsOf('one.md'), {'tag'});

      await File('${root.path}/a/two.md').writeAsString('two #new');
      versions = await store.listVersions();
      final second = await NoteIndex.load(
        store,
        versions.keys.toList()..sort(),
        versions: versions,
        previous: first,
      );
      // Unchanged: the very same entry, not read again.
      expect(identical(second['one.md'], first['one.md']), isTrue);
      expect(second['a/two.md']!.text, 'two #new');
      expect(second.tagsOf('a/two.md'), {'new'});
    });
  });

  test('the vocabulary follows saves, renames and deletes', () {
    final index = NoteIndex({'a.md': 'apple banana', 'b.md': 'banana'});
    expect(index.vocabulary['banana'], 2);
    index.put('a.md', 'cherry');
    index.rename('b.md', 'c.md');
    index.put('d.md', 'apple');
    index.remove('d.md');
    final fresh = NoteIndex({'a.md': 'cherry', 'c.md': 'banana'});
    expect(index.vocabulary, fresh.vocabulary);
  });

  test('a refresh carries the vocabulary over, changed where notes '
      'changed', () async {
    final store = MemoryNoteStore({'a.md': 'apple', 'b.md': 'banana'});
    final first = await NoteIndex.load(
      store,
      ['a.md', 'b.md'],
      versions: {'a.md': '1', 'b.md': '1'},
    );
    first.vocabulary;
    store.notes['b.md'] = 'cherry';
    store.notes['c.md'] = 'apple';
    final second = await NoteIndex.load(
      store,
      ['b.md', 'c.md'],
      versions: {'b.md': '2', 'c.md': '1'},
      previous: first,
    );
    // b.md read again, c.md new, a.md gone.
    expect(second.changes, 3);
    expect(second.vocabulary, {'cherry': 1, 'apple': 1});
  });

  group('FileIndexCache', () {
    late Directory dir;
    late Directory notes;
    late FileIndexCache cache;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('turbonotes-index');
      notes = await Directory.systemTemp.createTemp('turbonotes-notes');
      cache = FileIndexCache(directory: () async => dir);
      await File('${notes.path}/one.md').writeAsString('one #tag café');
      await Directory('${notes.path}/a').create();
      await File('${notes.path}/a/two.md').writeAsString('two #other/sub');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
      await notes.delete(recursive: true);
    });

    Future<NoteIndex> read(NoteStore store, {NoteIndex? previous}) async {
      final versions = await (store as DirectoryNoteStore).listVersions();
      return NoteIndex.load(
        store,
        versions.keys.toList()..sort(),
        versions: versions,
        previous: previous,
      );
    }

    test('keeps the index of the folder last saved', () async {
      final store = DirectoryNoteStore(notes.path);
      final index = await read(store);
      expect(await cache.load(notes.path), isNull);
      await cache.save(notes.path, index);
      final loaded = (await cache.load(notes.path))!;
      expect(loaded.paths.toList(), ['a/two.md', 'one.md']);
      expect(loaded['one.md']!.text, 'one #tag café');
      expect(loaded['one.md']!.version, index['one.md']!.version);
      expect(loaded.tagsOf('a/two.md'), {'other/sub'});
      expect(loaded.vocabulary, index.vocabulary);
      // Only one folder is kept.
      await cache.save('/other', NoteIndex({'x.md': 'x'}));
      expect(await cache.load(notes.path), isNull);
    });

    test('a start from the cache reads only notes changed since', () async {
      final store = DirectoryNoteStore(notes.path);
      await cache.save(notes.path, await read(store));
      // A different size, so a different version even within one second.
      await File('${notes.path}/a/two.md').writeAsString('two, #edited');
      final cached = (await cache.load(notes.path))!;
      final index = await read(store, previous: cached);
      expect(index.changes, 1);
      expect(identical(index['one.md'], cached['one.md']), isTrue);
      expect(index.tagsOf('a/two.md'), {'edited'});
      final fresh = await NoteIndex.prepared({
        'a/two.md': 'two, #edited',
        'one.md': 'one #tag café',
      }, const {});
      expect(index.vocabulary, fresh.vocabulary);
    });

    test('notes saved in the app are read again on the next start', () async {
      final store = DirectoryNoteStore(notes.path);
      final index = await read(store);
      index.put('one.md', 'one, edited here');
      await cache.save(notes.path, index);
      final cached = (await cache.load(notes.path))!;
      expect(cached['one.md']!.version, isNull);
      expect((await read(store, previous: cached)).changes, 1);
    });

    test('a broken file is no cache', () async {
      await cache.save(notes.path, NoteIndex({'a.md': 'a'}));
      final file = dir.listSync(recursive: true).whereType<File>().single;
      file.writeAsBytesSync(file.readAsBytesSync().sublist(0, 20));
      expect(await cache.load(notes.path), isNull);
      file.writeAsStringSync('garbage');
      expect(await cache.load(notes.path), isNull);
    });
  });

  group('FileListingCache', () {
    late Directory dir;
    late FileListingCache cache;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('turbonotes-cache');
      cache = FileListingCache(directory: () async => dir);
    });

    tearDown(() => dir.delete(recursive: true));

    test('keeps a listing per folder', () async {
      expect(await cache.load('/notes'), isNull);
      await cache.save('/notes', ['a.md', 'b/c.md']);
      await cache.save('/other', ['x.md']);
      expect(await cache.load('/notes'), ['a.md', 'b/c.md']);
      expect(await cache.load('/other'), ['x.md']);
    });

    test('a broken file is no cache', () async {
      await cache.save('/notes', ['a.md']);
      final file = dir.listSync(recursive: true).whereType<File>().single;
      file.writeAsStringSync('{not json');
      expect(await cache.load('/notes'), isNull);
    });
  });

  testWidgets('the last listing shows while the folder is listed again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = MemoryNoteStore({'new.md': 'new', 'old.md': 'old'})
      ..listDelay = const Duration(seconds: 1);
    final cache = _MemoryListingCache({
      '/notes': ['old.md', 'gone.md'],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          preferences: PreferencesService(),
          storeFactory: () async => store,
          listingCache: cache,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('note:old.md')), findsOneWidget);
    expect(find.byKey(const ValueKey('note:gone.md')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note:new.md')), findsOneWidget);
    expect(find.byKey(const ValueKey('note:gone.md')), findsNothing);
    expect(cache.saved['/notes'], ['new.md', 'old.md']);
  });
}

class _MemoryListingCache implements ListingCache {
  _MemoryListingCache(this.saved);

  final Map<String, List<String>> saved;

  @override
  Future<List<String>?> load(String folder) async => saved[folder];

  @override
  Future<void> save(String folder, List<String> paths) async =>
      saved[folder] = paths;
}

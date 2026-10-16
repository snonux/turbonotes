import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'note_store.dart';
import 'tags.dart';

/// Lower-cases [s] one character at a time, so offsets into the result are
/// offsets into [s] (a plain toLowerCase can grow the string: `İ` -> `i̇`).
String foldCase(String s) {
  final lower = s.toLowerCase();
  if (lower.length == s.length) return lower;
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final l = s[i].toLowerCase();
    b.write(l.length == 1 ? l : s[i]);
  }
  return b.toString();
}

final RegExp _word = RegExp(r'[\p{L}\p{N}_]+', unicode: true);

/// One note's text plus what search and the tag tree need from it, computed
/// on first use (or up front by [NoteIndex.load], off the UI isolate).
class IndexedNote {
  IndexedNote(this.text, {this.version});

  final String text;

  /// The store's version of the note when [text] was read (see
  /// [VersionedNoteStore.listVersions]); null when unknown, e.g. after a
  /// save from within the app, so the next refresh reads it again.
  final String? version;

  late final String folded = foldCase(text);
  late final Set<String> tags = extractTags(text);
  late final Set<String> words = {
    for (final m in _word.allMatches(folded)) m[0]!,
  };

  /// Computes everything up front, so a background isolate does the work
  /// and hands over the results instead of the UI isolate doing it later.
  IndexedNote _prepared() {
    folded;
    tags;
    words;
    return this;
  }
}

/// The text of every note, kept in memory for full-text search and tags.
/// Built once per folder load, then kept current as notes are saved,
/// created, renamed and deleted from within the app.
class NoteIndex {
  NoteIndex([Map<String, String> texts = const {}])
    : _notes = {for (final e in texts.entries) e.key: IndexedNote(e.value)};

  NoteIndex._(this._notes);

  final Map<String, IndexedNote> _notes;
  TagNode? _tagTree;
  Map<String, Set<String>>? _vocabulary;

  /// Indexes every note in [paths]. A note that cannot be read is left out
  /// rather than failing the whole index.
  ///
  /// With [versions] (from [VersionedNoteStore.listVersions]), notes of
  /// [previous] whose version did not change are kept instead of read
  /// again, so a refresh, e.g. each time the app comes back to the
  /// foreground, only reads what changed. A [VersionedNoteStore] is read on
  /// a background isolate, which also parses tags and words there: on a
  /// large folder that work would otherwise freeze the UI for seconds.
  static Future<NoteIndex> load(
    NoteStore store,
    List<String> paths, {
    Map<String, String>? versions,
    NoteIndex? previous,
  }) async {
    final notes = <String, IndexedNote>{};
    final stale = <String>[];
    for (final path in paths) {
      final old = previous?._notes[path];
      final version = versions?[path];
      if (old != null && version != null && old.version == version) {
        notes[path] = old;
      } else {
        stale.add(path);
      }
    }
    if (stale.isNotEmpty) {
      final read = store is VersionedNoteStore
          ? await _readInBackground(store, stale, versions)
          : await _readHere(store, stale, versions);
      notes.addAll(read);
    }
    // In the order of [paths], like a fresh index.
    return NoteIndex._({
      for (final path in paths)
        if (notes.containsKey(path)) path: notes[path]!,
    });
  }

  /// Reads [paths] from a store without background support, a few at a
  /// time.
  static Future<Map<String, IndexedNote>> _readHere(
    NoteStore store,
    List<String> paths,
    Map<String, String>? versions, {
    int parallel = 8,
  }) async {
    final notes = <String, IndexedNote>{};
    var next = 0;
    Future<void> worker() async {
      while (next < paths.length) {
        final path = paths[next++];
        try {
          notes[path] = IndexedNote(
            await store.read(path),
            version: versions?[path],
          );
        } catch (_) {
          // Unreadable notes are simply not searchable.
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    return notes;
  }

  /// Whether any note carries a tag, without building the [tagTree].
  bool get hasTags => _hasTags ??= _notes.values.any((n) => n.tags.isNotEmpty);
  bool? _hasTags;

  Iterable<String> get paths => _notes.keys;

  IndexedNote? operator [](String path) => _notes[path];

  void put(String path, String text) {
    final old = _notes[path];
    if (old?.text == text) return;
    final note = IndexedNote(text);
    _notes[path] = note;
    _forgetWords(path, old);
    _addWords(path, note);
    _tagTree = null;
    _hasTags = null;
  }

  void remove(String path) {
    final old = _notes.remove(path);
    if (old == null) return;
    _forgetWords(path, old);
    _tagTree = null;
    _hasTags = null;
  }

  void rename(String from, String to) {
    final note = _notes.remove(from);
    if (note == null) return;
    _forgetWords(from, note);
    _notes[to] = note;
    _addWords(to, note);
    _tagTree = null;
    _hasTags = null;
  }

  // The vocabulary is kept current word by word: rebuilding it from every
  // note after each autosave would stall the next typo-tolerant search.
  void _forgetWords(String path, IndexedNote? note) {
    final vocabulary = _vocabulary;
    if (vocabulary == null || note == null) return;
    for (final w in note.words) {
      final paths = vocabulary[w];
      if (paths == null) continue;
      paths.remove(path);
      if (paths.isEmpty) vocabulary.remove(w);
    }
  }

  void _addWords(String path, IndexedNote note) {
    final vocabulary = _vocabulary;
    if (vocabulary == null) return;
    for (final w in note.words) {
      (vocabulary[w] ??= {}).add(path);
    }
  }

  Set<String> tagsOf(String path) => _notes[path]?.tags ?? const {};

  TagNode get tagTree => _tagTree ??= TagNode.build({
    for (final e in _notes.entries) e.key: e.value.tags,
  });

  /// Notes tagged [filter] or a tag nested below it.
  Set<String> notesTagged(String filter) => {
    for (final e in _notes.entries)
      if (e.value.tags.any((t) => tagMatches(t, filter))) e.key,
  };

  /// Every distinct word in any note, with the notes it occurs in.
  Map<String, Set<String>> get vocabulary {
    final cached = _vocabulary;
    if (cached != null) return cached;
    final vocabulary = <String, Set<String>>{};
    _notes.forEach((path, note) {
      for (final w in note.words) {
        (vocabulary[w] ??= {}).add(path);
      }
    });
    return _vocabulary = vocabulary;
  }
}

/// Reads [paths] from [store] on background isolates, a share each, and
/// prepares each note there. Top-level, so the isolates' closures capture
/// nothing else.
Future<Map<String, IndexedNote>> _readInBackground(
  VersionedNoteStore store,
  List<String> paths,
  Map<String, String>? versions,
) async {
  // Lets a store that talks to the platform (SAF) use its channel there.
  final token = RootIsolateToken.instance;
  // Phones have several cores; a few isolates read and parse in parallel.
  // Small batches are not worth starting more than one.
  final isolates = (paths.length ~/ 250).clamp(
    1,
    (Platform.numberOfProcessors - 1).clamp(1, 4),
  );
  final size = (paths.length / isolates).ceil();
  final shares = await Future.wait([
    for (var start = 0; start < paths.length; start += size)
      _readShare(store, token, {
        for (final path in paths.skip(start).take(size)) path: versions?[path],
      }),
  ]);
  return {for (final share in shares) ...share};
}

Future<Map<String, IndexedNote>> _readShare(
  VersionedNoteStore store,
  RootIsolateToken? token,
  Map<String, String?> wanted,
) => Isolate.run(() async {
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  final paths = wanted.keys.toList();
  final texts = await store.readMany(paths);
  return {
    for (var i = 0; i < paths.length; i++)
      if (texts[i] case final text?)
        paths[i]: IndexedNote(text, version: wanted[paths[i]])._prepared(),
  };
});

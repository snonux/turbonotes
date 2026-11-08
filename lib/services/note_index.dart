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

  /// An index of [texts] read at [versions] (an empty version counts as
  /// unknown), with every note's tags and words worked out and the
  /// vocabulary built, a share of the notes on each of a few isolates. For
  /// a background isolate, which then hands the finished index to the UI
  /// isolate without a copy (see [IndexCache]).
  static Future<NoteIndex> prepared(
    Map<String, String> texts,
    Map<String, String> versions,
  ) async {
    final paths = texts.keys.toList();
    final workers = _workers(paths.length);
    final size = (paths.length / workers).ceil();
    final shares = await Future.wait([
      for (var start = 0; start < paths.length; start += size)
        _prepareShare({
          for (final path in paths.skip(start).take(size))
            path: (texts[path]!, versions[path] ?? ''),
        }),
    ]);
    final notes = <String, IndexedNote>{
      for (final (share, _) in shares) ...share,
    };
    // The largest share's vocabulary is the base; the others add to it.
    final vocabularies = [for (final (_, words) in shares) words]
      ..sort((a, b) => b.length.compareTo(a.length));
    final vocabulary = vocabularies.isEmpty
        ? <String, int>{}
        : vocabularies.first;
    for (final other in vocabularies.skip(1)) {
      other.forEach((w, n) => vocabulary[w] = (vocabulary[w] ?? 0) + n);
    }
    return NoteIndex._({for (final path in paths) path: ?notes[path]})
      .._vocabulary = vocabulary;
  }

  final Map<String, IndexedNote> _notes;
  TagNode? _tagTree;

  /// Every word with the number of notes it occurs in.
  Map<String, int>? _vocabulary;

  /// How many notes the [load] that made this index read or dropped; 0
  /// when it kept the previous index as it was.
  int changes = 0;

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
    final index = NoteIndex._({
      for (final path in paths)
        if (notes.containsKey(path)) path: notes[path]!,
    });
    final old = previous?._notes ?? const <String, IndexedNote>{};
    index.changes =
        stale.length +
        old.keys.where((p) => !index._notes.containsKey(p)).length;
    index._carryVocabulary(previous);
    return index;
  }

  /// Takes over [previous]'s vocabulary, changed only for the notes that
  /// differ, instead of building it again from every note on the next
  /// typo-tolerant search.
  void _carryVocabulary(NoteIndex? previous) {
    final old = previous?._vocabulary;
    if (old == null) return;
    _vocabulary = Map.of(old);
    previous!._notes.forEach((path, note) {
      if (!identical(_notes[path], note)) _forgetWords(path, note);
    });
    _notes.forEach((path, note) {
      if (!identical(previous._notes[path], note)) _addWords(path, note);
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
      final count = vocabulary[w];
      if (count == null) continue;
      if (count <= 1) {
        vocabulary.remove(w);
      } else {
        vocabulary[w] = count - 1;
      }
    }
  }

  void _addWords(String path, IndexedNote note) {
    final vocabulary = _vocabulary;
    if (vocabulary == null) return;
    for (final w in note.words) {
      vocabulary[w] = (vocabulary[w] ?? 0) + 1;
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

  /// Every distinct word in any note, with the number of notes it occurs
  /// in.
  Map<String, int> get vocabulary {
    final cached = _vocabulary;
    if (cached != null) return cached;
    final vocabulary = <String, int>{};
    for (final note in _notes.values) {
      for (final w in note.words) {
        vocabulary[w] = (vocabulary[w] ?? 0) + 1;
      }
    }
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
  final isolates = _workers(paths.length);
  final size = (paths.length / isolates).ceil();
  final shares = await Future.wait([
    for (var start = 0; start < paths.length; start += size)
      _readShare(store, token, {
        for (final path in paths.skip(start).take(size)) path: versions?[path],
      }),
  ]);
  return {for (final share in shares) ...share};
}

/// Isolates to read or prepare [notes] notes on: phones have several cores,
/// so a few work in parallel; small batches are not worth more than one.
int _workers(int notes) =>
    (notes ~/ 250).clamp(1, (Platform.numberOfProcessors - 1).clamp(1, 4));

/// Prepares one share of [NoteIndex.prepared] on its own isolate, with the
/// share's vocabulary. Top-level, so the closure captures only [share].
Future<(Map<String, IndexedNote>, Map<String, int>)> _prepareShare(
  Map<String, (String, String)> share,
) => Isolate.run(() {
  final notes = <String, IndexedNote>{};
  final vocabulary = <String, int>{};
  share.forEach((path, entry) {
    final (text, version) = entry;
    final note = IndexedNote(
      text,
      version: version.isEmpty ? null : version,
    )._prepared();
    notes[path] = note;
    for (final w in note.words) {
      vocabulary[w] = (vocabulary[w] ?? 0) + 1;
    }
  });
  return (notes, vocabulary);
});

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

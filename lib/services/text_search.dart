import 'dart:math' as math;

import 'package:flutter/services.dart' show TextSelection;

import 'fuzzy.dart';
import 'note_index.dart';
import 'note_tree.dart';
import 'tags.dart';

/// Full-text search across all notes, forgiving typos.
///
/// The query splits on whitespace into terms that must all match. A term
/// starting with `#` is a tag filter (`#work` also finds `#work/quicknote`).
/// Any other term matches a note when it occurs in the note's text (case
/// insensitive), when a word in the note is within a couple of typos of it
/// (`metting` finds `meeting`, `quikc` finds `quicknote`), or when it
/// fuzzy-matches the note's path, as in the note finder.
class SearchHit {
  const SearchHit(this.path, this.score, this.snippets);

  final String path;
  final int score;

  /// Lines with matches, best first, at most [kMaxSnippets].
  final List<SearchSnippet> snippets;
}

/// One line of a note with the matched ranges in it.
class SearchSnippet {
  const SearchSnippet(this.lineStart, this.line, this.ranges);

  /// Offset of [line] in the note's text.
  final int lineStart;
  final String line;

  /// Matched (start, end) ranges within [line], sorted.
  final List<(int, int)> ranges;

  /// The first match in the note's text, to select when it opens.
  TextSelection get firstMatch => ranges.isEmpty
      ? TextSelection.collapsed(offset: lineStart)
      : TextSelection(
          baseOffset: lineStart + ranges.first.$1,
          extentOffset: lineStart + ranges.first.$2,
        );
}

const kMaxSnippets = 3;

/// Typos tolerated in a term of [length] characters.
int allowedTypos(int length) => length <= 3
    ? 0
    : length <= 6
    ? 1
    : 2;

/// Optimal-string-alignment distance (Levenshtein plus swapped neighbours),
/// or [max] + 1 once it is certain to exceed [max].
int typoDistance(String a, String b, int max) {
  if ((a.length - b.length).abs() > max) return max + 1;
  final n = a.length, m = b.length;
  var prev2 = List<int>.filled(m + 1, 0);
  var prev = List<int>.generate(m + 1, (j) => j);
  var cur = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    cur[0] = i;
    var rowMin = cur[0];
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = math.min(
        math.min(prev[j] + 1, cur[j - 1] + 1),
        prev[j - 1] + cost,
      );
      if (i > 1 &&
          j > 1 &&
          a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
          a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        v = math.min(v, prev2[j - 2] + 1);
      }
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return max + 1;
    final t = prev2;
    prev2 = prev;
    prev = cur;
    cur = t;
  }
  return prev[m];
}

class _Term {
  _Term(this.text) : typos = allowedTypos(text.length);

  final String text;
  final int typos;

  /// Words of the notes within [typos] of this term, with their distance.
  Map<String, int>? near;

  void findNear(Map<String, int> vocabulary) {
    final found = <String, int>{};
    if (typos > 0) {
      for (final w in vocabulary.keys) {
        if (w.length < 3 || w.contains(text)) continue;
        final d = typoDistance(text, w, typos);
        if (d <= typos) {
          found[w] = d;
        } else if (w.length > text.length) {
          // A typo in the start of a longer word: `quikc` for `quicknote`.
          // Ranks one typo below the same distance on a whole word.
          final p = typoDistance(text, w.substring(0, text.length), typos);
          if (p <= typos) found[w] = p + 1;
        }
      }
    }
    near = found;
  }
}

/// Searches [index] for [query]; best hits first.
List<SearchHit> searchNotes(String query, NoteIndex index, {int limit = 100}) {
  final tags = <String>[];
  final terms = <_Term>[];
  for (final raw in query.trim().split(RegExp(r'\s+'))) {
    if (raw.isEmpty) continue;
    if (raw.length > 1 && raw.startsWith('#')) {
      tags.add(foldCase(raw.substring(1)));
    } else {
      terms.add(_Term(foldCase(raw)));
    }
  }
  if (tags.isEmpty && terms.isEmpty) return const [];
  final vocabulary = terms.any((t) => t.typos > 0) ? index.vocabulary : null;
  for (final t in terms) {
    if (vocabulary != null) t.findNear(vocabulary);
  }

  final hits = <SearchHit>[];
  for (final path in index.paths) {
    final note = index[path]!;
    if (!tags.every((f) => note.tags.any((t) => tagMatches(t, f)))) continue;
    var score = 0;
    final ranges = <(int, int)>[];
    var matchedAll = true;
    for (final term in terms) {
      final s = _scoreTerm(term, path, note, ranges);
      if (s == null) {
        matchedAll = false;
        break;
      }
      score += s;
    }
    if (!matchedAll) continue;
    if (terms.isEmpty) {
      // A pure tag search: show where the tags are.
      for (final m in kTagPattern.allMatches(note.folded)) {
        final tag = tagOf(m);
        if (tag != null && tags.any((f) => tagMatches(tag, f))) {
          ranges.add((m.start, m.end));
        }
      }
    }
    hits.add(SearchHit(path, score, _snippets(note.text, ranges)));
  }
  hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.path.compareTo(b.path);
  });
  return hits.length > limit ? hits.sublist(0, limit) : hits;
}

/// Score of [term] in one note, adding its matches to [ranges]; null when
/// the term matches neither the text nor the path.
int? _scoreTerm(
  _Term term,
  String path,
  IndexedNote note,
  List<(int, int)> ranges,
) {
  int? score;
  final text = note.folded;
  final t = term.text;

  // Exact (case-insensitive) occurrences.
  var count = 0;
  var boundary = false;
  for (
    var at = text.indexOf(t);
    at >= 0 && count < 50;
    at = text.indexOf(t, at + t.length)
  ) {
    count++;
    ranges.add((at, at + t.length));
    if (at == 0 || !_isWordChar(text.codeUnitAt(at - 1))) boundary = true;
  }
  if (count > 0) score = 100 + (boundary ? 20 : 0) + math.min(count, 5) * 4;

  // Near misses, only when the exact text is not there.
  if (score == null) {
    final near = term.near;
    if (near != null && near.isNotEmpty) {
      var best = 99;
      for (final w in note.words) {
        final d = near[w];
        if (d == null) continue;
        best = math.min(best, d);
        for (final at in _wordOccurrences(text, w, 10)) {
          ranges.add((at, at + w.length));
        }
      }
      if (best < 99) score = 70 - 15 * best;
    }
  }

  // The note's name and folders.
  final name = foldCase(displayName(path));
  if (name.contains(t)) {
    score = (score ?? 0) + 120;
  } else if (fuzzyMatch(t, path) != null) {
    score = (score ?? 0) + 30;
  }
  return score;
}

bool _isWordChar(int c) =>
    (c >= 48 && c <= 57) ||
    (c >= 65 && c <= 90) ||
    (c >= 97 && c <= 122) ||
    c == 95 ||
    c > 127;

/// Starts of whole-word occurrences of [word] in [text].
Iterable<int> _wordOccurrences(String text, String word, int max) sync* {
  var found = 0;
  for (
    var at = text.indexOf(word);
    at >= 0 && found < max;
    at = text.indexOf(word, at + 1)
  ) {
    final end = at + word.length;
    if ((at == 0 || !_isWordChar(text.codeUnitAt(at - 1))) &&
        (end == text.length || !_isWordChar(text.codeUnitAt(end)))) {
      found++;
      yield at;
    }
  }
}

/// Groups [ranges] by line and keeps the lines with the most matches.
List<SearchSnippet> _snippets(String text, List<(int, int)> ranges) {
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final byLine = <int, List<(int, int)>>{};
  for (final r in ranges) {
    final start = r.$1 == 0 ? 0 : text.lastIndexOf('\n', r.$1 - 1) + 1;
    (byLine[start] ??= []).add(r);
  }
  final lines = byLine.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.length.compareTo(a.value.length);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return [
    for (final e in lines.take(kMaxSnippets)) _snippet(text, e.key, e.value),
  ]..sort((a, b) => a.lineStart.compareTo(b.lineStart));
}

SearchSnippet _snippet(String text, int start, List<(int, int)> ranges) {
  var end = text.indexOf('\n', start);
  if (end < 0) end = text.length;
  final merged = <(int, int)>[];
  for (final r in ranges) {
    final s = r.$1 - start, e = math.min(r.$2, end) - start;
    if (merged.isNotEmpty && s <= merged.last.$2) {
      merged[merged.length - 1] = (merged.last.$1, math.max(merged.last.$2, e));
    } else {
      merged.add((s, e));
    }
  }
  return SearchSnippet(start, text.substring(start, end), merged);
}

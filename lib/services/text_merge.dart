import 'dart:typed_data';

/// A conservative diff3-style merge of Markdown source. Null means that both
/// sides changed the same lines, or that diffing would exceed the work budget.
/// Lines retain their endings, including CRLF and a missing final newline.
/// Algorithm background: https://git-scm.com/docs/git-merge-file and
/// https://www.gnu.org/software/diffutils/manual/diffutils.html (diff3).
String? mergeNoteText(String? base, String local, String remote) {
  if (local == remote) return local;
  if (base == local) return remote;
  if (base == remote) return local;
  if (base == null) return null;
  final original = _lines(base);
  final ours = _changes(original, _lines(local));
  final theirs = _changes(original, _lines(remote));
  if (ours == null || theirs == null) return null;
  final edits = [...ours];
  for (final change in theirs) {
    var duplicate = false;
    for (final other in ours) {
      if (change.start == other.start &&
          change.end == other.end &&
          change.text == other.text) {
        duplicate = true;
        break;
      }
      // Insertions at a replacement boundary are ambiguous too.
      final overlap = change.start == change.end || other.start == other.end
          ? change.start <= other.end && other.start <= change.end
          : change.start < other.end && other.start < change.end;
      if (overlap) return null;
    }
    if (!duplicate) edits.add(change);
  }
  edits.sort((a, b) => a.start.compareTo(b.start));
  final out = StringBuffer();
  var cursor = 0;
  for (final edit in edits) {
    out.writeAll(original.sublist(cursor, edit.start));
    out.write(edit.text);
    cursor = edit.end;
  }
  out.writeAll(original.sublist(cursor));
  return out.toString();
}

List<String> _lines(String text) =>
    RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((m) => m[0]!).toList();

class _Change {
  const _Change(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

List<_Change>? _changes(List<String> base, List<String> changed) {
  var prefix = 0;
  while (prefix < base.length &&
      prefix < changed.length &&
      base[prefix] == changed[prefix]) {
    prefix++;
  }
  var endBase = base.length;
  var endChanged = changed.length;
  while (endBase > prefix &&
      endChanged > prefix &&
      base[endBase - 1] == changed[endChanged - 1]) {
    endBase--;
    endChanged--;
  }
  final n = endBase - prefix;
  final m = endChanged - prefix;
  if (n == 0 && m == 0) return [];
  if (n == 0 || m == 0) {
    return [
      _Change(prefix, endBase, changed.sublist(prefix, endChanged).join()),
    ];
  }
  // Bounded LCS diff: large, heavily changed notes become conflict copies
  // instead of freezing the UI or making a heuristic merge that loses text.
  if ((n + 1) * (m + 1) > 2000000) return null;
  final width = m + 1;
  final table = Uint32List((n + 1) * width);
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      table[i * width + j] = base[prefix + i] == changed[prefix + j]
          ? table[(i + 1) * width + j + 1] + 1
          : (table[(i + 1) * width + j] > table[i * width + j + 1]
                ? table[(i + 1) * width + j]
                : table[i * width + j + 1]);
    }
  }
  final result = <_Change>[];
  var i = 0;
  var j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && base[prefix + i] == changed[prefix + j]) {
      i++;
      j++;
      continue;
    }
    final start = i;
    final replacement = StringBuffer();
    while (i < n || j < m) {
      if (i < n && j < m && base[prefix + i] == changed[prefix + j]) break;
      if (j < m &&
          (i == n || table[i * width + j + 1] > table[(i + 1) * width + j])) {
        replacement.write(changed[prefix + j++]);
      } else {
        i++;
      }
    }
    result.add(_Change(prefix + start, prefix + i, replacement.toString()));
  }
  return result;
}

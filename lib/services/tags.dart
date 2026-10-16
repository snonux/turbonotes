/// `#tags` in note text, Obsidian style: `#idea`, nested `#work/quicknote`.
///
/// A tag starts with `#` that does not follow a letter, digit, `/`, `(`, `&`
/// or another `#`, so headings (`# Title`), URL fragments (`page#top`,
/// `/#top`), link targets (`(#top)`) and HTML entities (`&#38;`) are not tags.
/// Pure numbers (`#123`, an issue reference) are not tags either. Tags are
/// compared lower-case. Nothing inside code spans or fenced code counts.
final RegExp kTagPattern = RegExp(
  r'(?<![\p{L}\p{N}_/(&#])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)',
  unicode: true,
);

final RegExp _fence = RegExp(r'^\s{0,3}(```|~~~)');
final RegExp _codeSpan = RegExp(r'`[^`\n]*`');
final RegExp _digits = RegExp(r'^[0-9/_-]*$');

/// The tag [match] of [kTagPattern] names, or null for one that is not a
/// tag after all (all digits). Trailing `/` and `-` are dropped.
String? tagOf(Match match) {
  var tag = match.group(1)!;
  while (tag.endsWith('/') || tag.endsWith('-')) {
    tag = tag.substring(0, tag.length - 1);
  }
  if (tag.isEmpty || _digits.hasMatch(tag)) return null;
  return tag.toLowerCase();
}

/// Every tag in [text], lower-case.
Set<String> extractTags(String text) {
  final tags = <String>{};
  String? fence;
  for (final line in text.split('\n')) {
    final open = _fence.firstMatch(line);
    if (fence != null) {
      if (line.trimLeft().startsWith(fence)) fence = null;
      continue;
    }
    if (open != null) {
      fence = open.group(1);
      continue;
    }
    if (!line.contains('#')) continue;
    final plain = line.replaceAllMapped(_codeSpan, (m) => ' ' * m[0]!.length);
    for (final m in kTagPattern.allMatches(plain)) {
      final tag = tagOf(m);
      if (tag != null) tags.add(tag);
    }
  }
  return tags;
}

/// Whether a note tagged [noteTag] is shown by the filter [filter]: the tag
/// itself or one nested below it (`work` shows `work/quicknote`).
bool tagMatches(String noteTag, String filter) =>
    noteTag == filter || noteTag.startsWith('$filter/');

/// One level of the tag tree: `work/quicknote` is `quicknote` under `work`.
class TagNode {
  TagNode(this.name, this.tag);

  /// Last segment; empty for the root.
  final String name;

  /// Full tag, e.g. `work/quicknote`; empty for the root.
  final String tag;

  final Map<String, TagNode> _children = {};

  /// Notes carrying this tag or one nested below it.
  final Set<String> notes = {};

  /// Sorted once: a built tree never changes.
  late final List<TagNode> children = _children.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  /// Builds the tree from each note's tags.
  static TagNode build(Map<String, Set<String>> tagsByNote) {
    final root = TagNode('', '');
    tagsByNote.forEach((path, tags) {
      for (final tag in tags) {
        var node = root;
        for (final segment in tag.split('/')) {
          if (segment.isEmpty) continue;
          final full = node.tag.isEmpty ? segment : '${node.tag}/$segment';
          node = node._children.putIfAbsent(
            segment,
            () => TagNode(segment, full),
          );
          node.notes.add(path);
        }
      }
    });
    return root;
  }
}

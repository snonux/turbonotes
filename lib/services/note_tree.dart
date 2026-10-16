/// A folder in the note tree, built from the flat path list a [NoteStore]
/// returns. Folders sort before notes, both alphabetically (case-insensitive).
class NoteFolder {
  NoteFolder(this.name, this.path);

  /// Last path segment; empty for the root.
  final String name;

  /// Relative path from the notes folder root; empty for the root.
  final String path;

  final Map<String, NoteFolder> _folders = {};
  final List<String> _notes = [];

  // A tree is never changed once built, so the sorted lists and counts are
  // worked out once: the sidebar asks for them on every rebuild.
  late final List<NoteFolder> folders = _folders.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Full relative note paths directly inside this folder.
  late final List<String> notes = List.of(_notes)
    ..sort(
      (a, b) => baseName(a).toLowerCase().compareTo(baseName(b).toLowerCase()),
    );

  late final int noteCount =
      _notes.length + _folders.values.fold(0, (sum, f) => sum + f.noteCount);

  static NoteFolder build(Iterable<String> notePaths) {
    final root = NoteFolder('', '');
    for (final path in notePaths) {
      final segments = path.split('/');
      var folder = root;
      for (var i = 0; i < segments.length - 1; i++) {
        final name = segments[i];
        final childPath = folder.path.isEmpty ? name : '${folder.path}/$name';
        folder = folder._folders.putIfAbsent(
          name,
          () => NoteFolder(name, childPath),
        );
      }
      folder._notes.add(path);
    }
    return root;
  }
}

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// A note's file name without its markdown extension.
String displayName(String path) {
  final name = baseName(path);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String parentPath(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// Every folder on the way to [path], e.g. `a/b/c.md` -> `a`, `a/b`.
Iterable<String> ancestorFolders(String path) sync* {
  final segments = path.split('/');
  for (var i = 1; i < segments.length; i++) {
    yield segments.take(i).join('/');
  }
}

/// Where edits go when [path] changed on disk and nobody could be asked:
/// `a/todo.md` -> `a/todo (conflict 2026-10-07 180215).md`, next to the note.
String conflictCopyPath(String path, DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}${two(at.minute)}${two(at.second)}';
  final name = baseName(path);
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot) : '.md';
  final folder = parentPath(path);
  final copy = '${displayName(path)} (conflict $stamp)$ext';
  return folder.isEmpty ? copy : '$folder/$copy';
}

/// Where an image added to the note at [notePath] is stored, and the link
/// the note gets for it: `a/to do.md` ->
/// (`a/to-do-20261007-180215.png`, `to-do-20261007-180215.png`): right next
/// to the note, so the image travels with it.
/// A [suffix] above 0 tells apart images added in the same second
/// (`to-do-20261007-180215-1.png`), as quick capture does.
({String path, String link}) attachmentPathFor(
  String notePath,
  String extension,
  DateTime at, {
  int suffix = 0,
}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  final stem = displayName(
    notePath,
  ).replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '-');
  final ext = extension.startsWith('.') ? extension : '.$extension';
  final unique = suffix > 0 ? '$stamp-$suffix' : stamp;
  final link = '${stem.isEmpty ? 'image' : stem}-$unique$ext';
  final folder = parentPath(notePath);
  return (path: folder.isEmpty ? link : '$folder/$link', link: link);
}

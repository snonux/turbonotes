import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// File extensions treated as markdown notes. Everything else in the notes
/// folder is left alone and never shown.
const List<String> kNoteExtensions = ['.md', '.markdown'];

bool isNotePath(String path) =>
    kNoteExtensions.contains(p.posix.extension(path).toLowerCase());

/// Image files a note can embed (pasted or shared images). They live next to
/// the notes, right beside the note that links them, and never show in the
/// tree.
const List<String> kImageExtensions = [
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
];

bool isImagePath(String path) =>
    kImageExtensions.contains(p.posix.extension(path).toLowerCase());

/// Folders that are never scanned: dot-folders such as `.git`, `.obsidian`
/// or `.stfolder` hold tooling state, not notes.
bool isHiddenSegment(String segment) => segment.startsWith('.');

/// Thrown for a note path a user typed that cannot name a note.
class InvalidNotePathException implements Exception {
  const InvalidNotePathException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when [NoteStore.create] or [NoteStore.rename] would overwrite.
class NoteExistsException implements Exception {
  const NoteExistsException(this.path);
  final String path;
  @override
  String toString() => '$path already exists.';
}

/// Normalizes a user-typed note path to the store's form: POSIX separators,
/// relative to the notes folder, no `.`/`..` segments, a markdown extension
/// (`.md` is appended when none is given).
String normalizeNotePath(String raw) {
  final path = _normalizeRelativePath(raw);
  return isNotePath(path) ? path : '$path.md';
}

/// Like [normalizeNotePath] for an image next to the notes; it must already
/// carry one of [kImageExtensions].
String normalizeAttachmentPath(String raw) {
  final path = _normalizeRelativePath(raw);
  if (!isImagePath(path)) {
    throw InvalidNotePathException('$path is not an image.');
  }
  return path;
}

String _normalizeRelativePath(String raw) {
  var path = raw.trim().replaceAll('\\', '/');
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  if (path.isEmpty) {
    throw const InvalidNotePathException('Enter a file name.');
  }
  final segments = path.split('/');
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') {
      throw const InvalidNotePathException(
        'Use a path inside the notes folder, without empty, "." or ".." parts.',
      );
    }
    if (isHiddenSegment(segment)) {
      throw const InvalidNotePathException(
        'Names starting with "." are hidden and cannot hold notes.',
      );
    }
  }
  return path;
}

/// Resolves the target of a markdown link or image in the note at
/// [notePath] to a path in the notes folder, or null for anything that is
/// not a file inside it (URLs, absolute paths, `..` past the root).
String? resolveNoteLink(String notePath, String target) {
  var t = target.trim();
  if (t.startsWith('<') && t.endsWith('>')) t = t.substring(1, t.length - 1);
  // A title after the destination: ![alt](img.png "title").
  final space = t.indexOf(' "');
  if (space > 0) t = t.substring(0, space);
  if (t.isEmpty || t.startsWith('/') || t.contains(':')) return null;
  try {
    t = Uri.decodeComponent(t);
  } on ArgumentError {
    // Not percent-encoded after all; use it as written.
  }
  final folder = p.posix.dirname(notePath);
  final joined = p.posix.normalize(folder == '.' ? t : p.posix.join(folder, t));
  if (joined == '.' || joined.startsWith('../') || joined == '..') return null;
  return joined;
}

/// A folder of markdown notes, addressed by relative POSIX paths such as
/// `projects/quicknote.md`. Implementations never touch anything outside
/// the folder and never list non-markdown files.
abstract class NoteStore {
  /// A short human label for the folder, for titles and messages.
  String get label;

  /// Every note path in the folder, recursively, sorted.
  Future<List<String>> list();

  Future<String> read(String path);

  /// Replaces the content of an existing note.
  Future<void> write(String path, String text);

  /// Replaces a synced note only if it still contains [expected]. Retains the
  /// displaced file as a hidden recovery backup so even an already-open
  /// external writer cannot lose its edits during replacement.
  Future<void> replaceForSync(String path, String expected, String text);

  /// Creates a new note (and any missing parent folders). Throws
  /// [NoteExistsException] rather than overwrite.
  Future<void> create(String path, String text);

  Future<void> delete(String path);

  /// Moves a note. Throws [NoteExistsException] rather than overwrite.
  Future<void> rename(String from, String to);

  /// Reads an image next to the notes (see [normalizeAttachmentPath]).
  Future<Uint8List> readBytes(String path);

  /// Stores a new image (and any missing parent folders). Throws
  /// [NoteExistsException] rather than overwrite.
  Future<void> createBytes(String path, Uint8List bytes);
}

/// A store that can say cheaply which notes changed since its last listing
/// and read many notes in one go, so the search index is built off the UI
/// isolate and a refresh only reads what changed (see `NoteIndex.load`).
///
/// Implementations must be sendable to another isolate, and work there
/// (platform channels do once `BackgroundIsolateBinaryMessenger` is set up).
abstract interface class VersionedNoteStore implements NoteStore {
  /// Every note path, like [list], with a version string that changes
  /// whenever the note does (its modification time and size).
  Future<Map<String, String>> listVersions();

  /// The text of each of [paths], in order; null for one that cannot be
  /// read.
  Future<List<String?>> readMany(List<String> paths);
}

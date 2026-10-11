import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'note_store.dart';

/// Notes in a plain filesystem directory (Linux, or a typed path on Android).
class DirectoryNoteStore implements NoteStore {
  DirectoryNoteStore(this.root);

  final String root;

  @override
  String get label => root;

  File _file(String path) => _inside(path, normalizeNotePath(path));

  File _inside(String path, String normalized) {
    final full = p.normalize(p.join(root, p.joinAll(normalized.split('/'))));
    if (!p.isWithin(p.normalize(root), full)) {
      throw InvalidNotePathException('$path is outside the notes folder.');
    }
    var component = p.normalize(root);
    for (final segment in normalized.split('/')) {
      component = p.join(component, segment);
      if (FileSystemEntity.typeSync(component, followLinks: false) ==
          FileSystemEntityType.link) {
        throw InvalidNotePathException('$path contains a symbolic link.');
      }
    }
    return File(full);
  }

  @override
  Future<List<String>> list() async {
    final dir = Directory(root);
    if (!await dir.exists()) {
      throw FileSystemException('The notes folder does not exist', root);
    }
    final notes = <String>[];
    await _scan(dir, '', notes);
    notes.sort();
    return notes;
  }

  // Manual recursion rather than list(recursive: true): hidden folders such
  // as .git are skipped without being walked, and links are never followed,
  // so a symlink loop cannot hang the scan.
  Future<void> _scan(Directory dir, String prefix, List<String> out) async {
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (isHiddenSegment(name)) continue;
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (entity is Directory) {
        await _scan(entity, rel, out);
      } else if (entity is File && isNotePath(name)) {
        out.add(rel);
      }
    }
  }

  @override
  Future<String> read(String path) async => _file(path).readAsString();

  @override
  Future<void> write(String path, String text) async {
    final file = _file(path);
    if (!await file.exists()) {
      throw PathNotFoundException(path, const OSError('Note not found'));
    }
    await _atomicWrite(file, text);
  }

  @override
  Future<void> replaceForSync(String path, String expected, String text) async {
    final file = _file(path);
    if (await file.readAsString() != expected) {
      throw FileSystemException('Note changed during sync; sync again', path);
    }
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final backup = File(
      '${file.parent.path}/.turbonotes-sync-backup-$nonce.md',
    );
    await backup.create(exclusive: true);
    try {
      // Move the actual inode, not a copy. An external writer with an open
      // descriptor can still finish writing into the retained backup.
      await _file(path).rename(backup.path);
    } catch (_) {
      await backup.delete();
      rethrow;
    }
    try {
      if (await backup.readAsString() != expected) {
        throw FileSystemException('Note changed during sync; sync again', path);
      }
      await create(path, text);
    } catch (_) {
      // Never overwrite a new file created by an external writer. Restoring
      // through create also leaves the recovery inode intact for open writers.
      if (!await file.exists()) {
        try {
          await create(path, await backup.readAsString());
        } on NoteExistsException {
          // Another writer restored the path first; the backup is retained.
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> create(String path, String text) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    try {
      await file.create(exclusive: true);
    } on PathExistsException {
      throw NoteExistsException(normalizeNotePath(path));
    }
    await file.writeAsString(text, mode: FileMode.append, flush: true);
  }

  @override
  Future<void> delete(String path) async {
    await _file(path).delete();
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = _file(from);
    final target = _file(to);
    if (await target.exists()) throw NoteExistsException(normalizeNotePath(to));
    await target.parent.create(recursive: true);
    await source.rename(target.path);
  }

  @override
  Future<Uint8List> readBytes(String path) async =>
      _inside(path, normalizeAttachmentPath(path)).readAsBytes();

  @override
  Future<void> createBytes(String path, Uint8List bytes) async {
    final normalized = normalizeAttachmentPath(path);
    final file = _inside(path, normalized);
    await file.parent.create(recursive: true);
    try {
      await file.create(exclusive: true);
    } on PathExistsException {
      throw NoteExistsException(normalized);
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  /// Write a sibling temp file, then rename it over the note, so a crash or
  /// full disk mid-save never leaves a half-written note behind.
  Future<void> _atomicWrite(File file, String text) async {
    final temp = File(
      '${file.parent.path}/.${p.basename(file.path)}.'
      '${Random.secure().nextInt(1 << 32)}.tmp',
    );
    try {
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // The original note is intact either way.
      }
      rethrow;
    }
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:turbonotes/services/note_store.dart';

/// In-memory [NoteStore] for widget tests: no dart:io futures, so it works
/// on the fake clock of a testWidgets body (see AGENTS.md).
class MemoryNoteStore implements NoteStore {
  MemoryNoteStore(Map<String, String> notes) : notes = Map.of(notes);

  final Map<String, String> notes;
  final Map<String, Uint8List> files = {};

  /// Makes [list] take this long, like a real folder, so a refresh spans
  /// frames.
  Duration? listDelay;

  @override
  String get label => '/notes';

  @override
  Future<List<String>> list() async {
    final delay = listDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return notes.keys.toList()..sort();
  }

  @override
  Future<String> read(String path) async {
    final text = notes[path];
    if (text == null) throw PathNotFoundException(path, const OSError());
    return text;
  }

  @override
  Future<void> write(String path, String text) async {
    if (!notes.containsKey(path)) {
      throw PathNotFoundException(path, const OSError());
    }
    notes[path] = text;
  }

  @override
  Future<void> replaceForSync(String path, String expected, String text) async {
    if (notes[path] != expected) {
      throw FileSystemException('Note changed during sync', path);
    }
    notes[path] = text;
  }

  @override
  Future<void> create(String path, String text) async {
    final p = normalizeNotePath(path);
    if (notes.containsKey(p)) throw NoteExistsException(p);
    notes[p] = text;
  }

  @override
  Future<void> delete(String path) async {
    if (notes.remove(path) == null) {
      throw PathNotFoundException(path, const OSError());
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    if (notes.containsKey(to)) throw NoteExistsException(to);
    notes[to] = notes.remove(from)!;
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final bytes = files[path];
    if (bytes == null) throw PathNotFoundException(path, const OSError());
    return bytes;
  }

  @override
  Future<void> createBytes(String path, Uint8List bytes) async {
    final p = normalizeAttachmentPath(path);
    if (files.containsKey(p)) throw NoteExistsException(p);
    files[p] = bytes;
  }
}

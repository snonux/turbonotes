import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'note_index.dart';

/// The search index of the folder last opened, kept between starts: on a
/// large folder, reading every note again on each start is what kept tags
/// and search waiting, and on Android it kept the document provider busy
/// while a note was being opened. With it, a start only reads the notes
/// whose version changed since.
///
/// Only the folder last indexed is kept, in the app's private support
/// directory, so the copy never outgrows one notes folder, and opening
/// another folder replaces it.
abstract interface class IndexCache {
  /// The index saved for [folder], or null when there is none. Every entry
  /// keeps the version it was read at, so a refresh against a fresh scan
  /// reads only what changed.
  Future<NoteIndex?> load(String folder);

  Future<void> save(String folder, NoteIndex index);
}

/// [IndexCache] in one binary file. A missing, broken or foreign file just
/// means no cache.
class FileIndexCache implements IndexCache {
  FileIndexCache({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<String> _path() async =>
      p.join((await _directory()).path, 'index', 'notes.bin');

  @override
  Future<NoteIndex?> load(String folder) async {
    final String path;
    try {
      path = await _path();
    } catch (_) {
      return null;
    }
    // Decoding and preparing thousands of notes is real work: a background
    // isolate does it and hands the finished index over without a copy.
    return Isolate.run(() => decodeIndexCache(path, folder));
  }

  @override
  Future<void> save(String folder, NoteIndex index) async {
    try {
      final path = await _path();
      final entries = [
        for (final path in index.paths)
          (path, index[path]!.version ?? '', index[path]!.text),
      ];
      await Isolate.run(() => encodeIndexCache(path, folder, entries));
    } catch (_) {
      // Only a quicker next start is lost.
    }
  }
}

final _magic = ascii.encode('TNIX1');

/// Writes [entries] (path, version, text) for [folder] to [path],
/// atomically. Synchronous: meant for a background isolate.
void encodeIndexCache(
  String path,
  String folder,
  List<(String, String, String)> entries,
) {
  final out = BytesBuilder(copy: false);
  final length = ByteData(4);
  void string(String s) {
    final bytes = utf8.encode(s);
    length.setUint32(0, bytes.length);
    out
      ..add(Uint8List.fromList(length.buffer.asUint8List()))
      ..add(bytes);
  }

  out.add(_magic);
  string(folder);
  length.setUint32(0, entries.length);
  out.add(Uint8List.fromList(length.buffer.asUint8List()));
  for (final (notePath, version, text) in entries) {
    string(notePath);
    string(version);
    string(text);
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  final temp = File('$path.tmp');
  temp.writeAsBytesSync(out.takeBytes(), flush: true);
  temp.renameSync(path);
}

/// Reads what [encodeIndexCache] wrote for [folder]; null when the file is
/// missing, broken or holds another folder. Synchronous apart from the
/// signature: meant for a background isolate.
Future<NoteIndex?> decodeIndexCache(String path, String folder) async {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    var at = 0;
    int uint32() {
      final v = data.getUint32(at);
      at += 4;
      return v;
    }

    String string() {
      final n = uint32();
      if (at + n > bytes.length) throw const FormatException('Truncated');
      final s = utf8.decode(Uint8List.sublistView(bytes, at, at + n));
      at += n;
      return s;
    }

    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    at = _magic.length;
    if (string() != folder) return null;
    final count = uint32();
    final texts = <String, String>{};
    final versions = <String, String>{};
    for (var i = 0; i < count; i++) {
      final notePath = string();
      versions[notePath] = string();
      texts[notePath] = string();
    }
    return await NoteIndex.prepared(texts, versions);
  } catch (_) {
    return null;
  }
}

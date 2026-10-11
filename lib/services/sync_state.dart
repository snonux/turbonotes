import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

abstract interface class SyncState {
  Future<Map<String, String>> load();
  Future<void> save(Map<String, String> heads);
}

/// Per folder and S3 destination, outside the notes folder. A broken state
/// file is an error, never silently treated as a new device.
class FileSyncState implements SyncState {
  FileSyncState(String directory, String scope)
    : _file = File(p.join(directory, 'sync', '$scope.json'));

  final File _file;

  @override
  Future<Map<String, String>> load() async {
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded.values.any((v) => v is! String)) {
        throw const FormatException('Invalid local sync state.');
      }
      return decoded.cast<String, String>();
    } on PathNotFoundException {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, String> heads) async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    try {
      await temp.writeAsString(jsonEncode(heads), flush: true);
      await temp.rename(_file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

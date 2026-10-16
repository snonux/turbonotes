import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The note paths a folder held when the app last listed it, so the
/// sidebar shows straight away on the next start while the folder is
/// listed again behind it. Only paths are kept, never note text.
abstract interface class ListingCache {
  /// The paths last saved for [folder], or null when there are none.
  Future<List<String>?> load(String folder);

  Future<void> save(String folder, List<String> paths);
}

/// Keeps each folder's listing in a file in the app's support directory,
/// outside the notes. A missing or broken file just means no cache.
class FileListingCache implements ListingCache {
  FileListingCache({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file(String folder) async {
    final name = sha1.convert(utf8.encode(folder)).toString();
    return File(p.join((await _directory()).path, 'listing', '$name.json'));
  }

  @override
  Future<List<String>?> load(String folder) async {
    try {
      final decoded = jsonDecode(await (await _file(folder)).readAsString());
      // The folder is stored too, guarding against a hash collision.
      if (decoded is! Map || decoded['folder'] != folder) return null;
      final paths = decoded['paths'];
      return paths is List ? paths.whereType<String>().toList() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String folder, List<String> paths) async {
    try {
      final file = await _file(folder);
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'folder': folder, 'paths': paths}),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (_) {
      // Only a quicker start is lost.
    }
  }
}

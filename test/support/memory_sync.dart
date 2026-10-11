import 'dart:async';

import 'package:turbonotes/services/sync_objects.dart';
import 'package:turbonotes/services/sync_state.dart';

class MemorySyncObjects implements SyncObjects {
  final Map<String, List<int>> data = {};
  Future<void> Function()? beforeWrite;
  Future<void> Function()? afterList;
  int writes = 0;
  final Set<String> omitFromList = {};

  @override
  Future<List<String>> list(String prefix) async {
    final keys = data.keys
        .where((key) => key.startsWith(prefix) && !omitFromList.contains(key))
        .toList();
    await afterList?.call();
    return keys;
  }

  @override
  Future<List<int>> read(String key) async {
    if (!data.containsKey(key)) throw StateError('Missing revision');
    return List.of(data[key]!);
  }

  @override
  Future<void> write(String key, List<int> bytes) async {
    await beforeWrite?.call();
    // A content-addressed key can only ever receive the same bytes.
    if (data.containsKey(key) && data[key]!.join(',') != bytes.join(',')) {
      throw StateError('Overwriting a revision');
    }
    data[key] = List.of(bytes);
    writes++;
  }

  @override
  void close() {}
}

class MemorySyncState implements SyncState {
  Map<String, String> heads = {};
  bool failSave = false;

  @override
  Future<Map<String, String>> load() async => Map.of(heads);

  @override
  Future<void> save(Map<String, String> value) async {
    if (failSave) throw StateError('State write failed');
    heads = Map.of(value);
  }
}

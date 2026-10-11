// Run only against a dedicated test bucket:
// TURBONOTES_S3_SMOKE_CONFIG=/private/config.json flutter test tool/sync_garage_smoke_test.dart
// Config JSON: endpoint, region, bucket, accessKey, secretKey. Never commit it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/services/directory_note_store.dart';
import 'package:turbonotes/services/note_sync.dart';
import 'package:turbonotes/services/sync_config.dart';
import 'package:turbonotes/services/sync_objects.dart';
import 'package:turbonotes/services/sync_state.dart';

void main() {
  test(
    'Garage: two filesystem replicas merge, preserve conflicts, and recover offline',
    () async {
      final configPath = Platform.environment['TURBONOTES_S3_SMOKE_CONFIG'];
      if (configPath == null) {
        fail(
          'Set TURBONOTES_S3_SMOKE_CONFIG to dedicated test-bucket credentials.',
        );
      }
      final json =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
      final config = SyncConfig(
        enabled: true,
        endpoint: json['endpoint'] as String,
        region: json['region'] as String,
        bucket: json['bucket'] as String,
        accessKey: json['accessKey'] as String,
        secretKey: json['secretKey'] as String,
      );
      if (!config.bucket.contains('test')) {
        fail('Live smoke requires a dedicated test bucket.');
      }
      final dir = await Directory.systemTemp.createTemp('turbonotes-live-sync');
      addTearDown(() => dir.delete(recursive: true));
      final aDir = await Directory('${dir.path}/a').create();
      final bDir = await Directory('${dir.path}/b').create();
      final a = DirectoryNoteStore(aDir.path);
      final b = DirectoryNoteStore(bDir.path);
      final objects = S3SyncObjects(config);
      addTearDown(objects.close);
      final syncA = NoteSync(
        store: a,
        objects: objects,
        state: FileSyncState(dir.path, 'a'),
      );
      final syncB = NoteSync(
        store: b,
        objects: objects,
        state: FileSyncState(dir.path, 'b'),
      );
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final path = 'smoke-$stamp/space ü.markdown';
      final deepPath =
          'smoke-$stamp/${List.filled(4, 'ü' * 90).join('/')}/deep.md';
      await a.create(deepPath, 'deep Unicode path');
      await a.create(path, '# Title\r\nfirst\r\nlast');
      await syncA.run();
      await syncB.run();
      expect(await b.read(path), await a.read(path));
      expect(await b.read(deepPath), 'deep Unicode path');
      await a.write(path, '# Changed\r\nfirst\r\nlast');
      await b.write(path, '# Title\r\nfirst\r\nend');
      await Future.wait([syncA.run(), syncB.run()]);
      await syncA.run();
      await syncB.run();
      expect(await a.read(path), '# Changed\r\nfirst\r\nend');
      expect(await b.read(path), await a.read(path));
      await a.write(path, 'remote conflict');
      await b.write(path, 'local conflict');
      await syncA.run();
      final result = await syncB.run();
      expect(result.conflicts, ['smoke-$stamp/space ü-sync-conflict.md']);
      expect(await b.read(path), 'local conflict');
      expect(await b.read(result.conflicts.single), 'remote conflict');
      await syncA.run();
      expect(await a.read(path), 'local conflict');
      expect(await a.read(result.conflicts.single), 'remote conflict');
      await b.delete(path);
      await syncB.run();
      expect(await b.read(path), 'local conflict');
      // Exercise the real transport's closed/offline path without touching keys.
      objects.close();
      await a.write(path, 'offline edit');
      await expectLater(syncA.run(), throwsStateError);
      expect(await a.read(path), 'offline edit');
      final reconnected = S3SyncObjects(config);
      addTearDown(reconnected.close);
      await NoteSync(
        store: a,
        objects: reconnected,
        state: FileSyncState(dir.path, 'a'),
      ).run();
      await NoteSync(
        store: b,
        objects: reconnected,
        state: FileSyncState(dir.path, 'b'),
      ).run();
      expect(await b.read(path), 'offline edit');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

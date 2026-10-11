import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbonotes/services/preferences.dart';
import 'package:turbonotes/services/sync_config.dart';
import 'package:turbonotes/services/sync_state.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'sync defaults off, saves settings and preserves credentials exactly',
    () async {
      final prefs = PreferencesService();
      expect((await prefs.syncConfig()).enabled, isFalse);
      const config = SyncConfig(
        enabled: true,
        accessKey: 'key',
        secretKey: ' secret ',
      );
      await prefs.setSyncConfig(config);
      final saved = await prefs.syncConfig();
      expect(saved.enabled, isTrue);
      expect(saved.secretKey, ' secret ');
      expect(saved.endpoint, config.endpoint);
      expect(saved.bucket, config.bucket);
      expect(saved.region, config.region);
      expect(saved.accessKey, config.accessKey);
      await prefs.setSyncConfig(const SyncConfig());
      expect((await prefs.syncConfig()).enabled, isFalse);
    },
  );

  test(
    'invalid enabled settings are rejected without changing saved settings',
    () async {
      final prefs = PreferencesService();
      for (final config in [
        const SyncConfig(enabled: true),
        const SyncConfig(
          enabled: true,
          endpoint: 'http://example.com',
          accessKey: 'key',
          secretKey: 'secret',
        ),
        const SyncConfig(
          enabled: true,
          endpoint: 'https://user:secret@example.com',
          accessKey: 'key',
          secretKey: 'secret',
        ),
        const SyncConfig(
          enabled: true,
          endpoint: 'https://example.com/path',
          accessKey: 'key',
          secretKey: 'secret',
        ),
        const SyncConfig(
          enabled: true,
          bucket: '../bucket',
          accessKey: 'key',
          secretKey: 'secret',
        ),
        const SyncConfig(
          enabled: true,
          region: ' ',
          accessKey: 'key',
          secretKey: 'secret',
        ),
      ]) {
        expect(config.error, isNotNull);
        await expectLater(prefs.setSyncConfig(config), throwsFormatException);
      }
      expect((await prefs.syncConfig()).enabled, isFalse);
    },
  );

  test(
    'state scope separates folders and destinations, not credential rotations',
    () {
      const config = SyncConfig(accessKey: 'one', secretKey: 'secret');
      const rotated = SyncConfig(accessKey: 'two', secretKey: 'other');
      expect(config.scope('/a'), rotated.scope('/a'));
      expect(config.scope('/a'), isNot(config.scope('/b')));
      expect(
        config.scope('/a'),
        isNot(const SyncConfig(bucket: 'other').scope('/a')),
      );
    },
  );

  test(
    'local state is durable, isolated, atomic, and refuses corruption',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'turbonotes-sync-state',
      );
      addTearDown(() => dir.delete(recursive: true));
      final state = FileSyncState(dir.path, 'a');
      expect(await state.load(), isEmpty);
      await state.save({'note.md': 'id'});
      expect(await FileSyncState(dir.path, 'a').load(), {'note.md': 'id'});
      expect(await FileSyncState(dir.path, 'b').load(), isEmpty);
      expect(await File('${dir.path}/sync/a.json.tmp').exists(), isFalse);
      await File('${dir.path}/sync/a.json').writeAsString('{broken');
      await expectLater(state.load(), throwsFormatException);
    },
  );
}

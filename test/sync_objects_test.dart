import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:turbonotes/services/sync_config.dart';
import 'package:turbonotes/services/sync_objects.dart';

const _config = SyncConfig(
  enabled: true,
  endpoint: 'https://example.org',
  region: 'garage',
  bucket: 'test-bucket',
  accessKey: 'test-access',
  secretKey: 'test-secret',
);

class _Client extends http.BaseClient {
  _Client(Future<http.Response> Function(http.Request) handler)
    : delegate = MockClient(handler);
  final MockClient delegate;
  final requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) throw StateError('Client closed');
    requests.add(request);
    return delegate.send(request);
  }

  @override
  void close() {
    closed = true;
    delegate.close();
  }
}

String _page(List<String> keys, {bool more = false, String? token}) =>
    '''
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
<Name>test-bucket</Name><Prefix>notes/</Prefix><KeyCount>${keys.length}</KeyCount>
<MaxKeys>1000</MaxKeys><IsTruncated>$more</IsTruncated>
${token == null ? '' : '<NextContinuationToken>$token</NextContinuationToken>'}
${keys.map((key) => '<Contents><Key>$key</Key><LastModified>2026-10-11T00:00:00.000Z</LastModified><ETag>abc</ETag><Size>1</Size><StorageClass>STANDARD</StorageClass></Contents>').join()}
</ListBucketResult>''';

void main() {
  test('real S3 adapter advances V2 tokens beyond 1000 revisions', () async {
    final first = List.generate(1000, (i) => 'notes/$i.json');
    var pages = 0;
    final clients = <_Client>[];
    Future<http.Response> response(http.Request request) async {
      expect(request.url.queryParameters['list-type'], '2');
      expect(request.url.queryParameters['prefix'], 'notes/');
      expect(request.headers['authorization'], contains('AWS4-HMAC-SHA256'));
      if (pages++ == 0) {
        expect(request.url.queryParameters['continuation-token'], isNull);
        return http.Response(_page(first, more: true, token: 'opaque+/='), 200);
      }
      expect(request.url.queryParameters['continuation-token'], 'opaque+/=');
      return http.Response(_page(['notes/1000.json']), 200);
    }

    final objects = S3SyncObjects(
      _config,
      clientFactory: () {
        final client = _Client(response);
        clients.add(client);
        return client;
      },
    );
    addTearDown(objects.close);
    expect(await objects.list('notes/'), [...first, 'notes/1000.json']);
    expect(pages, 2);
    expect(clients.every((client) => client.closed), isTrue);
  });

  for (final token in [null, 'repeated']) {
    test(
      'truncated pages with missing or repeated tokens stop safely ($token)',
      () async {
        final clients = <_Client>[];
        final objects = S3SyncObjects(
          _config,
          clientFactory: () {
            final client = _Client(
              (_) async => http.Response(
                _page(['notes/a'], more: true, token: token),
                200,
              ),
            );
            clients.add(client);
            return client;
          },
        );
        addTearDown(objects.close);
        await expectLater(objects.list('notes/'), throwsFormatException);
        expect(
          clients.expand((client) => client.requests).length,
          token == null ? 1 : 2,
        );
        expect(clients.every((client) => client.closed), isTrue);
      },
    );
  }

  test(
    'S3 transport reads and uploads exact bytes and closes requests',
    () async {
      final payload = utf8.encode('{"note":"ä\\r\\n"}');
      final clients = <_Client>[];
      final objects = S3SyncObjects(
        _config,
        clientFactory: () {
          final client = _Client((request) async {
            if (request.method == 'GET') {
              return http.Response.bytes(payload, 200);
            }
            expect(request.method, 'PUT');
            expect(request.bodyBytes, payload);
            return http.Response('', 200, headers: {'etag': 'test-etag'});
          });
          clients.add(client);
          return client;
        },
      );
      addTearDown(objects.close);
      expect(await objects.read('notes/a.json'), payload);
      await objects.write('notes/a.json', payload);
      expect(clients.every((client) => client.closed), isTrue);
    },
  );

  test(
    'signed S3 requests refuse redirects and surface denied access',
    () async {
      final client = _Client(
        (_) async => http.Response(
          '<Error><Code>AccessDenied</Code><Message>Denied</Message></Error>',
          307,
          headers: {'location': 'https://another.example.org/secret'},
        ),
      );
      final objects = S3SyncObjects(_config, clientFactory: () => client);
      addTearDown(objects.close);
      await expectLater(objects.read('notes/a.json'), throwsA(anything));
      expect(client.requests.single.followRedirects, isFalse);
      expect(client.closed, isTrue);
    },
  );

  test(
    'read limit and timeout close connections without further requests',
    () async {
      final tooLarge = _Client(
        (_) async =>
            http.Response.bytes(List.filled(8 * 1024 * 1024 + 1, 120), 200),
      );
      final objects = S3SyncObjects(_config, clientFactory: () => tooLarge);
      addTearDown(objects.close);
      await expectLater(objects.read('notes/a.json'), throwsFormatException);
      expect(tooLarge.closed, isTrue);

      final gate = Completer<http.Response>();
      final stalled = _Client((_) => gate.future);
      final timed = S3SyncObjects(
        _config,
        clientFactory: () => stalled,
        requestTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(timed.close);
      await expectLater(
        timed.read('notes/a.json'),
        throwsA(isA<TimeoutException>()),
      );
      expect(stalled.closed, isTrue);
      gate.complete(http.Response('late', 200));
      timed.close();
      await expectLater(timed.read('notes/a.json'), throwsStateError);
      expect(stalled.requests.length, 1);
    },
  );
}

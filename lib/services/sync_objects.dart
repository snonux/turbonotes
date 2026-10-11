import 'dart:typed_data';
import 'dart:io';

import 'package:minio/minio.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'sync_config.dart';

/// Only immutable revisions are written; no object is deleted by sync.
abstract interface class SyncObjects {
  Future<List<String>> list(String prefix);
  Future<List<int>> read(String key);
  Future<void> write(String key, List<int> bytes);
  void close();
}

class S3SyncObjects implements SyncObjects {
  S3SyncObjects(
    SyncConfig config, {
    http.Client Function()? clientFactory,
    Duration requestTimeout = const Duration(minutes: 1),
  }) : _bucket = config.bucket,
       _clientFactory =
           clientFactory ??
           (() => IOClient(
             HttpClient()..connectionTimeout = const Duration(seconds: 15),
           )),
       _requestTimeout = requestTimeout {
    final error = config.error;
    if (error != null) throw FormatException(error);
    _client = Minio(
      endPoint: config.uri.host,
      port: config.uri.port,
      useSSL: true,
      region: config.region,
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      pathStyle: true,
    );
  }

  final String _bucket;
  final http.Client Function() _clientFactory;
  final Duration _requestTimeout;
  late final Minio _client;
  final Set<http.Client> _connections = {};
  bool _closed = false;

  Future<T> _request<T>(Future<T> Function() body) async {
    if (_closed) throw StateError('Sync connection is closed.');
    final clients = <http.Client>[];
    var finished = false;
    try {
      return await http
          .runWithClient(body, () {
            if (_closed || finished) {
              throw StateError('Sync request has ended.');
            }
            final client = _SyncHttpClient(_clientFactory());
            clients.add(client);
            _connections.add(client);
            return client;
          })
          .timeout(_requestTimeout);
    } finally {
      finished = true;
      for (final client in clients) {
        client.close();
        _connections.remove(client);
      }
    }
  }

  @override
  Future<List<String>> list(String prefix) => _request(() async {
    final keys = <String>[];
    final seen = <String>{};
    String? token;
    while (true) {
      // The pinned library's all-objects helpers use v1, which can fail to
      // advance when NextMarker is absent. V2 uses an explicit opaque token.
      // https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html
      final page = await _client.listObjectsV2Query(
        _bucket,
        prefix,
        token,
        '',
        1000,
        null,
      );
      for (final object in page.contents!) {
        if (object.key != null) keys.add(object.key!);
      }
      if (page.isTruncated != true) break;
      token = page.nextContinuationToken;
      if (token == null || token.isEmpty || !seen.add(token)) {
        throw const FormatException('The S3 listing did not advance.');
      }
    }
    return keys;
  });

  @override
  Future<List<int>> read(String key) => _request(() async {
    final data = BytesBuilder(copy: false);
    final stream = await _client.getObject(_bucket, key);
    await for (final bytes in stream) {
      data.add(bytes);
      if (data.length > 8 * 1024 * 1024) {
        throw const FormatException('A sync revision exceeds 8 MiB.');
      }
    }
    return data.takeBytes();
  });

  @override
  Future<void> write(String key, List<int> bytes) => _request(() async {
    await _client.putObject(
      _bucket,
      key,
      Stream.value(Uint8List.fromList(bytes)),
      size: bytes.length,
      metadata: {'content-type': 'application/json'},
    );
  });

  @override
  void close() {
    _closed = true;
    for (final client in _connections) {
      client.close();
    }
    _connections.clear();
  }
}

class _SyncHttpClient extends http.BaseClient {
  _SyncHttpClient(this._client);
  final http.Client _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // S3 endpoint redirects must never forward signed credentials elsewhere.
    request.followRedirects = false;
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}

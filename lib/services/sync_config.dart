import 'dart:convert';

import 'package:crypto/crypto.dart';

class SyncConfig {
  const SyncConfig({
    this.enabled = false,
    this.endpoint = 'https://garage.f3s.buetow.org',
    this.region = 'garage',
    this.bucket = 'turbonotes',
    this.accessKey = '',
    this.secretKey = '',
  });

  final bool enabled;
  final String endpoint;
  final String region;
  final String bucket;
  final String accessKey;
  final String secretKey;

  Uri get uri => Uri.parse(endpoint);

  /// Credentials can be rotated without forgetting the common ancestor.
  String scope(String folder) => sha256
      .convert(utf8.encode(jsonEncode([endpoint, region, bucket, folder])))
      .toString();

  String? get error {
    try {
      final u = uri;
      if (u.scheme != 'https' ||
          u.host.isEmpty ||
          u.userInfo.isNotEmpty ||
          (u.path.isNotEmpty && u.path != '/') ||
          u.hasQuery ||
          u.hasFragment ||
          u.port < 1 ||
          u.port > 65535) {
        return 'Use an HTTPS endpoint without a path, query or credentials.';
      }
    } on FormatException {
      return 'Enter a valid HTTPS endpoint.';
    }
    if (region.isEmpty || !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(region)) {
      return 'Enter an S3 region (for Garage, use garage).';
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$').hasMatch(bucket) ||
        bucket.contains('..') ||
        bucket.contains('.-') ||
        bucket.contains('-.') ||
        RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(bucket)) {
      return 'Enter a valid S3 bucket name (3–63 characters).';
    }
    if (accessKey.trim().isEmpty || secretKey.trim().isEmpty) {
      return 'Enter the S3 access key and secret key.';
    }
    return null;
  }
}

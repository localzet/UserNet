import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;

import 'package:crypto/crypto.dart';
import 'package:fl_clash/usernet/services/usernet_admin.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

int compareUserNetVersions(String left, String right) {
  final a = left.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final b = right.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final length = a.length > b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final comparison = (index < a.length ? a[index] : 0).compareTo(
      index < b.length ? b[index] : 0,
    );
    if (comparison != 0) return comparison;
  }
  return 0;
}

class UserNetRelease {
  const UserNetRelease({
    required this.version,
    required this.build,
    required this.notes,
    required this.downloadUrl,
    required this.sha256,
  });

  final String version;
  final int build;
  final String notes;
  final Uri downloadUrl;
  final String sha256;

  static UserNetRelease? parse(
    Map<String, dynamic> json, {
    String platform = 'android',
    String? arch,
  }) {
    final version = json['version']?.toString();
    final build = json['build'];
    final notes = json['notes']?.toString() ?? '';
    final (urlField, artifactPath, artifactExtension) = switch (platform) {
      'windows' => ('installerUrl', '/windows/', '.exe'),
      'linux' => ('debUrl', '/linux/', '.deb'),
      'macos' => (
        arch == 'arm64' ? 'dmgArm64Url' : 'dmgAmd64Url',
        '/macos/',
        '.dmg',
      ),
      _ => ('apkUrl', '/android/', '.apk'),
    };
    final checksumField = platform == 'macos'
        ? (arch == 'arm64' ? 'sha256Arm64' : 'sha256Amd64')
        : 'sha256';
    final artifactUrl = Uri.tryParse(json[urlField]?.toString() ?? '');
    final sha256 = json[checksumField]?.toString().toLowerCase();
    final isPrimaryHost =
        artifactUrl?.host == 'updates.userlay.com' &&
        artifactUrl!.path.startsWith(artifactPath);
    final isLocalzetMirror =
        artifactUrl?.host == 'www.userlay.com' &&
        artifactUrl!.path.startsWith('/usernet-updates$artifactPath');
    if (version == null ||
        version.isEmpty ||
        build is! int ||
        build <= 0 ||
        artifactUrl == null ||
        artifactUrl.scheme != 'https' ||
        artifactUrl.userInfo.isNotEmpty ||
        artifactUrl.hasPort ||
        artifactUrl.hasQuery ||
        artifactUrl.hasFragment ||
        (!isPrimaryHost && !isLocalzetMirror) ||
        !artifactUrl.path.endsWith(artifactExtension) ||
        sha256 == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      return null;
    }
    return UserNetRelease(
      version: version,
      build: build,
      notes: notes,
      downloadUrl: artifactUrl,
      sha256: sha256,
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}

class UserNetUpdateService {
  UserNetUpdateService({
    http.Client? client,
    Future<Directory> Function()? supportDirectory,
    String? platform,
    String? arch,
  }) : _client = client ?? http.Client(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _platform =
           platform ??
           (Platform.isWindows
               ? 'windows'
               : Platform.isAndroid
               ? 'android'
               : Platform.isLinux
               ? 'linux'
               : Platform.isMacOS
               ? 'macos'
               : 'unsupported') {
    _arch = arch ??
        (Platform.isMacOS && Abi.current() == Abi.macosArm64
            ? 'arm64'
            : 'amd64');
    const configuredUrl = String.fromEnvironment(
      'USERNET_RELEASE_MANIFEST_URL',
    );
    const channel = userNetAdminBuild ? 'admin' : 'stable';
    _manifestUrls = [
      Uri.parse(
        configuredUrl.isNotEmpty
            ? configuredUrl
            : 'https://updates.userlay.com/$_platform/$channel.json',
      ),
      Uri.parse(
        'https://www.userlay.com/usernet-updates/$_platform/$channel.json',
      ),
    ];
  }

  final http.Client _client;
  final Future<Directory> Function() _supportDirectory;
  final String _platform;
  late final String _arch;
  late final List<Uri> _manifestUrls;

  Future<UserNetRelease?> latest() async {
    if (_platform == 'unsupported' || userNetAdminBuild) return null;
    Object? lastError;
    UserNetRelease? latestRelease;
    for (final manifestUrl in _manifestUrls) {
      if (manifestUrl.scheme != 'https') {
        throw const FormatException('Release manifest must use HTTPS');
      }
      try {
        final response = await _client
            .get(manifestUrl, headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 404) continue;
        if (response.statusCode != 200) {
          throw StateError('Release server returned ${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) {
          throw const FormatException('Invalid release manifest');
        }
        final release = UserNetRelease.parse(
          Map<String, dynamic>.from(decoded),
          platform: _platform,
          arch: _arch,
        );
        if (release == null) {
          throw const FormatException('Invalid release metadata');
        }
        if (latestRelease == null || release.build >= latestRelease.build) {
          latestRelease = release;
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (latestRelease != null) return latestRelease;
    if (lastError is Exception) throw lastError;
    if (lastError is Error) throw lastError;
    if (lastError != null) throw StateError('Release manifests unavailable');
    return null;
  }

  Future<UserNetRelease?> availableUpdate() async {
    final release = await latest();
    if (release == null) return null;
    final package = await PackageInfo.fromPlatform();
    if (_platform == 'linux') {
      return compareUserNetVersions(release.version, package.version) > 0
          ? release
          : null;
    }
    final installedBuild = int.tryParse(package.buildNumber) ?? 0;
    if (installedBuild > 0) {
      return release.build > installedBuild ? release : null;
    }
    return compareUserNetVersions(release.version, package.version) > 0
        ? release
        : null;
  }

  Future<File> download(
    UserNetRelease release, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (_platform != 'android') {
      throw UnsupportedError('In-app installation is available on Android');
    }
    final directory = await _supportDirectory();
    final safeName = 'usernet-${release.version}-${release.build}.apk'
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File(p.join(directory.path, safeName));
    final partialFile = File('${file.path}.part');
    final request = http.Request('GET', release.downloadUrl)
      ..headers['Accept'] = 'application/vnd.android.package-archive';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Release server returned ${response.statusCode}');
    }
    final total = response.contentLength ?? 0;
    if (total > 500 * 1024 * 1024) {
      throw const FormatException('Release package is too large');
    }
    final fileSink = partialFile.openWrite();
    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        received += chunk.length;
        if (received > 500 * 1024 * 1024 || (total > 0 && received > total)) {
          throw const FormatException('Invalid release package size');
        }
        fileSink.add(chunk);
        hashSink.add(chunk);
        onProgress?.call(received, total);
      }
      hashSink.close();
      await fileSink.flush();
      await fileSink.close();
      if (digestSink.value?.toString() != release.sha256) {
        throw const FormatException('Release package SHA-256 mismatch');
      }
      await partialFile.rename(file.path);
      return file;
    } catch (_) {
      await fileSink.close();
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    }
  }
}

final userNetUpdateService = UserNetUpdateService();

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/usernet/services/usernet_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('accepts a hosted, versioned Android release', () {
    final release = UserNetRelease.parse({
      'version': '0.5.0',
      'build': 2026091601,
      'notes': 'Stability update',
      'apkUrl': 'https://updates.userlay.com/android/usernet-0.5.0.apk',
      'sha256': digest,
    });
    expect(release?.build, 2026091601);
    expect(release?.downloadUrl.host, 'updates.userlay.com');
  });

  test('accepts only the localzet mirror release path', () {
    final release = UserNetRelease.parse({
      'version': '0.5.2',
      'build': 2026102907,
      'apkUrl':
          'https://www.userlay.com/usernet-updates/android/usernet-0.5.2.apk',
      'sha256': digest,
    });
    expect(release?.downloadUrl.host, 'www.userlay.com');
    expect(
      UserNetRelease.parse({
        'version': '0.5.2',
        'build': 2026102907,
        'apkUrl': 'https://www.userlay.com/unrelated/usernet.apk',
        'sha256': digest,
      }),
      isNull,
    );
  });

  test('uses the mirror when the primary update origin is unreachable', () async {
    final service = UserNetUpdateService(
      platform: 'android',
      client: MockClient((request) async {
        if (request.url.host == 'updates.userlay.com') {
          throw const SocketException('unreachable');
        }
        return http.Response(
          '{"version":"0.5.2","build":2026102907,'
          '"apkUrl":"https://www.userlay.com/usernet-updates/android/usernet.apk",'
          '"sha256":"$digest"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final release = await service.latest();

    expect(release?.build, 2026102907);
    expect(release?.downloadUrl.host, 'www.userlay.com');
  });

  test('chooses the newest version across both update origins', () async {
    final service = UserNetUpdateService(
      platform: 'android',
      client: MockClient((request) async {
        final mirrored = request.url.host == 'www.userlay.com';
        final version = mirrored ? '0.5.2' : '0.5.1';
        final build = mirrored ? 2026102907 : 2026102906;
        final hostPath = mirrored
            ? 'www.userlay.com/usernet-updates'
            : 'updates.userlay.com';
        return http.Response(
          '{"version":"$version","build":$build,'
          '"apkUrl":"https://$hostPath/android/usernet-$version.apk",'
          '"sha256":"$digest"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final release = await service.latest();

    expect(release?.build, 2026102907);
    expect(release?.downloadUrl.host, 'www.userlay.com');
  });

  test('accepts a Windows installer only from the Windows release path', () {
    final release = UserNetRelease.parse({
      'version': '0.5.1',
      'build': 2026091607,
      'installerUrl':
          'https://updates.userlay.com/windows/usernet-0.5.1-2026091607.exe',
      'sha256': digest,
    }, platform: 'windows');
    expect(release?.downloadUrl.path, '/windows/usernet-0.5.1-2026091607.exe');
    expect(
      UserNetRelease.parse({
        'version': '0.5.1',
        'build': 2026091607,
        'installerUrl': 'https://updates.userlay.com/android/usernet.apk',
        'sha256': digest,
      }, platform: 'windows'),
      isNull,
    );
  });

  test('accepts a Debian package only from the Linux release path', () {
    final release = UserNetRelease.parse({
      'version': '0.5.11',
      'build': 2026110803,
      'debUrl': 'https://updates.userlay.com/linux/usernet-amd64.deb',
      'sha256': digest,
    }, platform: 'linux');

    expect(release?.downloadUrl.path, '/linux/usernet-amd64.deb');
    expect(
      UserNetRelease.parse({
        'version': '0.5.11',
        'build': 2026110803,
        'debUrl': 'https://updates.userlay.com/android/usernet.apk',
        'sha256': digest,
      }, platform: 'linux'),
      isNull,
    );
  });

  test('accepts the architecture-specific macOS disk image', () {
    final alternateDigest = List.filled(64, 'a').join();
    final armRelease = UserNetRelease.parse(
      {
        'version': '0.5.12',
        'build': 2026110805,
        'dmgArm64Url':
            'https://updates.userlay.com/macos/UserNet-macos-arm64.dmg',
        'dmgAmd64Url':
            'https://updates.userlay.com/macos/UserNet-macos-amd64.dmg',
        'sha256Arm64': digest,
        'sha256Amd64': alternateDigest,
      },
      platform: 'macos',
      arch: 'arm64',
    );
    final intelRelease = UserNetRelease.parse(
      {
        'version': '0.5.12',
        'build': 2026110805,
        'dmgArm64Url':
            'https://updates.userlay.com/macos/UserNet-macos-arm64.dmg',
        'dmgAmd64Url':
            'https://updates.userlay.com/macos/UserNet-macos-amd64.dmg',
        'sha256Arm64': digest,
        'sha256Amd64': alternateDigest,
      },
      platform: 'macos',
      arch: 'amd64',
    );

    expect(armRelease?.downloadUrl.path, '/macos/UserNet-macos-arm64.dmg');
    expect(intelRelease?.downloadUrl.path, '/macos/UserNet-macos-amd64.dmg');
    expect(armRelease?.sha256, digest);
    expect(intelRelease?.sha256, alternateDigest);
    expect(
      UserNetRelease.parse(
        {
          'version': '0.5.12',
          'build': 2026110805,
          'dmgArm64Url': 'https://updates.userlay.com/windows/UserNet.dmg',
          'sha256Arm64': digest,
        },
        platform: 'macos',
        arch: 'arm64',
      ),
      isNull,
    );
  });

  test('compares Linux release versions without a package build suffix', () {
    expect(
      compareUserNetVersions('0.5.11', '0.5.10.2026110802'),
      greaterThan(0),
    );
    expect(compareUserNetVersions('0.5.11', '0.5.11'), 0);
    expect(compareUserNetVersions('0.5.10', '0.5.11'), lessThan(0));
  });

  test('rejects credentialed or non-default-port release URLs', () {
    for (final url in [
      'https://user@updates.userlay.com/android/usernet.apk',
      'https://updates.userlay.com:8443/android/usernet.apk',
    ]) {
      expect(
        UserNetRelease.parse({
          'version': '0.5.0',
          'build': 2026091601,
          'apkUrl': url,
          'sha256': digest,
        }),
        isNull,
      );
    }
  });

  test('rejects downloads from another host', () {
    expect(
      UserNetRelease.parse({
        'version': '0.5.0',
        'build': 2026091601,
        'apkUrl': 'https://example.com/usernet.apk',
        'sha256': digest,
      }),
      isNull,
    );
  });

  test('rejects releases without a SHA-256 digest', () {
    expect(
      UserNetRelease.parse({
        'version': '0.5.0',
        'build': 2026091601,
        'apkUrl': 'https://updates.userlay.com/android/usernet.apk',
        'sha256': 'bad',
      }),
      isNull,
    );
  });

  test('downloads only an APK whose SHA-256 matches the manifest', () async {
    final directory = await Directory.systemTemp.createTemp('usernet-update-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = [0x50, 0x4b, 0x03, 0x04, 0x01, 0x02];
    final release = UserNetRelease(
      version: '0.5.2',
      build: 2026102906,
      notes: '',
      downloadUrl: Uri.parse(
        'https://updates.userlay.com/android/usernet-0.5.2.apk',
      ),
      sha256: sha256.convert(bytes).toString(),
    );
    final service = UserNetUpdateService(
      platform: 'android',
      client: MockClient((request) async {
        expect(request.url, release.downloadUrl);
        expect(
          request.headers['Accept'],
          'application/vnd.android.package-archive',
        );
        return http.Response.bytes(bytes, 200);
      }),
      supportDirectory: () async => directory,
    );

    final progress = <(int, int)>[];
    final downloaded = await service.download(
      release,
      onProgress: (received, total) => progress.add((received, total)),
    );

    expect(downloaded.path, endsWith('.apk'));
    expect(await downloaded.readAsBytes(), bytes);
    expect(progress, [(bytes.length, bytes.length)]);
  });

  test('rejects and removes a package with a mismatching digest', () async {
    final directory = await Directory.systemTemp.createTemp('usernet-update-');
    addTearDown(() => directory.delete(recursive: true));
    final release = UserNetRelease(
      version: '0.5.2',
      build: 2026102906,
      notes: '',
      downloadUrl: Uri.parse(
        'https://updates.userlay.com/android/usernet-0.5.2.apk',
      ),
      sha256: digest,
    );
    final service = UserNetUpdateService(
      platform: 'android',
      client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      supportDirectory: () async => directory,
    );

    await expectLater(service.download(release), throwsFormatException);
    expect(directory.listSync(), isEmpty);
  });
}

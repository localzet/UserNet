import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quick settings tile uses the complete monochrome UserNet mark', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final tileService = RegExp(
      r'<service\s+android:name="\.TileService"[^>]*>',
      multiLine: true,
    ).firstMatch(manifest)?.group(0);

    expect(tileService, isNotNull);
    expect(tileService, contains('android:icon="@drawable/usernet_tile"'));

    final icon = File(
      'android/app/src/main/res/drawable/usernet_tile.xml',
    ).readAsStringSync();
    expect(icon, contains('android:width="24dp"'));
    expect(icon, contains('android:height="24dp"'));
    expect(icon, contains('android:fillType="evenOdd"'));
    expect(icon, contains('M64,30 A7,7 0,1 1,64 44'));
    expect(icon, contains('M37,79 A7,7 0,1 1,37 93'));
    expect(icon, contains('M91,79 A7,7 0,1 1,91 93'));
    expect(icon, contains('M66.6,48.5 L61.4,45.5'));
    expect(icon, contains('M64,5 C76,5'));
    expect(icon, isNot(contains('#21A6EF')));
    for (final variant in ['ic_launcher.xml', 'ic_launcher_round.xml']) {
      final adaptive = File(
        'android/app/src/main/res/mipmap-anydpi-v26/$variant',
      ).readAsStringSync();
      expect(adaptive, contains('@drawable/usernet_tile'));
    }
  });

  test('notification icon uses the complete monochrome UserNet mark', () {
    final icon = File(
      'android/service/src/main/res/drawable/ic_service.xml',
    ).readAsStringSync();
    expect(icon, contains('android:fillType="evenOdd"'));
    expect(icon, contains('M37,79 A7,7 0,1 1,37 93'));
    expect(icon, contains('M91,79 A7,7 0,1 1,91 93'));
    expect(icon, contains('M66.6,48.5 L61.4,45.5'));
    expect(icon, contains('M64,30 A7,7 0,1 1,64 44'));
    expect(icon, isNot(contains('#21A6EF')));
  });

  test('Android splash uses the organic logo on a solid dark canvas', () {
    for (final style in [
      'android/app/src/main/res/values-v27/styles.xml',
      'android/app/src/main/res/values-night-v27/styles.xml',
    ]) {
      final source = File(style).readAsStringSync();
      expect(source, contains('@drawable/usernet_launcher'), reason: style);
      expect(
        source,
        contains(
          'android:windowSplashScreenBackground" tools:targetApi="s">#121212',
        ),
        reason: style,
      );
    }
    for (final style in [
      'android/app/src/main/res/values/styles.xml',
      'android/app/src/main/res/values-night/styles.xml',
      'android/app/src/main/res/values-v27/styles.xml',
      'android/app/src/main/res/values-night-v27/styles.xml',
    ]) {
      expect(
        File(style).readAsStringSync(),
        contains('@drawable/launch_background'),
        reason: style,
      );
    }
    expect(
      File(
        'android/app/src/main/res/drawable/launch_background.xml',
      ).readAsStringSync(),
      contains('@drawable/usernet_launcher'),
    );
  });

  test('cold quick actions open the app for missing setup or consent', () {
    final action = File(
      'android/app/src/main/kotlin/com/follow/clashx/QuickActionActivity.kt',
    ).readAsStringSync();
    expect(action, contains('needsInteractiveSetup(action)'));
    expect(action, contains('VpnService.prepare(this)'));
    expect(action, contains('POST_NOTIFICATIONS'));
    expect(action, contains('withContext(Dispatchers.Main.immediate)'));
    expect(action, isNot(contains('handle(intent)\n        finish()')));
  });

  test('VPN and proxy services remain started when the task is removed', () {
    final manifest = File(
      'android/service/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      RegExp(r'android:stopWithTask="false"').allMatches(manifest),
      hasLength(2),
    );

    for (final path in [
      'android/service/src/main/java/com/follow/clashx/service/VpnService.kt',
      'android/service/src/main/java/com/follow/clashx/service/ProxyService.kt',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('START_STICKY'),
        reason: path,
      );
    }
    expect(
      File(
        'android/app/src/main/kotlin/com/follow/clashx/ServiceController.kt',
      ).readAsStringSync(),
      contains('ContextCompat.startForegroundService'),
    );
  });
}

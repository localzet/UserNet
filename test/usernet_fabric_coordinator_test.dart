import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/usernet/services/usernet_fabric_coordinator.dart';
import 'package:fl_clash/usernet/services/usernet_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const transportChannel = MethodChannel('com.follow.clashx/usernet_transport');

  test('forced account mode retries after a concurrent Fabric start fails', () async {
    FlutterSecureStorage.setMockInitialValues({
      'usernet.account.fabric': jsonEncode({
        'userId': 'test-user',
        'credential': 'test-credential',
        'workPlatforms': ['telemost'],
        'carriers': [
          {'platform': 'telemost', 'joinLink': 'https://example.invalid/call'},
        ],
      }),
    });

    final firstStart = Completer<void>();
    var startCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, (call) async {
          switch (call.method) {
            case 'start':
              startCalls++;
              if (startCalls == 1) {
                firstStart.complete();
                await Future<void>.delayed(const Duration(milliseconds: 25));
                throw PlatformException(code: 'START_FAILED');
              }
              return null;
            case 'getStatus':
              return 'TUNNEL_CONNECTED';
            case 'isRunning':
              return true;
            default:
              return null;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transportChannel, null),
    );

    final coordinator = UserNetFabricCoordinator(isAndroid: () => true);
    const config = UserNetTransportConfig(
      enabled: true,
      mode: UserNetTransportMode.fabric,
      socksHost: '127.0.0.1',
      socksPort: 17890,
      proxyName: userNetCarrierProxyName,
    );

    final parallelFabricAttempt = coordinator.ensure(
      config,
      forceProbe: true,
    );
    await firstStart.future;

    final accountRecovery = coordinator.ensure(
      config,
      forceProbe: true,
      forceRequestedMode: true,
    );

    await expectLater(
      parallelFabricAttempt,
      throwsA(isA<PlatformException>()),
    );
    expect(await accountRecovery, isTrue);
    expect(startCalls, 2);
  });
}

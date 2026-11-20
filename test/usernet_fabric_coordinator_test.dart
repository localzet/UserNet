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

  test(
    'forced account mode retries after a concurrent Fabric start fails',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.fabric': jsonEncode({
          'userId': 'test-user',
          'credential': 'test-credential',
          'workPlatforms': ['telemost'],
          'carriers': [
            {
              'platform': 'telemost',
              'joinLink': 'https://example.invalid/call',
            },
          ],
        }),
      });

      final firstStart = Completer<void>();
      final failFirstStart = Completer<void>();
      final forcedWaitStarted = Completer<void>();
      final releaseForcedWait = Completer<void>();
      var startCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transportChannel, (call) async {
            switch (call.method) {
              case 'start':
                startCalls++;
                if (startCalls == 1) {
                  firstStart.complete();
                  await failFirstStart.future;
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

      final coordinator = UserNetFabricCoordinator(
        isAndroid: () => true,
        busyWait: (_) {
          if (!forcedWaitStarted.isCompleted) forcedWaitStarted.complete();
          return releaseForcedWait.future;
        },
      );
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
      final parallelFailure = expectLater(
        parallelFabricAttempt,
        throwsA(isA<PlatformException>()),
      );

      final accountRecovery = coordinator.ensure(
        config,
        forceProbe: true,
        forceRequestedMode: true,
      );
      await forcedWaitStarted.future;

      failFirstStart.completeError(PlatformException(code: 'START_FAILED'));
      await parallelFailure;
      releaseForcedWait.complete();

      expect(await accountRecovery, isTrue);
      expect(startCalls, 2);
    },
  );
}

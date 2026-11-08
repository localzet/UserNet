import 'dart:io';

import 'package:fl_clash/usernet/services/usernet_account.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const transportChannel = MethodChannel('com.follow.clashx/usernet_transport');
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, (call) async {
          if (call.method == 'getStatus') return 'STOPPED';
          if (call.method == 'isRunning') return false;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, null),
  );

  test('desktop account uses direct HTTP without invoking carrier', () async {
    FlutterSecureStorage.setMockInitialValues({
      'usernet.account.token': 'test-token',
    });
    var carrierCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, (call) async {
          carrierCalls++;
          throw MissingPluginException();
        });
    final service = UserNetAccountService(
      carrierSupported: false,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await service.account();
    expect(carrierCalls, 0);
    expect(await service.isSignedIn, isTrue);
  });

  test(
    'desktop network failure preserves the account without carrier',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.token': 'test-token',
      });
      var carrierCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transportChannel, (call) async {
            carrierCalls++;
            throw MissingPluginException();
          });
      final service = UserNetAccountService(
        carrierSupported: false,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await expectLater(
        service.account(),
        throwsA(
          isA<UserNetApiException>().having(
            (error) => error.message,
            'message',
            'USERNET_NETWORK_UNAVAILABLE',
          ),
        ),
      );
      expect(carrierCalls, 0);
      expect(await service.isSignedIn, isTrue);
    },
  );

  test('desktop intercepted HTML preserves account without carrier', () async {
    FlutterSecureStorage.setMockInitialValues({
      'usernet.account.token': 'test-token',
    });
    var carrierCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, (call) async {
          carrierCalls++;
          throw MissingPluginException();
        });
    final service = UserNetAccountService(
      carrierSupported: false,
      client: MockClient(
        (_) async => http.Response('<html>blocked</html>', 401),
      ),
    );
    await expectLater(
      service.account(),
      throwsA(
        isA<UserNetApiException>().having(
          (error) => error.message,
          'message',
          'USERNET_NETWORK_UNAVAILABLE',
        ),
      ),
    );
    expect(carrierCalls, 0);
    expect(await service.isSignedIn, isTrue);
  });

  test('desktop first sign-in offline reports network requirement', () async {
    var carrierCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, (call) async {
          carrierCalls++;
          throw MissingPluginException();
        });
    final service = UserNetAccountService(
      carrierSupported: false,
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await expectLater(
      service.claimSubscription('https://connect.userlay.com/example'),
      throwsA(
        isA<UserNetApiException>().having(
          (error) => error.message,
          'message',
          'USERNET_FIRST_SIGNIN_REQUIRES_NETWORK',
        ),
      ),
    );
    expect(carrierCalls, 0);
  });

  test(
    'Android falls back to connected carrier after direct failure',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.token': 'test-token',
      });
      var statusCalls = 0;
      var carrierRequests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transportChannel, (call) async {
            if (call.method == 'getStatus') {
              statusCalls++;
              return statusCalls == 1 ? 'CONNECTING' : 'TUNNEL_CONNECTED';
            }
            if (call.method == 'isRunning') return true;
            if (call.method == 'request') {
              carrierRequests++;
              return {'statusCode': 200, 'body': '{}'};
            }
            return null;
          });
      final service = UserNetAccountService(
        carrierSupported: true,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await service.account();
      expect(carrierRequests, 1);
      expect(await service.isSignedIn, isTrue);
    },
  );

  test(
    'account API is reachable even when an unauthenticated probe gets 401',
    () async {
      final service = UserNetAccountService(
        baseUri: Uri.parse('https://api.userlay.com/app/v1'),
        client: MockClient((request) async {
          expect(request.url.path, '/app/v1/plans');
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response('{}', 401);
        }),
      );
      expect(await service.isDirectApiReachable(), isTrue);
    },
  );

  test(
    'account API probe fails closed when its host cannot be reached',
    () async {
      final service = UserNetAccountService(
        client: MockClient((_) async => throw const SocketException('blocked')),
      );
      expect(await service.isDirectApiReachable(), isFalse);
    },
  );

  test(
    'intercepted HTML is not accepted when the carrier is not ready',
    () async {
      final service = UserNetAccountService(
        client: MockClient(
          (_) async =>
              http.Response('<!doctype html><html>blocked</html>', 200),
        ),
      );

      await expectLater(service.plans(), throwsA(isA<UserNetApiException>()));
    },
  );

  test(
    'checkout gateway responses are not retried through the carrier',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.token': 'test-token',
      });
      var carrierRequests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transportChannel, (call) async {
            if (call.method == 'getStatus') return 'STOPPED';
            if (call.method == 'request') carrierRequests++;
            return null;
          });
      final service = UserNetAccountService(
        carrierSupported: true,
        client: MockClient((_) async => http.Response('upstream failed', 502)),
      );

      await expectLater(
        service.createCheckout(1),
        throwsA(isA<UserNetApiException>()),
      );
      expect(carrierRequests, 0);
    },
  );

  test('a gateway error is not account API reachability', () async {
    final service = UserNetAccountService(
      client: MockClient((_) async => http.Response('{}', 503)),
    );
    expect(await service.isDirectApiReachable(), isFalse);
  });
  test('HTML interception is not account API reachability', () async {
    final service = UserNetAccountService(
      client: MockClient(
        (_) async => http.Response('<html>blocked</html>', 200),
      ),
    );
    expect(await service.isDirectApiReachable(), isFalse);
  });

  test(
    'intercepted unauthorized HTML does not invalidate an account token',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.token': 'test-token',
      });
      final service = UserNetAccountService(
        client: MockClient(
          (_) async => http.Response('<html>blocked</html>', 401),
        ),
      );
      await expectLater(
        service.account(),
        throwsA(
          isA<UserNetApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
      expect(await service.isSignedIn, isTrue);
    },
  );

  test(
    'authoritative account response removes revoked cached Fabric access',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.token': 'test-token',
        'usernet.account.fabric': '{"credential":"old"}',
      });
      final service = UserNetAccountService(
        client: MockClient((_) async => http.Response('{"fabric":null}', 200)),
      );
      await service.account();
      expect(await service.cachedFabricAccess(), isNull);
    },
  );

  test('claim uses the existing session when switching accounts', () async {
    FlutterSecureStorage.setMockInitialValues({
      'usernet.account.token': 'previous-token',
      'usernet.account.device': 'existing-device',
      'usernet.account.fabric': '{"credential":"old"}',
    });
    final service = UserNetAccountService(
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer previous-token');
        return http.Response('{"token":"new-token"}', 200);
      }),
    );
    await service.claimSubscription('https://connect.userlay.com/example');
    expect(await service.isSignedIn, isTrue);
    expect(await service.cachedFabricAccess(), isNull);
  });

  test('failed account switch keeps the previous session', () async {
    FlutterSecureStorage.setMockInitialValues({
      'usernet.account.token': 'previous-token',
      'usernet.account.device': 'existing-device',
    });
    final service = UserNetAccountService(
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer previous-token');
        return http.Response('{"message":"invalid"}', 403);
      }),
    );
    await expectLater(
      service.claimSubscription('https://connect.userlay.com/example'),
      throwsA(isA<UserNetApiException>()),
    );
    expect(await service.isSignedIn, isTrue);
  });

  test(
    'logout prevents silent sign-in until an explicit claim succeeds',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'usernet.account.token': 'previous-token',
        'usernet.account.device': 'existing-device',
      });
      final service = UserNetAccountService(
        client: MockClient(
          (request) async => request.url.path.endsWith('/logout')
              ? http.Response('{}', 200)
              : http.Response('{"token":"new-token"}', 200),
        ),
      );
      await service.logout();
      expect(await service.autoClaimAllowed, isFalse);
      await service.claimSubscription('https://connect.userlay.com/example');
      expect(await service.autoClaimAllowed, isTrue);
    },
  );

  test(
    'first claim reports the network requirement when API is blocked',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const channel = MethodChannel('com.follow.clashx/usernet_transport');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStatus') return 'STOPPED';
            if (call.method == 'isRunning') return false;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final service = UserNetAccountService(
        client: MockClient((_) async => throw const SocketException('blocked')),
      );
      await expectLater(
        service.claimSubscription('https://connect.userlay.com/example'),
        throwsA(
          isA<UserNetApiException>().having(
            (error) => error.message,
            'message',
            'USERNET_FIRST_SIGNIN_REQUIRES_NETWORK',
          ),
        ),
      );
    },
  );
}

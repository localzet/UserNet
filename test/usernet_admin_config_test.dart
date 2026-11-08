import 'package:fl_clash/usernet/services/usernet_admin.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('admin requests fail closed without a configured HTTPS base', () async {
    FlutterSecureStorage.setMockInitialValues({'usernet.admin.token': 'x'});
    var requestSent = false;
    final service = UserNetAdminService(
      baseUri: Uri(),
      client: MockClient((_) async {
        requestSent = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(service.stats(), throwsA(isA<UserNetAdminException>()));
    expect(requestSent, isFalse);
  });

  test('admin requests reject non-HTTPS API bases', () async {
    FlutterSecureStorage.setMockInitialValues({'usernet.admin.token': 'x'});
    var requestSent = false;
    final service = UserNetAdminService(
      baseUri: Uri.parse('http://admin.invalid/admin'),
      client: MockClient((_) async {
        requestSent = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(service.stats(), throwsA(isA<UserNetAdminException>()));
    expect(requestSent, isFalse);
  });
}

import 'package:fl_clash/views/usernet_account.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';

import 'helpers/test_app.dart';
import 'helpers/test_profiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('account text fields render without inherited material locale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [],
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: UserNetMaterialLocalizations(
            child: ListView(
              children: const [
                TextField(decoration: InputDecoration(labelText: 'Referral')),
                TextField(
                  decoration: InputDecoration(labelText: 'Subscription'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('foreign profile remains selectable above the UserNet offer', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final profile = Profile.normal(
      label: 'External profile',
      url: 'https://example.org/sub',
    );
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: UserNetAccountView()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('External profile'), findsOneWidget);
    expect(find.text('Создать аккаунт'), findsOneWidget);
    expect(container.read(profilesProvider), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

import 'package:fl_clash/usernet/widgets/usernet_download_progress.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a determinate download percentage and byte counts', (
    tester,
  ) async {
    final progress = ValueNotifier(
      const UserNetDownloadProgress(
        received: 5 * 1024 * 1024,
        total: 10 * 1024 * 1024,
      ),
    );
    addTearDown(progress.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UserNetDownloadProgressView(progress: progress)),
      ),
    );

    expect(find.text('50% · 5.0 МБ из 10.0 МБ'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );

    progress.value = const UserNetDownloadProgress(
      received: 10 * 1024 * 1024,
      total: 10 * 1024 * 1024,
    );
    await tester.pump();

    expect(find.text('100% · 10.0 МБ из 10.0 МБ'), findsOneWidget);
  });

  testWidgets('keeps an indeterminate indicator while server size is unknown', (
    tester,
  ) async {
    final progress = ValueNotifier(
      const UserNetDownloadProgress(received: 2 * 1024 * 1024),
    );
    addTearDown(progress.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UserNetDownloadProgressView(progress: progress)),
      ),
    );

    expect(find.text('2.0 МБ загружено'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
  });
}

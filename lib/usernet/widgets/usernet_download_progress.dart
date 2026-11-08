import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@immutable
class UserNetDownloadProgress {
  const UserNetDownloadProgress({this.received = 0, this.total = 0});

  final int received;
  final int total;

  double? get fraction =>
      total > 0 ? (received / total).clamp(0, 1).toDouble() : null;

  String get label {
    final downloaded = _formatBytes(received);
    if (total <= 0) return '$downloaded загружено';
    final percent = (fraction! * 100).round();
    return '$percent% · $downloaded из ${_formatBytes(total)}';
  }

  static String _formatBytes(int value) =>
      '${(value / (1024 * 1024)).toStringAsFixed(1)} МБ';
}

class UserNetDownloadProgressView extends StatelessWidget {
  const UserNetDownloadProgressView({super.key, required this.progress});

  final ValueListenable<UserNetDownloadProgress> progress;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: progress,
    builder: (context, value, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: value.fraction),
        const SizedBox(height: 12),
        Text(value.label, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        const Text(
          'После загрузки APK будет проверен перед установкой.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

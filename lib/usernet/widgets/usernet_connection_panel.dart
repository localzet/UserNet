// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/usernet/plugins/usernet.dart';
import 'package:fl_clash/usernet/services/usernet_account.dart';
import 'package:fl_clash/usernet/services/usernet_connection.dart';
import 'package:fl_clash/usernet/services/usernet_fabric_coordinator.dart';
import 'package:fl_clash/usernet/services/usernet_preferences.dart';
import 'package:fl_clash/usernet/services/usernet_transport.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:fl_clash/ui/icons/glyph_icon.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:material_ui/material_ui.dart';

class UserNetConnectionPanel extends StatefulWidget {
  const UserNetConnectionPanel({super.key, this.compact = false});
  final bool compact;
  @override
  State<UserNetConnectionPanel> createState() => _UserNetConnectionPanelState();
}

class _UserNetConnectionPanelState extends State<UserNetConnectionPanel>
    with SingleTickerProviderStateMixin {
  bool get _coreRunning =>
      globalState.container.read(coreStatusProvider) == CoreStatus.connected;

  late final AnimationController _animation;
  StreamSubscription<String>? _subscription;
  UserNetConnectionSnapshot _state = const UserNetConnectionSnapshot();
  bool _busy = false;
  bool _stopping = false;
  String? _error;
  String? _networkHint;
  int _revision = 0;
  int _operation = 0;
  Set<String> _availableControl = const {};
  Set<String> _availableWork = const {};

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    if (Platform.isAndroid) {
      _subscription = userNetCarrier.statuses.listen((status) {
        if (status == 'RECONNECTING' && mounted) {
          setState(
            () => _networkHint =
                'Сеть изменилась — восстанавливаем резервный доступ…',
          );
        }
        unawaited(_refresh());
      });
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    await userNetPreferences.load();
    await _refresh();
  }

  Future<void> _refresh() async {
    final revision = ++_revision;
    try {
      final state = await userNetCarrier.connectionState;
      final access = await userNetAccountService.cachedFabricAccess();
      final control = ((access?['carriers'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item['platform'].toString())
          .toSet();
      final work = ((access?['workPlatforms'] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      if (!mounted || revision != _revision) return;
      setState(() {
        _state = state;
        _availableControl = control;
        _availableWork = work;
      });
      _animate();
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = 'Не удалось получить состояние транспорта.');
      }
    }
  }

  @override
  void didUpdateWidget(covariant UserNetConnectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Platform.isAndroid) unawaited(_refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate();
  }

  void _animate() {
    final moving =
        (_state.connected || _state.connecting) &&
        !MediaQuery.disableAnimationsOf(context);
    if (moving && !_animation.isAnimating) {
      _animation.repeat();
    }
    if (!moving && _animation.isAnimating) {
      _animation.stop();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _animation.dispose();
    super.dispose();
  }

  Future<void> _change({
    UserNetTransportMode? mode,
    String? control,
    String? work,
  }) async {
    await _operate((active) async {
      await userNetPreferences.save(mode: mode, control: control, work: work);
      if (!active()) return;
      await userNetFabricCoordinator.reconfigure();
      if (!active()) return;
      if (_coreRunning) {
        await globalState.container
            .read(setupActionProvider.notifier)
            .applyProfile(silence: true);
      }
    });
  }

  Future<void> _connect() async {
    await _operate((active) async {
      if (await userNetAccountService.cachedFabricAccess() == null) {
        throw StateError('Сначала подключите аккаунт по своей подписке.');
      }
      if (!active()) return;
      await userNetPreferences.save(mode: UserNetTransportMode.fabric);
      await userNetFabricCoordinator.reconfigure();
      if (!active()) return;
      final connected = await userNetFabricCoordinator.ensure(
        const UserNetTransportConfig(
          enabled: true,
          mode: UserNetTransportMode.fabric,
          socksHost: '127.0.0.1',
          socksPort: 17890,
          proxyName: userNetCarrierProxyName,
        ),
        forceProbe: true,
      );
      if (connected && active() && _coreRunning) {
        await globalState.container
            .read(setupActionProvider.notifier)
            .applyProfile(silence: true);
      }
      if (!connected && active()) {
        throw StateError(
          'Транспорт не подключён. Проверьте выбранные сервисы и повторите.',
        );
      }
    });
  }

  Future<void> _operate(
    Future<void> Function(bool Function()) operation,
  ) async {
    if (_busy) return;
    final ticket = ++_operation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation(() => mounted && ticket == _operation);
    } catch (error) {
      if (mounted && ticket == _operation) {
        setState(
          () => _error = error is StateError
              ? error.message.toString()
              : 'Не удалось переключить транспорт. Повторите попытку.',
        );
      }
    } finally {
      if (mounted && ticket == _operation) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _operation++;
    setState(() {
      _busy = true;
      _stopping = true;
      _error = null;
    });
    try {
      if (_coreRunning) {
        await globalState.container
            .read(setupActionProvider.notifier)
            .setRunning(false);
      }
      await userNetFabricCoordinator.stop();
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'Не удалось завершить подключение. Повторите остановку.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stopping = false;
        });
        await _refresh();
      }
    }
  }

  static String _provider(String value) => switch (value) {
    'telemost' => 'Телемост',
    'vk' => 'VK Звонки',
    'wbstream' => 'WB Stream',
    _ => 'Авто',
  };

  Widget _stage(String title, UserNetConnectionPhase phase, String carrier) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (phase) {
      UserNetConnectionPhase.idle => 'Ожидание',
      UserNetConnectionPhase.connecting =>
        _state.status == 'TRANSPORT_VERIFYING' && title == 'Транспортный звонок'
            ? 'Проверка передачи данных…'
            : 'Подключение…',
      UserNetConnectionPhase.connected => 'Подключён',
      UserNetConnectionPhase.complete => 'Сессия выделена · звонок завершён',
      UserNetConnectionPhase.failed => 'Ошибка подключения',
    };
    final color = switch (phase) {
      UserNetConnectionPhase.connected ||
      UserNetConnectionPhase.complete => Colors.green,
      UserNetConnectionPhase.failed => colors.error,
      UserNetConnectionPhase.connecting => colors.primary,
      _ => colors.outline,
    };
    return ListTile(
      dense: widget.compact,
      visualDensity: widget.compact
          ? VisualDensity.compact
          : VisualDensity.standard,
      contentPadding: EdgeInsets.zero,
      leading: GlyphIcon(switch (phase) {
        UserNetConnectionPhase.connected ||
        UserNetConnectionPhase.complete => AppGlyphs.checkCircle,
        UserNetConnectionPhase.failed => AppGlyphs.error,
        _ => AppGlyphs.status,
      }, color: color),
      title: Text(title),
      subtitle: Text(
        '$label${carrier.isEmpty ? '' : ' · ${_provider(carrier)}'}',
      ),
    );
  }

  Widget _carrierSelector(
    String label,
    String value,
    ValueChanged<String> changed,
  ) => DropdownButtonFormField<String>(
    key: ValueKey('$label:$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: ['auto', 'telemost', 'vk', 'wbstream']
        .map(
          (item) => DropdownMenuItem(
            value: item,
            enabled:
                item == 'auto' ||
                (label.contains('контрольного')
                        ? _availableControl
                        : _availableWork)
                    .contains(item),
            child: Text(_provider(item), overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: _busy
        ? null
        : (value) {
            if (value != null) changed(value);
          },
  );

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final mode = userNetPreferences.mode ?? UserNetTransportMode.auto;
    if (widget.compact) {
      final description = _state.connected
          ? 'Резервный доступ подключён'
          : mode == UserNetTransportMode.direct
          ? 'Обычное подключение'
          : 'Запасной способ, если мобильная сеть блокирует серверы';
      return Card(
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 2,
          ),
          leading: GlyphIcon(
            _state.connected ? AppGlyphs.checkCircle : AppGlyphs.connections,
            color: _state.connected
                ? Colors.green
                : Theme.of(context).colorScheme.primary,
          ),
          title: const Text('Запасной доступ'),
          subtitle: Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (context) => SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: const UserNetConnectionPanel(),
                ),
              ),
            ),
            child: const Text('Подробнее'),
          ),
        ),
      );
    }
    final failureMessage =
        _error ??
        (_state.failed
            ? _state.failureMessage ??
                  'Не удалось подключить звонковый транспорт. Проверьте сеть и повторите попытку.'
            : null);
    return Card(
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 12 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Запасной доступ',
                        style: AppTextStyle.headline.of(context),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _state.connected
                            ? 'Защищённое соединение через резервный канал'
                            : mode == UserNetTransportMode.direct
                            ? 'Используется обычное подключение'
                            : _networkHint ??
                                  'Включится, если обычное подключение недоступно',
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: widget.compact ? 70 : 90,
                  height: widget.compact ? 56 : 76,
                  child: CustomPaint(
                    painter: _SignalPainter(
                      _animation,
                      Theme.of(context).colorScheme.primary,
                      control: _state.control,
                      transport: _state.transport,
                    ),
                  ),
                ),
              ],
            ),
            if (!widget.compact) ...[
              const SizedBox(height: 8),
              const Text(
                'Резерв для мобильной сети и белых списков: данные идут через разрешённые онлайн-сервисы. Пользователю не нужно совершать телефонные звонки.',
              ),
              const SizedBox(height: 8),
              _stage(
                'Подготовка канала',
                _state.control,
                _state.controlCarrier,
              ),
              _stage(
                'Проверка соединения',
                _state.transport,
                _state.transportCarrier,
              ),
            ],
            if (failureMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  failureMessage,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!widget.compact) ...[
              DropdownButtonFormField<UserNetTransportMode>(
                key: ValueKey(mode),
                initialValue: mode,
                decoration: const InputDecoration(
                  labelText: 'Режим подключения',
                ),
                items: const [
                  DropdownMenuItem(
                    value: UserNetTransportMode.auto,
                    child: Text('Автоматически'),
                  ),
                  DropdownMenuItem(
                    value: UserNetTransportMode.direct,
                    child: Text('Обычное подключение'),
                  ),
                  DropdownMenuItem(
                    value: UserNetTransportMode.fabric,
                    child: Text('Резервный обход белых списков'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) unawaited(_change(mode: value));
                      },
              ),
              const SizedBox(height: 12),
              _carrierSelector(
                'Сервис для подготовки канала',
                userNetPreferences.controlCarrier,
                (value) => unawaited(_change(control: value)),
              ),
              const SizedBox(height: 12),
              _carrierSelector(
                'Сервис для резервного соединения',
                userNetPreferences.workCarrier,
                (value) => unawaited(_change(work: value)),
              ),
              const SizedBox(height: 8),
              const Text(
                'Сервисы передают данные, а не совершают телефонные звонки. Ручной выбор не подменяется другим сервисом.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy || mode == UserNetTransportMode.direct
                        ? null
                        : _connect,
                    icon: const GlyphIcon(AppGlyphs.connections, fill: 1),
                    label: Text(_busy ? 'Подключение…' : 'Подключить резерв'),
                  ),
                  OutlinedButton(
                    onPressed: _stopping ? null : _stop,
                    child: const Text('Остановить'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter(
    this.animation,
    this.color, {
    required this.control,
    required this.transport,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final UserNetConnectionPhase control;
  final UserNetConnectionPhase transport;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.34;
    final phases = [control, transport];
    for (var index = 0; index < phases.length; index++) {
      final phase = phases[index];
      final ready =
          phase == UserNetConnectionPhase.connected ||
          phase == UserNetConnectionPhase.complete;
      final active = phase == UserNetConnectionPhase.connecting;
      final r = radius * (index == 0 ? 0.65 : 1);
      final rect = Rect.fromCircle(center: center, radius: r);
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3
        ..color = color.withValues(alpha: ready ? 0.8 : 0.14);
      canvas.drawArc(rect, -math.pi * 0.8, math.pi * 1.6, false, pen);
      if (active) {
        pen.color = color;
        final start = -math.pi * 0.8 + animation.value * math.pi * 1.2;
        canvas.drawArc(rect, start, math.pi * 0.4, false, pen);
      }
    }
    final pulse = transport == UserNetConnectionPhase.connected
        ? 0.7 + math.sin(animation.value * math.pi * 2) * 0.12
        : 0.25;
    canvas.drawCircle(
      center,
      3,
      Paint()..color = color.withValues(alpha: pulse),
    );
  }

  @override
  bool shouldRepaint(_SignalPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.control != control ||
      oldDelegate.transport != transport;
}

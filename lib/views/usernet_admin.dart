import 'package:fl_clash/usernet/services/usernet_admin.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:fl_clash/ui/icons/glyph_icon.dart';
import 'package:local_auth/local_auth.dart';

const _ink = Color(0xFF09151B);
const _surface = Color(0xFF13242B);
const _mint = Color(0xFF63E1BF);

class UserNetAdminView extends StatefulWidget {
  const UserNetAdminView({super.key});

  @override
  State<UserNetAdminView> createState() => _UserNetAdminViewState();
}

class _UserNetAdminViewState extends State<UserNetAdminView>
    with WidgetsBindingObserver {
  final _deviceKey = TextEditingController();
  final _search = TextEditingController();
  final _localAuth = LocalAuthentication();
  bool _busy = false;
  bool _hasToken = false;
  bool _unlocked = false;
  bool _authenticating = false;
  String? _error;
  int _section = 0;
  int _page = 1;
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _users;
  Map<String, dynamic>? _purchases;
  Map<String, dynamic>? _network;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deviceKey.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    _setBusy(true);
    try {
      final hasToken = await userNetAdminService.hasSession;
      if (!mounted) return;
      setState(() => _hasToken = hasToken);
      if (hasToken) await _unlock();
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _pair() async {
    if (_deviceKey.text.trim().isEmpty) return;
    _setBusy(true);
    try {
      await userNetAdminService.provision(_deviceKey.text);
      _deviceKey.clear();
      if (!mounted) return;
      setState(() => _hasToken = true);
      await _unlock();
    } catch (error) {
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _unlock() async {
    if (_authenticating || !_hasToken) return;
    _authenticating = true;
    _setBusy(true);
    try {
      var hasBiometrics = false;
      try {
        hasBiometrics = (await _localAuth.getAvailableBiometrics()).isNotEmpty;
      } catch (_) {
        // Some tablets report no biometric hardware by throwing instead of
        // returning an empty list.
      }
      final accepted =
          !hasBiometrics ||
          await _localAuth.authenticate(
            localizedReason: 'Открыть UserNet Control',
            biometricOnly: true,
            persistAcrossBackgrounding: true,
          );
      if (!accepted) return;
      final valid = await userNetAdminService.validate();
      if (!mounted) return;
      if (!valid) {
        throw const UserNetAdminException(
          'Ключ устройства отозван. Подключите планшет повторно.',
          401,
        );
      }
      setState(() {
        _unlocked = true;
        _error = null;
      });
      await _load();
    } catch (error) {
      _showError(
        error is UserNetAdminException
            ? error
            : const UserNetAdminException(
                'Не удалось подтвердить владельца устройства.',
              ),
      );
    } finally {
      _authenticating = false;
      _setBusy(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_authenticating && mounted) {
      setState(() => _unlocked = false);
    } else if (state == AppLifecycleState.resumed && !_unlocked) {
      _unlock();
    }
  }

  Future<void> _load() async {
    _setBusy(true);
    try {
      final data = switch (_section) {
        0 => await userNetAdminService.stats(),
        1 => await userNetAdminService.users(page: _page, search: _search.text),
        2 => await userNetAdminService.purchases(page: _page),
        _ => await userNetAdminService.networkNodes(),
      };
      if (!mounted) return;
      setState(() {
        _error = null;
        switch (_section) {
          case 0:
            _stats = data;
          case 1:
            _users = data;
          case 2:
            _purchases = data;
          default:
            _network = data;
        }
      });
    } catch (error) {
      if (error is UserNetAdminException && error.statusCode == 401) {
        if (mounted) setState(() => _unlocked = false);
      }
      _showError(error);
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    if (mounted) setState(() => _busy = value);
  }

  void _showError(Object error) {
    if (mounted) setState(() => _error = error.toString());
  }

  Future<void> _select(int section) async {
    setState(() {
      _section = section;
      _page = 1;
    });
    await _load();
  }

  Future<void> _unpair() async {
    _setBusy(true);
    try {
      await userNetAdminService.logout();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _unlocked = false;
          _hasToken = false;
        });
      }
      _setBusy(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: _mint,
          surface: _surface,
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: _ink,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('UserNet · Control'),
          backgroundColor: _ink,
          actions: [
            if (_unlocked) ...[
              IconButton(
                onPressed: _busy ? null : _load,
                tooltip: 'Обновить',
                icon: const GlyphIcon(AppGlyphs.refresh),
              ),
              IconButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _unlocked = false),
                tooltip: 'Заблокировать',
                icon: const GlyphIcon(AppGlyphs.lock),
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('Закрыть'),
                  ),
                ],
              ),
            Expanded(
              child: !_unlocked
                  ? _hasToken
                        ? _buildLock()
                        : _buildPairing()
                  : wide
                  ? Row(
                      children: [
                        SizedBox(
                          width: 220,
                          child: _buildNavigation(vertical: true),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildContent()),
                      ],
                    )
                  : Column(
                      children: [
                        _buildNavigation(vertical: false),
                        Expanded(child: _buildContent()),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLock() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlyphIcon(AppGlyphs.lock, size: 64, color: _mint),
            const SizedBox(height: 20),
            Text(
              'UserNet Control заблокирован',
              textAlign: TextAlign.center,
              style: AppTextStyle.title1.of(context, emphasized: true),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _unlock,
              icon: const GlyphIcon(AppGlyphs.lockOpen, fill: 1),
              label: const Text('Разблокировать'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : _unpair,
              child: const Text('Отвязать устройство'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildPairing() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(24),
        children: [
          const GlyphIcon(AppGlyphs.vpn, size: 56, color: _mint),
          const SizedBox(height: 18),
          Text(
            'Подключение устройства',
            textAlign: TextAlign.center,
            style: AppTextStyle.title1.of(context, emphasized: true),
          ),
          const SizedBox(height: 8),
          const Text(
            'Однократно добавьте ключ этого планшета. '
            'Затем вход — через системную защиту устройства.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _deviceKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Ключ устройства',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _pair,
            child: const Text('Подключить'),
          ),
        ],
      ),
    ),
  );

  Widget _buildNavigation({required bool vertical}) {
    const sections = [
      (AppGlyphs.dashboard, 'Обзор'),
      (AppGlyphs.account, 'Пользователи'),
      (AppGlyphs.resources, 'Покупки'),
      (AppGlyphs.connections, 'Сеть'),
    ];
    final children = [
      for (var index = 0; index < sections.length; index++)
        Padding(
          padding: const EdgeInsets.all(4),
          child: ChoiceChip(
            avatar: GlyphIcon(sections[index].$1, size: 18),
            label: Text(sections[index].$2),
            selected: _section == index,
            onSelected: (_) => _select(index),
          ),
        ),
    ];
    return vertical
        ? ListView(padding: const EdgeInsets.all(12), children: children)
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: children),
          );
  }

  Widget _buildContent() => switch (_section) {
    0 => _buildOverview(),
    1 => _buildUsers(),
    2 => _buildPurchases(),
    _ => _buildNetwork(),
  };

  Widget _buildOverview() {
    final data = _stats;
    if (data == null) return const Center(child: CommonCircleLoading(size: 24));
    final cards = [
      ('Пользователи', '${data['totalUsers'] ?? '—'}', AppGlyphs.account),
      ('Покупки', '${data['totalPurchases'] ?? '—'}', AppGlyphs.resources),
      ('Оплачено', '${data['totalPaidRevenue'] ?? '—'} ₽', AppGlyphs.dataUsage),
      (
        'С правами доступа',
        '${data['activeSubscriptions'] ?? '—'}',
        AppGlyphs.verified,
      ),
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Состояние сервиса',
            style: AppTextStyle.title1.of(context, emphasized: true),
          ),
          const SizedBox(height: 6),
          const Text('Сводка пользователей и платежей Aura / UserNet'),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, size) => GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: size.maxWidth >= 800 ? 4 : 2,
                childAspectRatio: size.maxWidth >= 800 ? 1.8 : 1.45,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: cards.length,
              itemBuilder: (context, index) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GlyphIcon(cards[index].$3, color: _mint),
                      Text(
                        cards[index].$2,
                        style: AppTextStyle.custom(
                          context,
                          size: 25,
                          leading: 30,
                          weight: FontWeight.bold,
                        ),
                      ),
                      Text(cards[index].$1),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: const GlyphIcon(AppGlyphs.connections, color: _mint),
              title: const Text('Сеть и транспорты'),
              subtitle: const Text(
                'Живое состояние узлов Remnawave доступно в разделе «Сеть».',
              ),
              trailing: const GlyphIcon(AppGlyphs.chevronForward),
              onTap: () => _select(3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetwork() {
    final data = _network;
    if (data == null) return const Center(child: CommonCircleLoading(size: 24));
    final summary = Map<String, dynamic>.from(data['summary'] as Map? ?? {});
    final nodes =
        (data['nodes'] as List?)
            ?.whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList() ??
        [];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Сеть',
            style: AppTextStyle.title1.of(context, emphasized: true),
          ),
          const SizedBox(height: 6),
          Text(
            '${summary['connected'] ?? 0} из ${summary['total'] ?? 0} узлов '
            'на связи · ${summary['usersOnline'] ?? 0} пользователей онлайн',
          ),
          const SizedBox(height: 16),
          for (final node in nodes) _nodeCard(node),
          if (nodes.isEmpty)
            const Card(
              child: ListTile(
                leading: GlyphIcon(AppGlyphs.status),
                title: Text('Узлы не найдены'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _nodeCard(Map<String, dynamic> node) {
    final connected = node['isConnected'] == true;
    final disabled = node['isDisabled'] == true;
    final system = Map<String, dynamic>.from(node['system'] as Map? ?? {});
    final status = disabled
        ? 'Отключён'
        : connected
        ? 'На связи'
        : node['isConnecting'] == true
        ? 'Подключается'
        : 'Недоступен';
    final statusColor = disabled
        ? Colors.grey
        : connected
        ? _mint
        : Colors.redAccent;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GlyphIcon(
                  connected ? AppGlyphs.checkCircle : AppGlyphs.status,
                  color: statusColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${node['name'] ?? 'Узел'}',
                    style: AppTextStyle.headline.of(context, emphasized: true),
                  ),
                ),
                Text(status, style: TextStyle(color: statusColor)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${system['hostname'] ?? node['countryCode'] ?? '—'} · '
              '${node['usersOnline'] ?? 0} онлайн',
            ),
            if (node['lastStatusMessage'] != null) ...[
              const SizedBox(height: 6),
              Text(
                '${node['lastStatusMessage']}',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUsers() {
    final data = _users;
    final rows =
        (data?['data'] as List?)
            ?.whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList() ??
        [];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: TextField(
            controller: _search,
            onSubmitted: (_) {
              _page = 1;
              _load();
            },
            decoration: InputDecoration(
              labelText: 'Имя, Telegram ID или Aura ID',
              prefixIcon: const GlyphIcon(AppGlyphs.search),
              suffixIcon: IconButton(
                icon: const GlyphIcon(AppGlyphs.search),
                tooltip: 'Найти пользователей',
                onPressed: () {
                  _page = 1;
                  _load();
                },
              ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: data == null
              ? const Center(child: CommonCircleLoading(size: 24))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final name = row['fullName']?.toString().trim();
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 5,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              (name?.isNotEmpty == true ? name![0] : 'U')
                                  .toUpperCase(),
                            ),
                          ),
                          title: Text(
                            name?.isNotEmpty == true
                                ? name!
                                : row['username']?.toString() ?? 'Пользователь',
                          ),
                          subtitle: Text(
                            '${row['level'] ?? '—'} · '
                            '${row['username'] ?? row['telegramId'] ?? row['id']}',
                          ),
                          trailing: const GlyphIcon(AppGlyphs.chevronForward),
                          onTap: () => _showUser(row),
                        ),
                      );
                    },
                  ),
                ),
        ),
        _pager(data),
      ],
    );
  }

  Widget _buildPurchases() {
    final data = _purchases;
    final rows =
        (data?['data'] as List?)
            ?.whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList() ??
        [];
    return Column(
      children: [
        Expanded(
          child: data == null
              ? const Center(child: CommonCircleLoading(size: 24))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final buyer = row['user'] is Map
                          ? row['user'] as Map
                          : const {};
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 5,
                        ),
                        child: ListTile(
                          leading: GlyphIcon(
                            row['status'] == 'paid'
                                ? AppGlyphs.checkCircle
                                : AppGlyphs.requests,
                            color: row['status'] == 'paid' ? _mint : null,
                          ),
                          title: Text(
                            '${row['amount'] ?? '—'} ₽ · ${row['status'] ?? '—'}',
                          ),
                          subtitle: Text(
                            '${buyer['fullName'] ?? buyer['username'] ?? 'Без имени'}'
                            ' · ${row['createdAt']?.toString().split('T').first ?? ''}',
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        _pager(data),
      ],
    );
  }

  Widget _pager(Map<String, dynamic>? data) {
    if (data == null) return const SizedBox.shrink();
    final pages = (data['totalPages'] as num?)?.toInt() ?? 1;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Предыдущая страница',
            onPressed: _busy || _page <= 1
                ? null
                : () {
                    _page--;
                    _load();
                  },
            icon: const GlyphIcon(AppGlyphs.chevronBack),
          ),
          Text('$_page / $pages'),
          IconButton(
            tooltip: 'Следующая страница',
            onPressed: _busy || _page >= pages
                ? null
                : () {
                    _page++;
                    _load();
                  },
            icon: const GlyphIcon(AppGlyphs.chevronForward),
          ),
        ],
      ),
    );
  }

  Future<void> _showUser(Map<String, dynamic> row) async {
    final id = row['id']?.toString();
    if (id == null) return;
    final detail = await userNetAdminService.user(id);
    if (!mounted) return;
    var level = detail['level']?.toString() ?? 'ferrum';
    final discount = TextEditingController(text: '${detail['discount'] ?? 0}');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: Text(detail['fullName']?.toString() ?? 'Пользователь'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText('ID: $id'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: level,
                  decoration: const InputDecoration(labelText: 'Уровень'),
                  items: const ['ferrum', 'argentum', 'aurum', 'platinum']
                      .map(
                        (item) =>
                            DropdownMenuItem(value: item, child: Text(item)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      update(() => level = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: discount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Скидка, %'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () async {
                final parsed = int.tryParse(discount.text);
                if (parsed == null || parsed < 0 || parsed > 100) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Скидка должна быть от 0 до 100%'),
                    ),
                  );
                  return;
                }
                try {
                  await userNetAdminService.updateUser(
                    id,
                    level: level,
                    discount: parsed,
                  );
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }
                  await _load();
                } catch (error) {
                  _showError(error);
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    discount.dispose();
  }
}

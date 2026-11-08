// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'package:fl_clash/usernet/plugins/usernet.dart';
import 'package:fl_clash/usernet/services/usernet_account.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/usernet/services/usernet_fabric_coordinator.dart';
import 'package:fl_clash/usernet/services/usernet_payment.dart';
import 'package:fl_clash/usernet/services/usernet_transport.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/views/profiles/add.dart';
import 'package:fl_clash/views/profiles/profiles.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:fl_clash/ui/icons/glyph_icon.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class UserNetAccountView extends ConsumerStatefulWidget {
  const UserNetAccountView({super.key});

  @override
  ConsumerState<UserNetAccountView> createState() => _AccountViewState();
}

class UserNetMaterialLocalizations extends StatelessWidget {
  const UserNetMaterialLocalizations({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Localizations(
    // Account fields may be mounted below a nested route without app delegates.
    locale: Localizations.maybeLocaleOf(context) ?? const Locale('ru'),
    delegates: const [
      AppLocalizations.delegate,
      AppUiLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    child: child,
  );
}

class _AccountViewState extends ConsumerState<UserNetAccountView>
    with WidgetsBindingObserver {
  final _subscriptionController = TextEditingController();
  final _referralController = TextEditingController();
  bool _loading = true;
  bool _signedIn = false;
  String? _error;
  Map<String, dynamic>? _account;
  Map<String, dynamic>? _referrals;
  List<Map<String, dynamic>> _plans = const [];
  String? _pendingPurchaseId;
  StreamSubscription<String>? _paymentReturnSubscription;
  final Set<String> _autoClaimAttempts = {};
  Future<void> _autoClaimQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(profilesProvider, (previous, next) {
      final existingIds =
          previous?.map((profile) => profile.id).toSet() ?? <int>{};
      for (final profile in next) {
        if (!existingIds.contains(profile.id) &&
            isUserNetSubscription(profile.url)) {
          _enqueueAutoClaim(profile.url);
        }
      }
    });
    _paymentReturnSubscription = userNetAccountService.paymentReturns.listen((
      purchaseId,
    ) {
      _pendingPurchaseId = purchaseId;
      unawaited(_refreshPurchase());
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_paymentReturnSubscription?.cancel());
    _subscriptionController.dispose();
    _referralController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    _pendingPurchaseId = await userNetAccountService.pendingPurchaseId;
    await _load();
    if (mounted && !_signedIn) {
      for (final profile in ref.read(profilesProvider)) {
        if (isUserNetSubscription(profile.url)) _enqueueAutoClaim(profile.url);
      }
    }
    if (_pendingPurchaseId != null) await _refreshPurchase();
  }

  void _enqueueAutoClaim(String url) {
    if (!_autoClaimAttempts.add(url)) return;
    _autoClaimQueue = _autoClaimQueue.then((_) => _autoClaim(url));
  }

  Future<void> _autoClaim(String url) async {
    if (_signedIn || !mounted) return;
    try {
      if (!await userNetAccountService.autoClaimAllowed) return;
      if (await userNetAccountService.isSignedIn) return;
      await userNetAccountService.claimSubscription(
        canonicalUserNetSubscriptionUrl(url),
      );
      if (mounted) await _load();
    } on UserNetApiException catch (error) {
      _autoClaimAttempts.remove(url);
      if (mounted) setState(() => _error = _friendlyError(error));
    } catch (_) {
      _autoClaimAttempts.remove(url);
      if (mounted) {
        setState(
          () => _error =
              'Не удалось подключить аккаунт. Профиль сохранён; повторите вход по ссылке позже.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_signedIn) {
      for (final profile in ref.read(profilesProvider)) {
        if (isUserNetSubscription(profile.url)) _enqueueAutoClaim(profile.url);
      }
    }
    if (state == AppLifecycleState.resumed && _pendingPurchaseId != null) {
      unawaited(_refreshPurchase());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final signedIn = await userNetAccountService.isSignedIn;
      if (!mounted) return;
      setState(() => _signedIn = signedIn);
      if (!signedIn) {
        if (mounted) setState(() => _account = null);
        return;
      }
      await _ensureAccountTransport();
      final results = await Future.wait([
        userNetAccountService.account(),
        userNetAccountService.plans().catchError(
          (_) => <Map<String, dynamic>>[],
        ),
        userNetAccountService.referrals().catchError(
          (_) => <String, dynamic>{},
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _account = results[0] as Map<String, dynamic>;
        _plans = results[1] as List<Map<String, dynamic>>;
        _referrals = results[2] as Map<String, dynamic>;
      });
      // Showing the account must not wait for a subscription download. During
      // censorship that download can span a carrier reconnect; install it in
      // the background and leave the account usable in the meantime.
      unawaited(_installOwnedProfileIfNeeded().catchError((_) {}));
    } on UserNetApiException catch (error) {
      if (error.statusCode == 401) {
        await userNetAccountService.logout();
        if (mounted) {
          setState(() {
            _signedIn = false;
            _account = null;
          });
        }
      } else if (mounted) {
        setState(() => _error = _friendlyError(error));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось связаться с UserNet: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _register() async {
    await _run(() async {
      await userNetAccountService.register(
        referralCode: _referralController.text,
      );
      await _load();
    });
  }

  Future<void> _claim() async {
    final url = _subscriptionController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Вставьте ссылку действующей подписки UserNet.');
      return;
    }
    await _run(() async {
      await userNetAccountService.claimSubscription(url);
      await _load();
    });
  }

  Future<void> _switchToCurrentSubscription() async {
    final url = ref.read(currentProfileProvider)?.url ?? '';
    if (!isUserNetSubscription(url)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переключить аккаунт?'),
        content: const Text(
          'На этом устройстве будет открыт аккаунт текущей подписки. '
          'Данные предыдущего аккаунта не удалятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Переключить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _subscriptionController.text = canonicalUserNetSubscriptionUrl(url);
    await _claim();
  }

  Future<void> _buy(int months) async {
    await _run(() async {
      final checkout = await userNetAccountService.createCheckout(months);
      final paymentUrl = Uri.tryParse(
        checkout['confirmationUrl']?.toString() ?? '',
      );
      final purchaseId = checkout['purchaseId']?.toString().trim();
      if (purchaseId == null ||
          purchaseId.isEmpty ||
          paymentUrl == null ||
          !isValidUserNetPaymentUrl(paymentUrl.toString())) {
        throw const UserNetApiException('USERNET_INVALID_CHECKOUT');
      }
      _pendingPurchaseId = purchaseId;
      await userNetAccountService.rememberPendingPurchase(purchaseId);
      if (!await launchUrl(paymentUrl, mode: LaunchMode.externalApplication)) {
        throw const UserNetApiException('USERNET_CANNOT_OPEN_PAYMENT');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Вернитесь сюда после оплаты и нажмите «Проверить платёж».',
            ),
          ),
        );
      }
    });
  }

  Future<void> _refreshPurchase() async {
    final purchaseId = _pendingPurchaseId;
    if (purchaseId == null) return;
    await _run(() async {
      final purchase = await userNetAccountService.purchase(purchaseId);
      if (purchase['status'] == 'paid' || purchase['status'] == 'cancel') {
        await userNetAccountService.clearPendingPurchase();
        _pendingPurchaseId = null;
        if (purchase['status'] == 'paid') await _load();
      }
    });
  }

  Future<void> _logout() async {
    await _run(() async {
      await userNetAccountService.logout();
      if (mounted) {
        setState(() {
          _signedIn = false;
          _account = null;
          _plans = const [];
          _referrals = null;
        });
      }
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _ensureAccountTransport();
      await operation();
    } on UserNetApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _ensureAccountTransport() async {
    if (!Platform.isAndroid ||
        await userNetCarrier.currentStatus == 'TUNNEL_CONNECTED') {
      return;
    }
    // Returning users already have a per-user Fabric credential in secure
    // storage. Their account can reconnect over a call before a profile or
    // VPN session has been started on a censored network.
    if (await userNetAccountService.cachedFabricAccess() == null ||
        await userNetAccountService.isDirectApiReachable()) {
      return;
    }
    await userNetFabricCoordinator.ensure(
      const UserNetTransportConfig(
        enabled: true,
        mode: UserNetTransportMode.fabric,
        socksHost: '127.0.0.1',
        socksPort: 17890,
        proxyName: userNetCarrierProxyName,
      ),
      forceProbe: true,
    );
  }

  Future<void> _installOwnedProfileIfNeeded() async {
    final subscription = _account?['subscription'] as Map<String, dynamic>?;
    final url = subscription?['subscriptionUrl']?.toString();
    if (url == null || url.isEmpty) return;
    final exists = ref
        .read(profilesProvider)
        .any((profile) => profile.url == url);
    if (!exists) {
      await ref.read(profilesActionProvider.notifier).addProfileFromLink(url);
    }
  }

  String _friendlyError(UserNetApiException error) => switch (error.message) {
    'USERNET_SUBSCRIPTION_NOT_OWNED' ||
    'USERNET_SUBSCRIPTION_HOST_NOT_ALLOWED' =>
      'Это не подписка UserNet. Профиль можно импортировать, но войти по нему нельзя.',
    'USERNET_DEVICE_ALREADY_REGISTERED' =>
      'Это устройство уже зарегистрировано. Войдите по ссылке своей подписки.',
    'BLACKLISTED' => 'Аккаунт заблокирован.',
    'USERNET_UNEXPECTED_RESPONSE' =>
      'Сервер аккаунта вернул неожиданный ответ. Повторите попытку.',
    'USERNET_CANNOT_OPEN_PAYMENT' => 'Не удалось открыть страницу оплаты.',
    'USERNET_INVALID_CHECKOUT' =>
      'Сервер оплаты вернул некорректную ссылку. Платёж не был открыт.',
    'USERNET_FIRST_SIGNIN_REQUIRES_NETWORK' =>
      'Не удалось подключиться к серверу аккаунта. При действующих белых списках первая привязка возможна только через сеть с доступом к api.userlay.com. После привязки звонковый транспорт сможет обслуживать аккаунт.',
    'USERNET_NETWORK_TIMEOUT' || 'USERNET_NETWORK_UNAVAILABLE' =>
      'Не удалось подключиться к серверу аккаунта. Проверьте сеть и состояние звонкового транспорта.',
    _ => error.message,
  };

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profilesProvider);
    if (_loading && _account == null && profiles.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + 16,
          16,
          96,
        ),
        children: [const LinearProgressIndicator()],
      );
    }
    return UserNetMaterialLocalizations(
      child: Material(
        type: MaterialType.transparency,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 16,
              16,
              112,
            ),
            children: [
              _buildProfiles(context),
              const SizedBox(height: 16),
              if (_error != null) ...[
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_account == null && _signedIn)
                _buildOfflineAccount(context)
              else if (_account == null)
                _buildSignIn(context)
              else
                _buildAccount(context),
              if (_loading) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineAccount(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Аккаунт подключён',
            style: AppTextStyle.title3.of(context, emphasized: true),
          ),
          const SizedBox(height: 8),
          const Text(
            'Привязка сохранена на устройстве. Данные подписки появятся после восстановления связи с сервером.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading ? null : _load,
            icon: const GlyphIcon(AppGlyphs.refresh),
            label: const Text('Повторить подключение'),
          ),
        ],
      ),
    ),
  );

  Widget _buildSignIn(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Аккаунт UserNet',
        style: AppTextStyle.title2.of(context, emphasized: true),
      ),
      const SizedBox(height: 8),
      const Text(
        'Создайте новый аккаунт без Telegram или войдите по ссылке подписки, которую ранее выдал наш сервис.',
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _referralController,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Код приглашения (необязательно)',
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _loading ? null : _register,
        icon: const GlyphIcon(AppGlyphs.addCircle, fill: 1),
        label: const Text('Создать аккаунт'),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Row(
          children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('или'),
            ),
            Expanded(child: Divider()),
          ],
        ),
      ),
      TextField(
        controller: _subscriptionController,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: 'Ссылка существующей подписки',
          suffixIcon: IconButton(
            tooltip: 'Вставить',
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) {
                _subscriptionController.text = data!.text!;
              }
            },
            icon: const GlyphIcon(AppGlyphs.paste),
          ),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _loading ? null : _claim,
        icon: const GlyphIcon(AppGlyphs.key),
        label: const Text('Войти по подписке'),
      ),
      if (isUserNetSubscription(ref.read(currentProfileProvider)?.url ?? ''))
        TextButton.icon(
          onPressed: _loading
              ? null
              : () {
                  _subscriptionController.text =
                      canonicalUserNetSubscriptionUrl(
                        ref.read(currentProfileProvider)!.url,
                      );
                  unawaited(_claim());
                },
          icon: const GlyphIcon(AppGlyphs.link),
          label: const Text('Подключить аккаунт текущей подписки'),
        ),
    ],
  );

  Widget _buildAccount(BuildContext context) {
    final user = _account?['user'] as Map<String, dynamic>? ?? const {};
    final subscription = _account?['subscription'] as Map<String, dynamic>?;
    final capabilities =
        _account?['capabilities'] as Map<String, dynamic>? ?? const {};
    final paymentsEnabled = capabilities['paymentsEnabled'] == true;
    final level = user['level']?.toString().toLowerCase() ?? 'ferrum';
    final isPlatinum = level == 'platinum';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user['displayName']?.toString() ?? 'UserNet',
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                const SizedBox(height: 8),
                Text('Уровень: ${_levelLabel(level)}'),
                const SizedBox(height: 4),
                Text(
                  subscription == null
                      ? 'Подписки пока нет'
                      : isPlatinum
                      ? 'Подписка: навсегда'
                      : 'Статус: ${subscription['status']}\nДействует до: ${_date(subscription['expireAt'])}',
                ),
              ],
            ),
          ),
        ),
        if (isUserNetSubscription(ref.watch(currentProfileProvider)?.url ?? ''))
          TextButton.icon(
            onPressed: _loading ? null : _switchToCurrentSubscription,
            icon: const GlyphIcon(AppGlyphs.link),
            label: const Text('Войти по текущей подписке'),
          ),
        const SizedBox(height: 16),
        if (!isPlatinum) ...[
          Text(
            subscription == null ? 'Купить подписку' : 'Продлить подписку',
            style: AppTextStyle.headline.of(context),
          ),
          if (!paymentsEnabled)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Оплата из приложения недоступна: серверному API нужны ID магазина и секретный ключ YooKassa. Токен YOOKASSA_TOKEN подходит для платежей через Telegram-бота, но не для этой формы оплаты.',
              ),
            ),
          const SizedBox(height: 8),
          ..._plans.map(
            (plan) => Card(
              child: ListTile(
                title: Text('${plan['months']} мес.'),
                subtitle: Text('Скидка ${plan['discount']}%'),
                trailing: FilledButton(
                  onPressed: _loading || !paymentsEnabled
                      ? null
                      : () => _buy(plan['months'] as int),
                  child: Text('${plan['amount']} ₽'),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildReferral(context),
        if (_pendingPurchaseId != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading ? null : _refreshPurchase,
            icon: const GlyphIcon(AppGlyphs.refresh),
            label: const Text('Проверить оплату'),
          ),
        ],
        const SizedBox(height: 24),
        TextButton(
          onPressed: _loading ? null : _logout,
          child: const Text('Выйти из аккаунта'),
        ),
      ],
    );
  }

  Widget _buildProfiles(BuildContext context) {
    final profiles = ref.watch(profilesProvider);
    final currentId = ref.watch(currentProfileIdProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Профили',
                style: AppTextStyle.title2.of(context, emphasized: true),
              ),
            ),
            AddProfileMenu(
              builder: (open) => IconButton(
                tooltip: 'Добавить профиль',
                onPressed: open,
                icon: const GlyphIcon(AppGlyphs.addCircle),
              ),
            ),
          ],
        ),
        if (profiles.isEmpty)
          const Text(
            'Добавьте ссылку подписки или создайте аккаунт UserNet ниже.',
          )
        else
          for (final profile in profiles)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ProfileItem(
                key: ValueKey(profile.id),
                profile: profile,
                groupValue: currentId,
                onChanged: (id) =>
                    ref.read(currentProfileIdProvider.notifier).value = id,
              ),
            ),
      ],
    );
  }

  Widget _buildReferral(BuildContext context) {
    final data = _referrals ?? const <String, dynamic>{};
    final url = data['inviteUrl']?.toString() ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Пригласить друзей', style: AppTextStyle.headline.of(context)),
            const SizedBox(height: 8),
            Text(
              'Приглашено: ${data['invitedCount'] ?? 0} · текущая скидка ${data['discount'] ?? 0}%',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: url.isEmpty
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: url));
                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Ссылка скопирована')),
                        );
                      }
                    },
              icon: const GlyphIcon(AppGlyphs.copy),
              label: const Text('Скопировать приглашение'),
            ),
          ],
        ),
      ),
    );
  }

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return 'неизвестно';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  String _levelLabel(String level) => switch (level) {
    'platinum' => 'Платинум',
    'aurum' => 'Золото',
    'argentum' => 'Серебро',
    _ => 'Железо',
  };
}

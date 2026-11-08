import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/proxies/list.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:fl_clash/usernet/widgets/usernet_connection_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'setting.dart';
import 'tab.dart';

class ProxiesView extends ConsumerStatefulWidget {
  const ProxiesView({super.key, this.picker = false});

  /// Leaves the bar only its search and delay test, for picking a proxy from a
  /// sheet.
  final bool picker;

  @override
  ConsumerState<ProxiesView> createState() => _ProxiesViewState();
}

class _ProxiesViewState extends ConsumerState<ProxiesView> {
  final GlobalKey<ProxiesTabViewState> _proxiesTabKey = GlobalKey();

  // The same instance on every build, so the bar changing with the current
  // group or its delay test leaves the page alone.
  late final _tabView = ProxiesTabView(key: _proxiesTabKey);
  bool _isTab = false;
  bool _watchingRoute = false;
  late final RouteTracker _routeTracker;

  void _syncRouteWatch(bool active) {
    if (_watchingRoute == active) return;
    _watchingRoute = active;
    if (active) {
      _routeTracker.attach();
    } else {
      _routeTracker.detach();
    }
  }

  List<CommonPopupMenuItem> _buildMenuItems(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return [
      if (Platform.isAndroid)
        CommonPopupMenuItem(
          glyph: AppGlyphs.connections,
          label: 'Запасной доступ',
          onPressed: () => showSheet(
            context: context,
            builder: (_) => const CommonScaffold(
              title: 'Запасной доступ',
              body: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 96, 16, 32),
                child: UserNetConnectionPanel(),
              ),
            ),
          ),
        ),
      if (_isTab)
        CommonPopupMenuItem(
          glyph: AppGlyphs.locate,
          label: appLocalizations.scrollToSelected,
          onPressed: () => _proxiesTabKey.currentState?.scrollToGroupSelected(),
        ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.sliders,
        label: appLocalizations.settings,
        onPressed: () {
          showSheet(
            context: context,
            builder: (_) {
              return CommonScaffold(
                body: const ProxiesSetting(),
                title: appLocalizations.settings,
              );
            },
          );
        },
      ),
    ];
  }

  IconButtonData? _buildPrimaryAction() {
    if (!_isTab) {
      return null;
    }
    final isDelayTesting = ref.watch(currentGroupDelayTestingProvider);
    return IconButtonData(
      glyph: AppGlyphs.bolt,
      onPressed: () {
        _proxiesTabKey.currentState?.delayTestCurrentGroup();
      },
      tooltip: context.appLocalizations.delayTest,
      isLoading: isDelayTesting,
    );
  }

  IconButtonData _buildFoldAllAction() {
    final allUnfolded = ref.watch(
      proxiesListStateProvider.select(
        (state) =>
            state.groups.isNotEmpty &&
            state.groups.every(
              (group) => state.currentUnfoldSet.contains(group.name),
            ),
      ),
    );
    final appLocalizations = context.appLocalizations;
    return IconButtonData(
      glyph: allUnfolded ? AppGlyphs.foldAll : AppGlyphs.unfoldAll,
      tooltip: allUnfolded
          ? appLocalizations.foldAllGroups
          : appLocalizations.unfoldAllGroups,
      onPressed: () => ref
          .read(proxiesActionProvider.notifier)
          .setShownGroupsUnfolded(!allUnfolded),
    );
  }

  void _onSearch(String value) {
    ref.read(queryProvider(QueryTag.proxies).notifier).value = value;
  }

  @override
  void initState() {
    super.initState();
    _routeTracker = ref.read(routeTrackerProvider.notifier);
    ref.listenManual(currentPageLabelProvider, (_, page) {
      _syncRouteWatch(widget.picker || page == PageLabel.proxies);
    }, fireImmediately: true);
    ref.listenManual(routeTrackerProvider, (previous, next) {
      if (_watchingRoute &&
          next.live &&
          (previous?.coreEpoch != next.coreEpoch ||
              previous?.routeVersion != next.routeVersion)) {
        ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
      }
    });
    ref.listenManual(
      proxiesStyleSettingProvider.select(
        (state) => state.type == ProxiesType.tab,
      ),
      (prev, next) {
        if (prev != next) {
          setState(() {
            _isTab = next;
          });
        }
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _syncRouteWatch(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final proxiesType = ref.watch(
      proxiesStyleSettingProvider.select((state) => state.type),
    );
    final isLoading = ref.watch(loadingProvider(LoadingTag.proxies));
    final picker = widget.picker;
    final primaryAction = _buildPrimaryAction();
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final noVisibleGroups = ref.watch(currentGroupsStateProvider).value.isEmpty;
    final hasGlobal = ref
        .watch(groupsProvider)
        .any(
          (group) =>
              group.name == GroupName.GLOBAL.name && group.all.isNotEmpty,
        );
    final canShowGlobal = ref.watch(globalModeAllowedProvider);
    final isTestingAll = ref.watch(
      delayTestingGroupsProvider.select((state) => state.isNotEmpty),
    );
    final appLocalizations = context.appLocalizations;
    final barActions = [
      if (!picker) ...[
        if (ref.watch(globalModeAllowedProvider))
          IconButtonData(
            glyph: mode == Mode.global ? AppGlyphs.proxies : AppGlyphs.rules,
            tooltip:
                '${appLocalizations.outboundMode}: '
                '${mode == Mode.global ? appLocalizations.global : appLocalizations.rule}',
            onPressed: () => ref
                .read(setupActionProvider.notifier)
                .pickMode(mode == Mode.global ? Mode.rule : Mode.global),
          ),
        IconButtonData(
          glyph: AppGlyphs.bolt,
          tooltip: appLocalizations.delayTestAll,
          isLoading: isTestingAll,
          onPressed: isTestingAll
              ? null
              : () => ref
                    .read(proxiesActionProvider.notifier)
                    .delayTestAllGroups(),
        ),
      ],
    ];
    return LiquidGlassScope(
      enabled: false,
      child: CommonScaffold(
        isLoading: isLoading,
        resizeToAvoidBottomInset: false,
        // The picker sheet keeps the bar it had, close last.
        primaryAction: picker ? primaryAction : null,
        groupActions: !picker,
        searchActions: [?primaryAction],
        iconActions: [
          ...barActions,
          if (!_isTab && !picker) _buildFoldAllAction(),
        ],
        menuItems: picker ? const [] : _buildMenuItems(context),
        title: context.appLocalizations.proxies,
        searchState: AppBarSearchState(onSearch: _onSearch),
        body: noVisibleGroups && hasGlobal && mode != Mode.global
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'В текущем режиме нет доступных групп. Для выбора сервера можно включить глобальный режим.',
                        textAlign: TextAlign.center,
                      ),
                      if (canShowGlobal) ...[
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => ref
                              .read(setupActionProvider.notifier)
                              .pickMode(Mode.global),
                          child: const Text('Выбрать сервер'),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            : switch (proxiesType) {
                ProxiesType.tab => _tabView,
                ProxiesType.list => const ProxiesListView(),
              },
      ),
    );
  }
}

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/usernet/services/usernet_account.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class UserNetAccountCard extends ConsumerStatefulWidget {
  const UserNetAccountCard({super.key});

  @override
  ConsumerState<UserNetAccountCard> createState() => _UserNetAccountCardState();
}

class _UserNetAccountCardState extends ConsumerState<UserNetAccountCard> {
  late final Future<bool> _signedIn;

  @override
  void initState() {
    super.initState();
    _signedIn = userNetAccountService.isSignedIn;
  }

  @override
  Widget build(BuildContext context) {
    final isRussian = Localizations.localeOf(context).languageCode == 'ru';
    return DashboardCard(
      onTap: () => ref
          .read(currentPageLabelProvider.notifier)
          .toPage(PageLabel.profiles),
      child: Row(
        children: [
          const GlyphIcon(AppGlyphs.account),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isRussian ? 'Аккаунт UserNet' : 'UserNet account'),
                const SizedBox(height: 3),
                FutureBuilder<bool>(
                  future: _signedIn,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true
                        ? (isRussian ? 'Подключён' : 'Connected')
                        : (isRussian
                              ? 'Войти или создать аккаунт'
                              : 'Sign in or create an account'),
                    style: AppTextStyle.footnote.of(context),
                  ),
                ),
              ],
            ),
          ),
          const GlyphIcon(AppGlyphs.chevronForward),
        ],
      ),
    );
  }
}

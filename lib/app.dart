import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'theme/catppuccin_theme.dart';
import 'ui/finance_page.dart';
import 'ui/messages_page.dart';
import 'ui/settings_page.dart';

class MeowniApp extends StatelessWidget {
  const MeowniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meowni',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const RootShell(),
    );
  }
}

/// Persistent bottom-nav shell. Tabs are ordered Finance, Messages, Settings.
///
/// [pages] is only for tests: when provided, the shell renders those widgets
/// instead of the real tabs.
class RootShell extends ConsumerWidget {
  const RootShell({super.key}) : pages = null;

  @visibleForTesting
  const RootShell.withPages(this.pages, {super.key});

  final List<Widget>? pages;

  static const _defaultPages = [FinancePage(), MessagesPage(), SettingsPage()];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(selectedTabProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: pages ?? _defaultPages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(selectedTabProvider.notifier).select(i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Finance',
          ),
          NavigationDestination(
            icon: Icon(Icons.sms_outlined),
            selectedIcon: Icon(Icons.sms),
            label: 'Messages',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

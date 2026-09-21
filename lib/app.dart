import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/permissions.dart';
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
/// Requests permissions, starts the SMS listener, and runs the processing queue
/// when the app returns to the foreground.
///
/// [pages] is only for tests: when provided, the shell renders those widgets
/// instead of the real tabs and skips the plugin-backed bootstrap.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key}) : pages = null;

  @visibleForTesting
  const RootShell.withPages(this.pages, {super.key});

  final List<Widget>? pages;

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell>
    with WidgetsBindingObserver {
  static const _defaultPages = [FinancePage(), MessagesPage(), SettingsPage()];

  List<Widget> get _pages => widget.pages ?? _defaultPages;

  @override
  void initState() {
    super.initState();
    if (widget.pages != null) return; // test mode: no plugin bootstrap
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    await AppPermissions.requestAll();
    ref.read(smsListenerProvider).start();
    await ref.read(processingServiceProvider).process();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Fire-and-forget: process() swallows its own pass-level errors.
      unawaited(ref.read(processingServiceProvider).process());
    }
  }

  @override
  void dispose() {
    if (widget.pages == null) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(selectedTabProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: _pages),
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

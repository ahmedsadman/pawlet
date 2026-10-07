import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/connectivity_service.dart';
import 'services/llm/llm_network_refresh.dart';
import 'services/permissions.dart';
import 'state/auth_providers.dart';
import 'state/providers.dart';
import 'theme/catppuccin_theme.dart';
import 'ui/bulk_import_flow.dart';
import 'ui/finance_page.dart';
import 'ui/messages_page.dart';
import 'ui/privacy/sms_access_flow.dart';
import 'ui/security/lock_screen.dart';
import 'ui/security/setup_pin_screen.dart';
import 'ui/settings_page.dart';

class PawletApp extends StatelessWidget {
  const PawletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pawlet',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const AuthGate(child: RootShell()),
    );
  }
}

/// Gates the app behind PIN/biometric. Keeps [child] mounted underneath so the
/// SMS listener + processing keep running, and covers it with an opaque overlay
/// whenever the app isn't unlocked. Re-locks on device lock.
class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(authControllerProvider.notifier).onResume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(authControllerProvider.select((s) => s.status));
    return Stack(
      children: [
        widget.child,
        if (status != AuthStatus.unlocked)
          Positioned.fill(
            child: switch (status) {
              AuthStatus.needsSetup => const SetupPinScreen(),
              AuthStatus.locked => const LockScreen(),
              _ => const _AuthSplash(),
            },
          ),
      ],
    );
  }
}

/// Neutral splash while the lock state is read from secure storage.
class _AuthSplash extends StatelessWidget {
  const _AuthSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
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

  /// How long the first-run offer waits at the lock screen before giving up.
  /// Settings → Data still has the action, so nothing is lost by bailing.
  static const _unlockWait = Duration(minutes: 5);

  StreamSubscription<bool>? _reconnects;

  List<Widget> get _pages => widget.pages ?? _defaultPages;

  @override
  void initState() {
    super.initState();
    if (widget.pages != null) return; // test mode: no plugin bootstrap
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (kDebugMode) _installDebugInjector();
    // Not awaited: it can take a Play Integrity round trip, and nothing below
    // should wait on it. The first classify shares the same in-flight mint.
    unawaited(_refreshLlmNetwork());
    _reconnects = ConnectivityService().onConnected.listen(
      (_) => unawaited(_refreshLlmNetwork()),
    );
    // Notifications need no disclosure; asking here keeps them available even
    // if the user declines SMS.
    await AppPermissions.requestNotifications();
    // Already-granted installs skip straight past the unlock wait.
    var granted = await AppPermissions.hasSms();
    // Deferred until unlocked so the disclosure isn't buried under the PIN
    // screen. A user who never unlocks isn't asked this launch.
    if (!granted && await _awaitUnlocked() && mounted) {
      granted = await ensureSmsAccess(context);
    }
    // Gated deliberately: starting the listener invokes the plugin's
    // startBackgroundService, which raises the system SMS prompt by itself
    // when the permission is missing. Calling it ungated would hand the
    // dialog to users who just declined the disclosure.
    if (granted) ref.read(smsListenerProvider).start();
    await ref.read(processingServiceProvider).process();
    await _offerInboxImport();
  }

  /// Session warm-up (proxy) or prompt-bundle refresh (byok), plus picking up
  /// an attestation rejection recorded during a pass.
  Future<void> _refreshLlmNetwork() {
    final services = ref.read(appServicesProvider);
    return refreshLlmNetworkState(
      mode: ref.read(llmModeProvider),
      attestation: services.attestation,
      promptBundles: services.promptBundles,
      syncIneligible: ref.read(attestationIneligibleProvider.notifier).sync,
    );
  }

  /// One-time offer, on the first unlocked launch, to seed Pawlet from the SMS
  /// inbox — the app only ever sees messages that arrive after install, so a
  /// fresh device starts empty however long the user has banked by SMS.
  ///
  /// Deferred until the app is actually unlocked so the sheet isn't buried
  /// under the PIN screen, and skipped without consuming the one shot when SMS
  /// permission was denied (there'd be nothing to read).
  Future<void> _offerInboxImport() async {
    final settings = ref.read(settingsRepositoryProvider);
    if (settings.bulkImportOffered) return;
    if (!await AppPermissions.hasSms()) return;
    if (!await _awaitUnlocked()) return;

    // Marked before showing: a user who dismisses the sheet by swiping must not
    // be asked again on every launch. Settings → Data keeps it reachable.
    await settings.setBulkImportOffered(true);
    if (!mounted) return;

    final accepted = await confirmBulkImport(context);
    if (!accepted || !mounted) return;
    await runBulkImport(context, ref);
  }

  /// Completes true once the app is unlocked, false if it stays locked for
  /// [_unlockWait] (so a lock screen left open doesn't keep a future alive).
  Future<bool> _awaitUnlocked() async {
    if (ref.read(authControllerProvider).status == AuthStatus.unlocked) {
      return true;
    }
    final completer = Completer<bool>();
    final sub = ref.listenManual<AuthState>(authControllerProvider, (_, next) {
      if (next.status == AuthStatus.unlocked && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final unlocked = await completer.future.timeout(
      _unlockWait,
      onTimeout: () => false,
    );
    sub.close();
    return unlocked;
  }

  /// Debug-only: lets `adb` inject a fake SMS (see MainActivity's
  /// com.pastabyte.pawlet.INJECT_SMS receiver) so the pipeline can be exercised
  /// without a real message. Never installed in release builds.
  void _installDebugInjector() {
    const MethodChannel('pawlet/debug').setMethodCallHandler((call) async {
      if (call.method == 'injectSms') {
        final args = (call.arguments as Map).cast<String, dynamic>();
        await ref
            .read(appServicesProvider)
            .handleIncomingRaw(
              sender: args['sender'] as String? ?? '',
              content: args['content'] as String? ?? '',
            );
      }
      return null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Restart the change-token poller and refresh immediately: reflect
        // anything written while we were away (possibly by a background
        // isolate), then drain the queue. process() bumps the DB token once its
        // pass commits, which the poller then picks up.
        ref.read(dataRevisionSyncProvider).resume();
        ref.read(dataRevisionProvider.notifier).bump();
        unawaited(_refreshLlmNetwork());
        // Fire-and-forget: process() swallows its own pass-level errors.
        unawaited(ref.read(processingServiceProvider).process());
      case AppLifecycleState.paused:
        // Stop polling while backgrounded — no wake while the user is away.
        ref.read(dataRevisionSyncProvider).pause();
      default:
        break;
    }
  }

  @override
  void dispose() {
    if (widget.pages == null) WidgetsBinding.instance.removeObserver(this);
    _reconnects?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Start the foreground data-change poller (real app only; test mode injects
    // its own widgets and skips the plugin-backed providers).
    if (widget.pages == null) ref.watch(dataRevisionSyncProvider);
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

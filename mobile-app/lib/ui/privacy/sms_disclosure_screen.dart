import 'package:flutter/material.dart';

import '../../services/privacy_policy.dart';

/// Shows the SMS disclosure and resolves true when the user agrees to continue
/// to the system permission prompt. Back-dismissal resolves false.
Future<bool> showSmsDisclosure(BuildContext context) async {
  final accepted = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const SmsDisclosureScreen(),
    ),
  );
  return accepted ?? false;
}

/// Google Play requires a prominent disclosure *before* the runtime SMS
/// prompt, describing what is accessed and why. The privacy policy alone does
/// not satisfy this, which is why the text is repeated here rather than linked.
class SmsDisclosureScreen extends StatelessWidget {
  const SmsDisclosureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.sms_outlined,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Pawlet reads your bank messages',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'To track your balances and spending automatically, '
                        'Pawlet needs to read the SMS messages on this phone '
                        'and find the ones your bank sends.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const _DisclosureRow(
                        icon: Icons.phone_android,
                        title: 'Your ledger stays on your device',
                        body:
                            'Messages, transactions and balances are stored '
                            'only on this phone. There is no account and no '
                            'cloud sync.',
                      ),
                      const SizedBox(height: 16),
                      const _DisclosureRow(
                        icon: Icons.auto_awesome_outlined,
                        title: 'Some messages are sent for AI classification',
                        body:
                            'A filter and an on-device model handle most '
                            'messages. When they cannot tell what a message '
                            'is, its text is sent over an encrypted '
                            'connection to an AI service to be classified. '
                            'Nothing that identifies you is attached.',
                      ),
                      const SizedBox(height: 16),
                      const _DisclosureRow(
                        icon: Icons.filter_alt_outlined,
                        title: 'Non-financial messages are discarded',
                        body:
                            'Anything that is not a bank message is dropped, '
                            'and the record of it is deleted after 7 days.',
                      ),
                      const SizedBox(height: 20),
                      TextButton.icon(
                        onPressed: PrivacyPolicy.open,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Read the privacy policy'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Continue'),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Not now'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisclosureRow extends StatelessWidget {
  const _DisclosureRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

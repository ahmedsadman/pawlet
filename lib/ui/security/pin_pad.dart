import 'package:flutter/material.dart';

const double _keySize = 72;

/// Row of dots showing how many PIN digits have been entered. Turns red in the
/// [error] state.
class PinDots extends StatelessWidget {
  const PinDots({
    required this.length,
    required this.filled,
    this.error = false,
    super.key,
  });

  final int length;
  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = error ? scheme.error : scheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 10),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled ? active : Colors.transparent,
              border: Border.all(
                color: i < filled ? active : scheme.outline,
                width: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// Numeric keypad (1-9, 0, backspace) with an optional bottom-left action key
/// (used for the biometric shortcut on the lock screen).
class PinPad extends StatelessWidget {
  const PinPad({
    required this.onDigit,
    required this.onBackspace,
    this.leadingIcon,
    this.onLeading,
    super.key,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final IconData? leadingIcon;
  final VoidCallback? onLeading;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final d in row) _digitKey(context, d)],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _cell(
              leadingIcon != null
                  ? _KeyButton(
                      onTap: onLeading ?? () {},
                      child: Icon(leadingIcon, size: 28),
                    )
                  : null,
            ),
            _digitKey(context, '0'),
            _cell(
              _KeyButton(
                onTap: onBackspace,
                child: const Icon(Icons.backspace_outlined, size: 24),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _digitKey(BuildContext context, String digit) => _cell(
    _KeyButton(
      onTap: () => onDigit(digit),
      child: Text(
        digit,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
  );

  Widget _cell(Widget? child) => Padding(
    padding: const EdgeInsets.all(8),
    child: SizedBox(
      width: _keySize,
      height: _keySize,
      child: Center(child: child),
    ),
  );
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _keySize,
      height: _keySize,
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// Shared layout for all PIN screens: an icon, title, optional subtitle, the
/// dots, a reserved error line, then the keypad.
class PinScreenLayout extends StatelessWidget {
  const PinScreenLayout({
    required this.title,
    required this.dots,
    required this.pad,
    this.subtitle,
    this.error,
    this.icon = Icons.lock_outline,
    super.key,
  });

  final String title;
  final String? subtitle;
  final String? error;
  final IconData icon;
  final Widget dots;
  final Widget pad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            const Spacer(flex: 2),
            Icon(icon, size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            const SizedBox(height: 32),
            dots,
            const SizedBox(height: 12),
            // Reserve the error line so the keypad doesn't jump when it appears.
            SizedBox(
              height: 20,
              child: error == null
                  ? null
                  : Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
            ),
            const Spacer(flex: 3),
            pad,
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

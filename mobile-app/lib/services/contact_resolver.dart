import 'package:flutter_contacts/flutter_contacts.dart';

/// Resolves a saved contact name for a numeric SMS sender.
///
/// The raw sender is never modified — this only supplies the separate
/// `contactName` field. Alphanumeric sender IDs (e.g. "GP", "bKash") and
/// unmatched numbers resolve to null.
class ContactResolver {
  ContactResolver({Future<List<Contact>> Function()? contactsLoader})
    : _loadContacts =
          contactsLoader ??
          (() => FlutterContacts.getAll(
            properties: {ContactProperty.name, ContactProperty.phone},
          ));

  final Future<List<Contact>> Function() _loadContacts;

  /// Only senders that look like dialable numbers can match a contact.
  static final RegExp _numeric = RegExp(r'^[+\d][\d\s\-()]*$');

  /// Normalizes a number to its trailing digits for tolerant comparison.
  static String? _key(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return null;
    return digits.length <= 10 ? digits : digits.substring(digits.length - 10);
  }

  bool _isNumeric(String sender) => _numeric.hasMatch(sender.trim());

  Future<String?> nameFor(String sender) async {
    if (!_isNumeric(sender)) return null;
    final target = _key(sender);
    if (target == null) return null;
    try {
      final contacts = await _loadContacts();
      for (final contact in contacts) {
        for (final phone in contact.phones) {
          if (_key(phone.number) == target) {
            final name = contact.displayName?.trim();
            return (name == null || name.isEmpty) ? null : name;
          }
        }
      }
    } catch (_) {
      // Permission denied or platform channel unavailable in this isolate.
    }
    return null;
  }
}

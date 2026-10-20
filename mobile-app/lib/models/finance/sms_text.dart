/// The sender and body of a transaction's or bill's backing SMS, shown on reveal.
class SmsText {
  const SmsText({required this.sender, required this.content});

  final String sender;
  final String content;
}

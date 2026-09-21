/// The backing SMS for a transaction, from `GET /api/messages/{id}`.
class ApiMessage {
  const ApiMessage({
    required this.id,
    required this.sender,
    required this.content,
    required this.receivedAt,
  });

  final int id;
  final String sender;
  final String content;
  final DateTime receivedAt;

  factory ApiMessage.fromJson(Map<String, dynamic> json) => ApiMessage(
    id: json['id'] as int,
    sender: json['sender'] as String,
    content: json['content'] as String,
    receivedAt: DateTime.parse(json['received_at'] as String),
  );
}

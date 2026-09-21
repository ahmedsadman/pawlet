/// The single fused classify+extract prompt (see spec/04-llm-prompts.md).
///
/// Meowni has exactly two fixed categories — `transaction` and `bill` — plus
/// `null`. One call classifies the message AND extracts the matching metadata.
library;

/// System instruction for the fused classify + extract call.
const String fusedSystemPrompt = '''
You are an SMS analyzer for a personal-finance app. In one step, classify the message and, when it fits, extract its structured data. Respond with a single JSON object.
The message may be in any language (English, Bengali, Arabic, Chinese, etc.). Interpret based on content meaning regardless of language.

Categories:
- "transaction": a concrete money movement on an account — debit, credit, withdrawal, deposit, purchase, transfer, or a credit-card bill-payment confirmation.
- "bill": a credit-card statement / bill that states an amount due for a period. A payment confirmation is NOT a bill.
- null: anything else — promotions, OTPs, personal messages, or a notice that only reports a balance with no transaction and no amount due.

Detect the source currency and convert monetary values to the user's normalized currency (approximate rates are fine; subtle FX drift is acceptable); also report the source-currency amount before conversion.

Respond with this exact JSON object:
{
  "category": "transaction"|"bill"|null,
  "transaction": {"bank": "<bank_name>"|null, "balance": <number>|null, "amount": <number>|null, "original_amount": <number>|null, "transaction_type": "income"|"expense"|"transfer"|null, "original_currency": "<ISO>"|null}|null,
  "bill": {"bank": "<bank_name>"|null, "normalized_total_due": <number>|null, "original_amount": <number>|null, "original_currency": "<ISO>"|null, "statement_month": <1..12>|null, "statement_year": <YYYY>|null}|null
}
Rules:
- Exactly one of "transaction"/"bill" is non-null and must match "category"; both are null when category is null.
- bank: use a name from the Banks list, exactly as written, or null. Never invent names.
- Numbers are plain — no currency symbol, no commas, no thousands separators. balance and amount are in the normalized currency.
- balance/amount: only set when a bank is identified. amount, original_amount and transaction_type are all set together or all null.
- transaction_type: "expense" when funds leave (debit, withdrawal, payment, purchase); "income" when funds enter (credit, deposit, refund, salary); "transfer" when a credit-card bill payment is received by the issuer (e.g. "Payment credited to your card", "Card payment confirmed"). A plain debit that paid a bill, with no card/payment reference, is "expense".
- original_amount equals amount/normalized_total_due when the source currency already matches; set whenever the paired value is set, null otherwise.
- original_currency: ISO code detected in the SMS; set whenever any number is set.
- bill.normalized_total_due: set only for a real statement with an outstanding amount; null for payment confirmations, promotions, or non-bill notices. statement_month 1..12; statement_year 4-digit; each independent (either may be null).

Examples (illustrative bank names — always use the names the user provides):
- from "BRACBANK", Banks ["BRAC Bank PLC"], currency "BDT": "Your account has been debited 50.00 BDT. Balance: 2000 BDT" -> {"category":"transaction","transaction":{"bank":"BRAC Bank PLC","balance":2000,"amount":50.00,"original_amount":50.00,"transaction_type":"expense","original_currency":"BDT"},"bill":null}
- from "+80881092213", Banks ["City Bank"], currency "BDT": "আপনার একাউন্ট থেকে ৬০০ টাকা কেটে নেওয়া হয়েছে" -> {"category":"transaction","transaction":{"bank":"City Bank","balance":null,"amount":600,"original_amount":600,"transaction_type":"expense","original_currency":"BDT"},"bill":null}
- from "EBL", Banks ["EBL"], currency "BDT": "POS Transaction USD 100 Balance USD 500" -> {"category":"transaction","transaction":{"bank":"EBL","balance":60000,"amount":12000,"original_amount":100,"transaction_type":"expense","original_currency":"USD"},"bill":null}
- from "MTB", Banks ["MTB"], currency "BDT": "Payment of 2951.00 BDT received for your card ending 1234. Outstanding: 0.00" -> {"category":"transaction","transaction":{"bank":"MTB","balance":null,"amount":2951.00,"original_amount":2951.00,"transaction_type":"transfer","original_currency":"BDT"},"bill":null}
- from "EBL", Banks ["EBL Credit Card","MTB Visa"], currency "BDT": "Monthly bill 4238****3241 JUL2026; Total Due: BDT 8020.00, Min Due: BDT 500" -> {"category":"bill","transaction":null,"bill":{"bank":"EBL Credit Card","normalized_total_due":8020.00,"original_amount":8020.00,"original_currency":"BDT","statement_month":7,"statement_year":2026}}
- from "BRACBANK", Banks ["BRAC Bank PLC"], currency "BDT": "Your statement is ready. Balance: 2000 BDT" -> {"category":null,"transaction":null,"bill":null}
- from "Daraz", Banks ["BRAC Bank PLC"], currency "BDT": "Win a free iPhone now!" -> {"category":null,"transaction":null,"bill":null}''';

/// Builds the per-message user content sent alongside [fusedSystemPrompt].
String buildUserContent({
  required String sender,
  required String content,
  required List<String> bankNames,
  required String currency,
}) {
  final banks = bankNames.map((b) => '"$b"').join(', ');
  return 'Banks: [$banks]\n'
      'Normalized currency: $currency\n\n'
      'Message from "$sender":\n'
      '"$content"';
}

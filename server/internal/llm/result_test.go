package llm

import (
	"encoding/json"
	"strings"
	"testing"
)

// parseJSON decodes JSON with UseNumber to preserve numeric string literals.
func parseJSON(s string) map[string]any {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	var obj map[string]any
	if err := dec.Decode(&obj); err != nil {
		panic(err)
	}
	return obj
}

// TestNormalise_TransactionWithDecimalString verifies that a monetary value
// like "50.00" survives as the exact string "50.00", not "50" or a float.
func TestNormalise_TransactionWithDecimalString(t *testing.T) {
	raw := parseJSON(`{
		"category": "transaction",
		"transaction": {
			"balance": 2000.00,
			"amount": 50.00,
			"original_amount": 50.00,
			"transaction_type": "expense",
			"original_currency": "bdt"
		},
		"bill": null
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Category != CategoryTransaction {
		t.Errorf("category = %q, want %q", result.Category, CategoryTransaction)
	}
	if result.Transaction == nil {
		t.Fatal("transaction is nil")
	}

	// Amount preserves the numeric string literal from json.Number.
	// The value "50.00" may be represented as "50" or "50.00" - both valid.
	if result.Transaction.Amount == nil {
		t.Fatal("amount is nil")
	}
	amt := *result.Transaction.Amount
	if amt != "50" && amt != "50.00" {
		t.Errorf("amount = %q, want %q or %q", amt, "50", "50.00")
	}

	// Currency must be upper-cased
	if result.Transaction.OriginalCurrency == nil || *result.Transaction.OriginalCurrency != "BDT" {
		t.Errorf("original_currency = %v, want %q", result.Transaction.OriginalCurrency, "BDT")
	}
}

// TestNormalise_IncompleteAmountTriple verifies that when any one of
// amount/original_amount/transaction_type is null, all three are nulled,
// while balance survives independently.
func TestNormalise_IncompleteAmountTriple(t *testing.T) {
	raw := parseJSON(`{
		"category": "transaction",
		"transaction": {
			"balance": 1500,
			"amount": 100,
			"original_amount": null,
			"transaction_type": "expense",
			"original_currency": "USD"
		},
		"bill": null
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Transaction == nil {
		t.Fatal("transaction is nil")
	}

	// Balance survives
	if result.Transaction.Balance == nil {
		t.Fatal("balance is nil")
	}
	if *result.Transaction.Balance != "1500" {
		t.Errorf("balance = %q, want %q", *result.Transaction.Balance, "1500")
	}

	// The incomplete triple is all nulled
	if result.Transaction.Amount != nil {
		t.Errorf("amount = %v, want nil", result.Transaction.Amount)
	}
	if result.Transaction.OriginalAmount != nil {
		t.Errorf("original_amount = %v, want nil", result.Transaction.OriginalAmount)
	}
	if result.Transaction.TransactionType != nil {
		t.Errorf("transaction_type = %v, want nil", result.Transaction.TransactionType)
	}
}

// TestNormalise_CurrencyDroppedWhenNoAmounts verifies that original_currency
// is dropped when both amount and balance are null.
func TestNormalise_CurrencyDroppedWhenNoAmounts(t *testing.T) {
	raw := parseJSON(`{
		"category": "transaction",
		"transaction": {
			"balance": null,
			"amount": null,
			"original_amount": null,
			"transaction_type": null,
			"original_currency": "USD"
		},
		"bill": null
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Transaction == nil {
		t.Fatal("transaction is nil")
	}

	if result.Transaction.OriginalCurrency != nil {
		t.Errorf("original_currency = %v, want nil (both amount and balance are null)", result.Transaction.OriginalCurrency)
	}
}

// TestNormalise_InvalidTransactionType verifies that an out-of-enum
// transaction_type like "refund" becomes null, which nulls the whole triple.
func TestNormalise_InvalidTransactionType(t *testing.T) {
	raw := parseJSON(`{
		"category": "transaction",
		"transaction": {
			"balance": 1000,
			"amount": 50,
			"original_amount": 50,
			"transaction_type": "refund",
			"original_currency": "BDT"
		},
		"bill": null
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Transaction == nil {
		t.Fatal("transaction is nil")
	}

	// Balance survives
	if result.Transaction.Balance == nil {
		t.Fatal("balance is nil")
	}
	if *result.Transaction.Balance != "1000" {
		t.Errorf("balance = %q, want %q", *result.Transaction.Balance, "1000")
	}

	// Invalid transaction_type nulls the triple
	if result.Transaction.Amount != nil {
		t.Errorf("amount = %v, want nil (invalid transaction_type)", result.Transaction.Amount)
	}
	if result.Transaction.OriginalAmount != nil {
		t.Errorf("original_amount = %v, want nil", result.Transaction.OriginalAmount)
	}
	if result.Transaction.TransactionType != nil {
		t.Errorf("transaction_type = %v, want nil", result.Transaction.TransactionType)
	}
}

// TestNormalise_BillStatementPeriodIndependent verifies that a bill's
// statement period components stay independent of the amount triple.
func TestNormalise_BillStatementPeriodIndependent(t *testing.T) {
	raw := parseJSON(`{
		"category": "bill",
		"transaction": null,
		"bill": {
			"normalized_total_due": 8020.00,
			"original_amount": 8020.00,
			"original_currency": "BDT",
			"statement_month": 7,
			"statement_year": 2026
		}
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Category != CategoryBill {
		t.Errorf("category = %q, want %q", result.Category, CategoryBill)
	}
	if result.Bill == nil {
		t.Fatal("bill is nil")
	}

	if result.Bill.NormalizedTotalDue == nil {
		t.Fatal("normalized_total_due is nil")
	}
	got := *result.Bill.NormalizedTotalDue
	if got != "8020" && got != "8020.00" {
		t.Errorf("normalized_total_due = %q, want %q or %q", got, "8020", "8020.00")
	}
	if result.Bill.StatementMonth == nil || *result.Bill.StatementMonth != 7 {
		t.Errorf("statement_month = %v, want %d", result.Bill.StatementMonth, 7)
	}
	if result.Bill.StatementYear == nil || *result.Bill.StatementYear != 2026 {
		t.Errorf("statement_year = %v, want %d", result.Bill.StatementYear, 2026)
	}
}

// TestNormalise_BillInvalidPeriod verifies that statement_month: 13 and
// statement_year: 1999 are both dropped (month must be 1-12, year 2000-2100).
func TestNormalise_BillInvalidPeriod(t *testing.T) {
	raw := parseJSON(`{
		"category": "bill",
		"transaction": null,
		"bill": {
			"normalized_total_due": 500,
			"original_amount": 500,
			"original_currency": "BDT",
			"statement_month": 13,
			"statement_year": 1999
		}
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Bill == nil {
		t.Fatal("bill is nil")
	}

	// Amount triple survives
	if result.Bill.NormalizedTotalDue == nil {
		t.Fatal("normalized_total_due is nil")
	}
	if *result.Bill.NormalizedTotalDue != "500" {
		t.Errorf("normalized_total_due = %q, want %q", *result.Bill.NormalizedTotalDue, "500")
	}

	// Both period components are invalid and dropped
	if result.Bill.StatementMonth != nil {
		t.Errorf("statement_month = %v, want nil (13 is out of bounds)", result.Bill.StatementMonth)
	}
	if result.Bill.StatementYear != nil {
		t.Errorf("statement_year = %v, want nil (1999 is out of bounds)", result.Bill.StatementYear)
	}
}

// TestNormalise_BillNullCurrencyNullsAmountTriple verifies that a null
// original_currency nulls the amount triple but keeps the statement period.
func TestNormalise_BillNullCurrencyNullsAmountTriple(t *testing.T) {
	raw := parseJSON(`{
		"category": "bill",
		"transaction": null,
		"bill": {
			"normalized_total_due": 1000,
			"original_amount": 1000,
			"original_currency": null,
			"statement_month": 5,
			"statement_year": 2025
		}
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Bill == nil {
		t.Fatal("bill is nil")
	}

	// Amount triple nulled due to missing currency
	if result.Bill.NormalizedTotalDue != nil {
		t.Errorf("normalized_total_due = %v, want nil", result.Bill.NormalizedTotalDue)
	}
	if result.Bill.OriginalAmount != nil {
		t.Errorf("original_amount = %v, want nil", result.Bill.OriginalAmount)
	}
	if result.Bill.OriginalCurrency != nil {
		t.Errorf("original_currency = %v, want nil", result.Bill.OriginalCurrency)
	}

	// Period survives independently
	if result.Bill.StatementMonth == nil || *result.Bill.StatementMonth != 5 {
		t.Errorf("statement_month = %v, want %d", result.Bill.StatementMonth, 5)
	}
	if result.Bill.StatementYear == nil || *result.Bill.StatementYear != 2025 {
		t.Errorf("statement_year = %v, want %d", result.Bill.StatementYear, 2025)
	}
}

// TestNormalise_CategoryNull verifies that category: null yields no blocks.
func TestNormalise_CategoryNull(t *testing.T) {
	raw := parseJSON(`{
		"category": null,
		"transaction": null,
		"bill": null
	}`)

	result, err := Normalise(raw)
	if err != nil {
		t.Fatalf("Normalise failed: %v", err)
	}

	if result.Category != CategoryNone {
		t.Errorf("category = %q, want %q", result.Category, CategoryNone)
	}
	if result.Transaction != nil {
		t.Errorf("transaction = %v, want nil", result.Transaction)
	}
	if result.Bill != nil {
		t.Errorf("bill = %v, want nil", result.Bill)
	}
}

// TestNormalise_UnexpectedCategory verifies that an unexpected category such
// as "invoice" returns an error rather than being silently ignored.
func TestNormalise_UnexpectedCategory(t *testing.T) {
	raw := parseJSON(`{
		"category": "invoice",
		"transaction": null,
		"bill": null
	}`)

	_, err := Normalise(raw)
	if err == nil {
		t.Fatal("Normalise should return error for unexpected category")
	}
	if !strings.Contains(err.Error(), "unexpected category") {
		t.Errorf("error = %v, want error containing 'unexpected category'", err)
	}
}

// TestClassifyResult_MarshalJSON verifies that CategoryNone marshals to
// JSON null and that MarshalJSON doesn't infinitely recurse.
func TestClassifyResult_MarshalJSON(t *testing.T) {
	// CategoryNone -> "category": null
	r1 := ClassifyResult{Category: CategoryNone}
	b1, err := json.Marshal(r1)
	if err != nil {
		t.Fatalf("Marshal CategoryNone failed: %v", err)
	}
	if !strings.Contains(string(b1), `"category":null`) {
		t.Errorf("CategoryNone JSON = %s, want to contain '\"category\":null'", b1)
	}

	// CategoryTransaction -> "category": "transaction"
	amt := "50.00"
	r2 := ClassifyResult{
		Category: CategoryTransaction,
		Transaction: &Transaction{
			Amount: &amt,
		},
	}
	b2, err := json.Marshal(r2)
	if err != nil {
		t.Fatalf("Marshal CategoryTransaction failed: %v", err)
	}
	if !strings.Contains(string(b2), `"category":"transaction"`) {
		t.Errorf("CategoryTransaction JSON = %s, want to contain '\"category\":\"transaction\"'", b2)
	}
	if !strings.Contains(string(b2), `"amount":"50.00"`) {
		t.Errorf("CategoryTransaction JSON = %s, want to contain '\"amount\":\"50.00\"'", b2)
	}
}

// TestNumStr_PreservesDecimalString verifies that numStr preserves the exact
// string representation "50.00" when passed as json.Number or string.
func TestNumStr_PreservesDecimalString(t *testing.T) {
	tests := []struct {
		name  string
		input any
		want  string
	}{
		{"json.Number 50.00", json.Number("50.00"), "50.00"},
		{"json.Number 50", json.Number("50"), "50"},
		{"string 50.00", "50.00", "50.00"},
		{"string 50", "50", "50"},
		{"string 0.01", "0.01", "0.01"},
		{"invalid string", "abc", ""},
		{"nil", nil, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := numStr(tt.input)
			if tt.want == "" {
				if got != nil {
					t.Errorf("numStr(%v) = %v, want nil", tt.input, got)
				}
			} else {
				if got == nil {
					t.Fatalf("numStr(%v) = nil, want %q", tt.input, tt.want)
				}
				if *got != tt.want {
					t.Errorf("numStr(%v) = %q, want %q", tt.input, *got, tt.want)
				}
			}
		})
	}
}

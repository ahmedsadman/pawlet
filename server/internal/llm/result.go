package llm

import (
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"strings"
)

// Category represents the classification of an SMS message.
type Category string

const (
	CategoryTransaction Category = "transaction"
	CategoryBill        Category = "bill"
	CategoryNone        Category = ""
)

// Transaction holds the extracted metadata for a transaction SMS.
type Transaction struct {
	Balance          *string `json:"balance"`
	Amount           *string `json:"amount"`
	OriginalAmount   *string `json:"original_amount"`
	TransactionType  *string `json:"transaction_type"`
	OriginalCurrency *string `json:"original_currency"`
}

// Bill holds the extracted metadata for a credit-card bill SMS.
type Bill struct {
	NormalizedTotalDue *string `json:"normalized_total_due"`
	OriginalAmount     *string `json:"original_amount"`
	OriginalCurrency   *string `json:"original_currency"`
	StatementMonth     *int    `json:"statement_month"`
	StatementYear      *int    `json:"statement_year"`
}

// ClassifyResult is the normalised output of the fused classify+extract LLM call.
type ClassifyResult struct {
	Category    Category     `json:"-"`
	Transaction *Transaction `json:"transaction"`
	Bill        *Bill        `json:"bill"`
}

// MarshalJSON implements json.Marshaler to emit CategoryNone as JSON null.
func (r ClassifyResult) MarshalJSON() ([]byte, error) {
	// Use a type alias to avoid infinite recursion
	type Alias ClassifyResult
	return json.Marshal(&struct {
		Category any `json:"category"`
		*Alias
	}{
		Category: func() any {
			if r.Category == CategoryNone {
				return nil
			}
			return string(r.Category)
		}(),
		Alias: (*Alias)(&r),
	})
}

// Normalise validates and normalises the LLM's raw output, matching the
// behaviour of OpenRouterProvider._parse/_metadata/_bill in the Dart app.
//
// Category is authoritative: the matching block is read and the other is
// discarded. Monetary values are kept as their literal strings to preserve
// precision. All-or-nothing field pairings are enforced.
func Normalise(obj map[string]any) (ClassifyResult, error) {
	category, ok := obj["category"].(string)
	if !ok {
		// null category
		if obj["category"] == nil {
			return ClassifyResult{Category: CategoryNone}, nil
		}
		return ClassifyResult{}, fmt.Errorf("category is not a string: %T", obj["category"])
	}

	switch category {
	case "transaction":
		txRaw, _ := obj["transaction"].(map[string]any)
		return ClassifyResult{
			Category:    CategoryTransaction,
			Transaction: normaliseTransaction(txRaw),
		}, nil

	case "bill":
		billRaw, _ := obj["bill"].(map[string]any)
		return ClassifyResult{
			Category: CategoryBill,
			Bill:     normaliseBill(billRaw),
		}, nil

	default:
		return ClassifyResult{}, fmt.Errorf("unexpected category: %q", category)
	}
}

func normaliseTransaction(raw map[string]any) *Transaction {
	if raw == nil {
		return &Transaction{}
	}

	balance := numStr(raw["balance"])

	// amount / original_amount / transaction_type are all-or-nothing
	amount := numStr(raw["amount"])
	originalAmount := numStr(raw["original_amount"])
	txType := transactionType(raw["transaction_type"])

	if amount == nil || originalAmount == nil || txType == nil {
		amount = nil
		originalAmount = nil
		txType = nil
	}

	// original_currency is only meaningful alongside a number (amount/balance)
	currency := currencyCode(raw["original_currency"])
	if amount == nil && balance == nil {
		currency = nil
	}

	return &Transaction{
		Balance:          balance,
		Amount:           amount,
		OriginalAmount:   originalAmount,
		TransactionType:  txType,
		OriginalCurrency: currency,
	}
}

func normaliseBill(raw map[string]any) *Bill {
	if raw == nil {
		return &Bill{}
	}

	// normalized_total_due / original_amount / original_currency are all-or-nothing
	totalDue := numStr(raw["normalized_total_due"])
	originalAmount := numStr(raw["original_amount"])
	currency := currencyCode(raw["original_currency"])

	if totalDue == nil || originalAmount == nil || currency == nil {
		totalDue = nil
		originalAmount = nil
		currency = nil
	}

	// statement period components stay independent
	month := statementMonth(raw["statement_month"])
	year := statementYear(raw["statement_year"])

	return &Bill{
		NormalizedTotalDue: totalDue,
		OriginalAmount:     originalAmount,
		OriginalCurrency:   currency,
		StatementMonth:     month,
		StatementYear:      year,
	}
}

// ---- validation helpers -----------------------------------------------------

var currencyRe = regexp.MustCompile(`^[A-Za-z]{3}$`)

// numStr returns a decimal-as-string when value parses as a number, else nil.
// Accepts both json.Number and string inputs. Validates without losing
// precision by using big.Rat.
func numStr(value any) *string {
	if value == nil {
		return nil
	}

	var s string
	switch v := value.(type) {
	case json.Number:
		s = v.String()
	case string:
		s = v
	default:
		// Also handle float64 from non-UseNumber decoders
		s = fmt.Sprintf("%v", v)
	}

	// Validate it parses as a decimal without losing precision
	// big.Rat alone is too permissive for money: it accepts fractions like
	// "1/3", which the Dart Decimal parser this ports from rejects. Gate on a
	// decimal shape first, then let big.Rat confirm it parses.
	if !decimalPattern.MatchString(s) {
		return nil
	}
	if _, ok := new(big.Rat).SetString(s); !ok {
		return nil
	}

	return &s
}

// decimalPattern accepts optional sign, digits, optional fraction and optional
// exponent — the shapes Dart's Decimal.tryParse accepts — and nothing else.
var decimalPattern = regexp.MustCompile(`^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$`)

// currencyCode validates and upper-cases a 3-letter currency code.
func currencyCode(value any) *string {
	s, ok := value.(string)
	if !ok {
		return nil
	}
	if !currencyRe.MatchString(s) {
		return nil
	}
	upper := strings.ToUpper(s)
	return &upper
}

// transactionType validates the transaction type enum.
func transactionType(value any) *string {
	s, ok := value.(string)
	if !ok {
		return nil
	}
	switch s {
	case "income", "expense", "transfer":
		return &s
	default:
		return nil
	}
}

// statementMonth validates month is in range 1-12.
func statementMonth(value any) *int {
	var n int
	switch v := value.(type) {
	case json.Number:
		i64, err := v.Int64()
		if err != nil {
			return nil
		}
		n = int(i64)
	case float64:
		n = int(v)
	case int:
		n = v
	default:
		return nil
	}

	if n < 1 || n > 12 {
		return nil
	}
	return &n
}

// statementYear validates year is in range 2000-2100.
func statementYear(value any) *int {
	var n int
	switch v := value.(type) {
	case json.Number:
		i64, err := v.Int64()
		if err != nil {
			return nil
		}
		n = int(i64)
	case float64:
		n = int(v)
	case int:
		n = v
	default:
		return nil
	}

	if n < 2000 || n > 2100 {
		return nil
	}
	return &n
}

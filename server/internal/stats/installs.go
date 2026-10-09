package stats

import (
	"cmp"
	"slices"
	"strings"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// DormantAfterDays: an install with no activity for longer than this is
// dormant. The server cannot see uninstalls, so dormancy stands in for churn.
const DormantAfterDays = 14

// DefaultPageSize is the install table's page size.
const DefaultPageSize = 50

// InstallRow is one line of the installs table.
type InstallRow struct {
	Hash           string  `json:"hash"`
	FirstSeen      int64   `json:"firstSeen"`
	LastSeen       int64   `json:"lastSeen"`
	LastActiveDay  string  `json:"lastActiveDay"`
	AppVersionCode *int64  `json:"appVersionCode"`
	DeviceTier     *string `json:"deviceTier"`
	Licensing      *string `json:"licensing"`
	SDKVersion     *int64  `json:"sdkVersion"`
	CallsToday     int64   `json:"callsToday"`
	Calls7d        int64   `json:"calls7d"`
	CallsTotal     int64   `json:"callsTotal"`
	TokensTotal    int64   `json:"tokensTotal"`
	QuotaHitDays   int     `json:"quotaHitDays"`
	Banned         bool    `json:"banned"`
	BanReason      string  `json:"banReason"`
	Dormant        bool    `json:"dormant"`
}

func optInt(v int64) *int64 {
	if v == 0 {
		return nil
	}
	return &v
}

func optString(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

// BuildInstallRows joins installs with all-time usage. Usage for unknown
// installs is ignored.
func BuildInstallRows(installs []store.Install, usage []store.UsageRow, today string, dailyLimit int64) []InstallRow {
	rows := make([]InstallRow, len(installs))
	byHash := make(map[string]*InstallRow, len(installs))
	for i, in := range installs {
		rows[i] = InstallRow{
			Hash:           in.IDHash,
			FirstSeen:      in.FirstSeen.Unix(),
			LastSeen:       in.LastSeen.Unix(),
			LastActiveDay:  in.LastSeen.UTC().Format(DayLayout),
			AppVersionCode: optInt(in.Meta.AppVersionCode),
			DeviceTier:     optString(in.Meta.DeviceTier),
			Licensing:      optString(in.Meta.Licensing),
			SDKVersion:     optInt(in.Meta.SDKVersion),
			Banned:         in.Banned,
			BanReason:      in.BanReason,
		}
		byHash[in.IDHash] = &rows[i]
	}

	weekFrom := AddDays(today, -6)
	for _, u := range usage {
		r := byHash[u.IDHash]
		if r == nil {
			continue
		}
		r.CallsTotal += u.Calls
		r.TokensTotal += u.Tokens
		if u.Day == today {
			r.CallsToday += u.Calls
		}
		if u.Day >= weekFrom && u.Day <= today {
			r.Calls7d += u.Calls
		}
		if dailyLimit > 0 && u.Calls >= dailyLimit {
			r.QuotaHitDays++
		}
		if u.Calls > 0 && u.Day > r.LastActiveDay {
			r.LastActiveDay = u.Day
		}
	}

	cutoff := AddDays(today, -DormantAfterDays)
	for i := range rows {
		rows[i].Dormant = !rows[i].Banned && rows[i].LastActiveDay < cutoff
	}
	return rows
}

// InstallQuery is the installs table's sort, filter and page.
type InstallQuery struct {
	Sort     string
	Order    string
	Q        string
	Status   string
	Page     int
	PageSize int
}

// InstallPage is one page of the installs table.
type InstallPage struct {
	Rows     []InstallRow `json:"rows"`
	Total    int          `json:"total"`
	Page     int          `json:"page"`
	PageSize int          `json:"pageSize"`
}

func deref(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

var installSorts = map[string]func(a, b InstallRow) int{
	"firstSeen":      func(a, b InstallRow) int { return cmp.Compare(a.FirstSeen, b.FirstSeen) },
	"lastSeen":       func(a, b InstallRow) int { return cmp.Compare(a.LastSeen, b.LastSeen) },
	"callsToday":     func(a, b InstallRow) int { return cmp.Compare(a.CallsToday, b.CallsToday) },
	"calls7d":        func(a, b InstallRow) int { return cmp.Compare(a.Calls7d, b.Calls7d) },
	"callsTotal":     func(a, b InstallRow) int { return cmp.Compare(a.CallsTotal, b.CallsTotal) },
	"tokensTotal":    func(a, b InstallRow) int { return cmp.Compare(a.TokensTotal, b.TokensTotal) },
	"quotaHitDays":   func(a, b InstallRow) int { return cmp.Compare(a.QuotaHitDays, b.QuotaHitDays) },
	"appVersionCode": func(a, b InstallRow) int { return cmp.Compare(deref(a.AppVersionCode), deref(b.AppVersionCode)) },
}

func matchesStatus(r InstallRow, status string) bool {
	switch status {
	case "active":
		return !r.Banned && !r.Dormant
	case "dormant":
		return r.Dormant
	case "banned":
		return r.Banned
	}
	return true
}

// QueryInstalls filters, sorts (default lastSeen desc, ties by hash) and
// pages the table. Unknown sort, order or status values are ErrBadRequest.
func QueryInstalls(rows []InstallRow, q InstallQuery) (InstallPage, error) {
	sortKey := q.Sort
	if sortKey == "" {
		sortKey = "lastSeen"
	}
	compare, ok := installSorts[sortKey]
	if !ok {
		return InstallPage{}, ErrBadRequest
	}
	desc := true
	switch q.Order {
	case "", "desc":
	case "asc":
		desc = false
	default:
		return InstallPage{}, ErrBadRequest
	}
	switch q.Status {
	case "", "all", "active", "dormant", "banned":
	default:
		return InstallPage{}, ErrBadRequest
	}

	prefix := strings.ToLower(strings.TrimSpace(q.Q))
	filtered := make([]InstallRow, 0, len(rows))
	for _, r := range rows {
		if matchesStatus(r, q.Status) && strings.HasPrefix(r.Hash, prefix) {
			filtered = append(filtered, r)
		}
	}
	slices.SortStableFunc(filtered, func(a, b InstallRow) int {
		c := compare(a, b)
		if desc {
			c = -c
		}
		if c == 0 {
			c = strings.Compare(a.Hash, b.Hash)
		}
		return c
	})

	size := q.PageSize
	if size <= 0 {
		size = DefaultPageSize
	}
	page := q.Page
	if page < 1 {
		page = 1
	}
	lastPage := (len(filtered) + size - 1) / size
	var start int
	if page-1 >= lastPage {
		start = len(filtered)
	} else {
		start = (page - 1) * size
	}
	end := min(start+size, len(filtered))
	return InstallPage{Rows: filtered[start:end], Total: len(filtered), Page: page, PageSize: size}, nil
}

// DetailDay is one day on an install's detail page.
type DetailDay struct {
	Day     string `json:"day"`
	Calls   int64  `json:"calls"`
	Tokens  int64  `json:"tokens"`
	Session bool   `json:"session"`
}

// InstallDaily lists every day from firstSeenDay to today for one install.
func InstallDaily(firstSeenDay, today string, usage []store.UsageRow, sessionDays []string) []DetailDay {
	if firstSeenDay > today {
		firstSeenDay = today
	}
	byDay := make(map[string]store.UsageRow, len(usage))
	for _, u := range usage {
		byDay[u.Day] = u
	}
	sessions := make(map[string]bool, len(sessionDays))
	for _, d := range sessionDays {
		sessions[d] = true
	}
	days := Days(firstSeenDay, today)
	out := make([]DetailDay, 0, len(days))
	for _, d := range days {
		u := byDay[d]
		out = append(out, DetailDay{Day: d, Calls: u.Calls, Tokens: u.Tokens, Session: sessions[d]})
	}
	return out
}

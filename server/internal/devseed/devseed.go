// Package devseed fills an empty database with about four months of realistic
// fake history so the dashboard can be built and checked locally. It must
// never be pointed at production data; it refuses any database that already
// has installs.
package devseed

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"os"
	"strconv"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// ErrNotEmpty reports a database that already has installs.
var ErrNotEmpty = errors.New("devseed: database already has installs")

// Days is how much history Seed writes, ending today. It is longer than
// store.ModelStatsRetentionDays so the oldest model stats get rolled up.
const Days = 120

var models = []string{"nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3.8-27b:free", "nex-agi/nex-n2.5-pro:free"}

// Summary counts what Seed wrote.
type Summary struct {
	Installs, InstallDays, Usage, Counters int
	ModelStats, ModelStatsRollup           int
	From, To                               string
}

type weighted struct {
	key    string
	weight float64
}

func pick(r *rand.Rand, options []weighted) string {
	total := 0.0
	for _, o := range options {
		total += o.weight
	}
	x := r.Float64() * total
	for _, o := range options {
		x -= o.weight
		if x <= 0 {
			return o.key
		}
	}
	return options[len(options)-1].key
}

func poisson(r *rand.Rand, lambda float64) int64 {
	if lambda <= 0 {
		return 0
	}
	l, k, p := math.Exp(-lambda), int64(0), 1.0
	for {
		k++
		p *= r.Float64()
		if p <= l {
			return k - 1
		}
	}
}

var (
	tiers     = []weighted{{"DEVICE", 0.7}, {"STRONG", 0.3}}
	licensing = []weighted{{"LICENSED", 0.92}, {"UNLICENSED", 0.06}, {"UNEVALUATED", 0.02}}
	outcomes  = []weighted{
		{"ok", 0.945},
		{"upstream_retryable", 0.03},
		{"upstream_429", 0.015},
		{"upstream_rejected", 0.006},
		{"client_cancelled", 0.004},
	}
	modelMix    = []weighted{{models[0], 0.7}, {models[1], 0.22}, {models[2], 0.08}}
	categoryMix = []weighted{{"transaction", 0.6}, {"bill", 0.08}, {"none", 0.32}}
	latencyMix  = []weighted{
		{"500", 0.03},
		{"1000", 0.2},
		{"2000", 0.33},
		{"4000", 0.27},
		{"8000", 0.12},
		{"16000", 0.04},
		{"32000", 0.008},
		{"inf", 0.002},
	}
)

// Seed migrates path (creating it if needed) and fills it, using seed for
// the random source so runs are repeatable.
func Seed(path string, now time.Time, seed int64) (Summary, error) {
	// Check if database is non-empty BEFORE migrating it.
	if _, err := os.Stat(path); err == nil {
		raw, err := sql.Open("sqlite", "file:"+path)
		if err != nil {
			return Summary{}, err
		}
		var hasTable int
		if err := raw.QueryRow(`SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='installs'`).Scan(&hasTable); err != nil {
			_ = raw.Close()
			return Summary{}, err
		}
		if hasTable > 0 {
			var existing int
			if err := raw.QueryRow(`SELECT count(*) FROM installs`).Scan(&existing); err != nil {
				_ = raw.Close()
				return Summary{}, err
			}
			if existing > 0 {
				_ = raw.Close()
				return Summary{}, ErrNotEmpty
			}
		}
		_ = raw.Close()
	}

	s, err := store.Open(path)
	if err != nil {
		return Summary{}, err
	}
	_ = s.Close()

	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return Summary{}, err
	}
	defer func() { _ = db.Close() }()

	r := rand.New(rand.NewSource(seed)) //nolint:gosec // fake data, not security
	today := now.UTC().Truncate(24 * time.Hour)
	start := today.AddDate(0, 0, -(Days - 1))
	dayKey := func(i int) string { return start.AddDate(0, 0, i).Format("2006-01-02") }
	releases := []struct {
		code int64
		day  int
	}{{14, 0}, {15, 27}, {16, 55}, {17, 84}, {18, 107}}
	latestAt := func(d int) int64 {
		v := releases[0].code
		for _, rel := range releases {
			if d >= rel.day {
				v = rel.code
			}
		}
		return v
	}

	// The fleet's on-device rate climbs from about 70% to 83% across the span,
	// with day-to-day noise shared by every install.
	dayRate := make([]float64, Days)
	for d := range dayRate {
		rate := 0.70 + 0.13*float64(d)/float64(Days-1) + r.NormFloat64()*0.02
		dayRate[d] = math.Min(0.95, math.Max(0.5, rate))
	}
	// Model stats come only from the reporting release and later, so their
	// version is newer than the session versions above: 19, then 20 from
	// two-thirds through, which each install picks up within a few days.
	const statsVersionOld, statsVersionNew = 19, 20
	statsSwitchDay := Days * 2 / 3

	tx, err := db.Begin()
	if err != nil {
		return Summary{}, err
	}
	defer func() { _ = tx.Rollback() }()

	counters := map[[3]string]int64{}
	add := func(day, metric, key string, n int64) {
		if n > 0 {
			counters[[3]string{day, metric, key}] += n
		}
	}

	installs := 0
	for d := 0; d < Days; d++ {
		for j := poisson(r, 0.8+3.2*float64(d)/Days); j > 0; j-- {
			installs++
			sum := sha256.Sum256([]byte(fmt.Sprintf("dev-seed-install-%d", installs)))
			hash := hex.EncodeToString(sum[:])
			firstSeen := start.AddDate(0, 0, d).Add(time.Duration(r.Intn(86400)) * time.Second)
			var sdk any
			if r.Float64() < 0.8 {
				sdk = 28 + r.Intn(8)
			}
			heavy := r.Float64() < 0.08
			churn := 0.01 + r.Float64()*0.06
			sms := 1.5 + r.Float64()*5
			if heavy {
				sms = 40 + r.Float64()*80
			}
			version := latestAt(d)
			statsVersion := int64(statsVersionOld)
			lastSeen := firstSeen

			for dd := d; dd < Days; dd++ {
				if dd > d && r.Float64() < churn {
					break
				}
				if v := latestAt(dd); v > version && r.Float64() < 0.25 {
					version = v
				}
				key := dayKey(dd)
				if dd == d || r.Float64() < 0.55 {
					if _, err := tx.Exec(`INSERT INTO install_days (id_hash, day, app_version_code) VALUES (?,?,?)`, hash, key, version); err != nil {
						return Summary{}, err
					}
					add(key, "session_outcome", "ok", 1)
					if ts := start.AddDate(0, 0, dd).Add(time.Duration(r.Intn(86400)) * time.Second); ts.After(lastSeen) {
						lastSeen = ts
					}
				}
				calls := poisson(r, sms)
				var imported int64
				if dd == d {
					imported = 15 + int64(r.Intn(40)) // first-day inbox import
					calls += imported
				}
				if calls == 0 {
					continue
				}
				if calls > 200 {
					add(key, "classify_outcome", "rate_limited_daily", calls-200)
					calls = 200
				}
				// Every live call is a message the local model declined or could
				// not run on; it accepted the rest, so messages ≈ calls ÷ (1 − rate).
				// The inbox import never goes through the local model.
				if live := calls - imported; live > 0 {
					if dd >= statsSwitchDay && statsVersion == statsVersionOld && r.Float64() < 0.6 {
						statsVersion = statsVersionNew
					}
					unavailable := min(live, poisson(r, 0.02*float64(live)))
					accepted := int64(math.Round(float64(live) * dayRate[dd] / (1 - dayRate[dd])))
					if _, err := tx.Exec(`INSERT INTO model_stats_daily
					    (id_hash, day, app_version_code, accepted, declined, unavailable) VALUES (?,?,?,?,?,?)`,
						hash, key, statsVersion, accepted, live-unavailable, unavailable); err != nil {
						return Summary{}, err
					}
				}
				var ok int64
				for c := int64(0); c < calls; c++ {
					o := pick(r, outcomes)
					add(key, "classify_outcome", o, 1)
					if o == "ok" {
						ok++
						add(key, "model", pick(r, modelMix), 1)
						add(key, "category", pick(r, categoryMix), 1)
						add(key, "classify_latency_ms", pick(r, latencyMix), 1)
					}
				}
				if _, err := tx.Exec(`INSERT INTO usage (id_hash, day, calls, tokens) VALUES (?,?,?,?)`,
					hash, key, calls, ok*int64(380+r.Intn(160))); err != nil {
					return Summary{}, err
				}
			}

			banned, reason := 0, ""
			if r.Float64() < 0.02 {
				banned, reason = 1, "abuse: scripted calls"
			}
			if _, err := tx.Exec(`INSERT INTO installs (id_hash, first_seen, last_seen, banned, ban_reason,
			    app_version_code, device_tier, licensing, sdk_version) VALUES (?,?,?,?,?,?,?,?,?)`,
				hash, firstSeen.Unix(), lastSeen.Unix(), banned, reason, version,
				pick(r, tiers), pick(r, licensing), sdk); err != nil {
				return Summary{}, err
			}
		}

		key := dayKey(d)
		add(key, "classify_outcome", "unauthorized", poisson(r, 2))
		add(key, "classify_outcome", "bad_request", poisson(r, 0.5))
		add(key, "classify_outcome", "rate_limited_burst", poisson(r, 1))
		add(key, "session_outcome", "device_integrity", poisson(r, 0.6))
		add(key, "session_outcome", "challenge_invalid", poisson(r, 0.4))
		add(key, "session_outcome", "attest_unavailable", poisson(r, 0.2))
		add(key, "session_outcome", "cert_mismatch", poisson(r, 0.05))
	}

	for k, n := range counters {
		if _, err := tx.Exec(`INSERT INTO counters_daily (day, metric, key, count) VALUES (?,?,?,?)`, k[0], k[1], k[2], n); err != nil {
			return Summary{}, err
		}
	}
	info := map[string]string{
		store.InfoDailyPerInstall: "200",
		store.InfoBurstPerMin:     "20",
		store.InfoGlobalDailyCap:  "20000",
		store.InfoModels:          models[0] + "," + models[1] + "," + models[2],
		store.InfoStartedAt:       strconv.FormatInt(now.Add(-36*time.Hour).Unix(), 10),
		store.InfoImageTag:        "dev-seed",
	}
	for k, v := range info {
		if _, err := tx.Exec(`INSERT INTO server_info (key, value) VALUES (?, ?)
		    ON CONFLICT(key) DO UPDATE SET value = excluded.value`, k, v); err != nil {
			return Summary{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return Summary{}, err
	}

	// Fold model stats older than the retention window exactly as pawletd's
	// rollup job would, so model_stats_rollup and messages_archived are filled.
	s, err = store.Open(path)
	if err != nil {
		return Summary{}, err
	}
	_, err = s.RollupModelStats(context.Background(), now)
	_ = s.Close()
	if err != nil {
		return Summary{}, err
	}

	sum := Summary{From: dayKey(0), To: dayKey(Days - 1)}
	for table, dst := range map[string]*int{
		"installs": &sum.Installs, "install_days": &sum.InstallDays,
		"usage": &sum.Usage, "counters_daily": &sum.Counters,
		"model_stats_daily": &sum.ModelStats, "model_stats_rollup": &sum.ModelStatsRollup,
	} {
		if err := db.QueryRow(`SELECT count(*) FROM ` + table).Scan(dst); err != nil { //nolint:gosec // fixed table names
			return Summary{}, err
		}
	}
	return sum, nil
}

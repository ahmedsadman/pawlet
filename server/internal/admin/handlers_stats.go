package admin

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/stats"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// cohortCount is how many weekly cohorts the engagement page shows.
const cohortCount = 12

// adoptionDays is how far back the fleet page's version adoption reaches.
const adoptionDays = 90

// maxBanReason caps the stored ban reason, in characters.
const maxBanReason = 200

// collectingSince tells the dashboard where history begins for data that
// only exists since the capture deploy.
type collectingSince struct {
	Sessions *string `json:"sessions"`
	Counters *string `json:"counters"`
}

func newCollectingSince(e store.EarliestDays) collectingSince {
	opt := func(s string) *string {
		if s == "" {
			return nil
		}
		return &s
	}
	return collectingSince{Sessions: opt(e.InstallDays), Counters: opt(e.Counters)}
}

func validHash(h string) bool {
	if len(h) != 64 {
		return false
	}
	for _, c := range h {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func classifyCounts(rows []store.CounterRow, day string) map[string]int64 {
	out := map[string]int64{}
	for _, c := range rows {
		if c.Day == day && c.Metric == metrics.ClassifyOutcome {
			out[c.Key] += c.Count
		}
	}
	return out
}

func (s *Server) today() string { return stats.Today(s.now()) }

// rangeFor resolves ?range= against the database's history.
func (s *Server) rangeFor(r *http.Request) (stats.Range, store.EarliestDays, error) {
	earliest, err := s.store.EarliestDays(r.Context())
	if err != nil {
		return stats.Range{}, store.EarliestDays{}, err
	}
	rng, err := stats.ParseRange(r.URL.Query().Get("range"), s.today(), earliest.Any())
	return rng, earliest, err
}

// writeRangeError maps a bad range to 400 and anything else to 500.
func (s *Server) writeRangeError(w http.ResponseWriter, err error) {
	if errors.Is(err, stats.ErrBadRequest) {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	s.fail(w, "resolve range", err)
}

func (s *Server) dailyLimit(r *http.Request) (int64, error) {
	info, err := s.store.ServerInfo(r.Context())
	if err != nil {
		return 0, err
	}
	return int64(stats.ParseServerInfo(info).DailyPerInstall), nil
}

type overviewResponse struct {
	Range stats.Range `json:"range"`
	stats.Overview
	Server          stats.ServerInfo `json:"server"`
	CollectingSince collectingSince  `json:"collectingSince"`
}

func (s *Server) overview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	today := s.today()
	rng, earliest, err := s.rangeFor(r)
	if err != nil {
		s.writeRangeError(w, err)
		return
	}
	installs, err := s.store.AllInstalls(ctx)
	if err != nil {
		s.fail(w, "load installs", err)
		return
	}
	activityFrom := stats.AddDays(rng.From, -29)
	usage, err := s.store.UsageBetween(ctx, activityFrom, today)
	if err != nil {
		s.fail(w, "load usage", err)
		return
	}
	sessions, err := s.store.InstallDaysBetween(ctx, activityFrom, today)
	if err != nil {
		s.fail(w, "load sessions", err)
		return
	}
	counters, err := s.store.CountersBetween(ctx, today, today)
	if err != nil {
		s.fail(w, "load counters", err)
		return
	}
	info, err := s.store.ServerInfo(ctx)
	if err != nil {
		s.fail(w, "load server info", err)
		return
	}

	ov := stats.BuildOverview(stats.OverviewInput{
		Range: rng, Today: today, Installs: installs, Usage: usage,
		Activity:      stats.BuildActivity(usage, sessions, stats.ModeAny),
		CountersToday: classifyCounts(counters, today),
	})
	writeJSON(w, http.StatusOK, overviewResponse{
		Range: rng, Overview: ov, Server: stats.ParseServerInfo(info), CollectingSince: newCollectingSince(earliest),
	})
}

func (s *Server) installRows(r *http.Request) ([]stats.InstallRow, error) {
	ctx := r.Context()
	installs, err := s.store.AllInstalls(ctx)
	if err != nil {
		return nil, err
	}
	usage, err := s.store.AllUsage(ctx)
	if err != nil {
		return nil, err
	}
	limit, err := s.dailyLimit(r)
	if err != nil {
		return nil, err
	}
	return stats.BuildInstallRows(installs, usage, s.today(), limit), nil
}

func (s *Server) installs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page := 1
	if pageStr := q.Get("page"); pageStr != "" {
		p, err := strconv.Atoi(pageStr)
		if err != nil || p < 1 {
			writeError(w, http.StatusBadRequest, "bad_request")
			return
		}
		page = p
	}
	rows, err := s.installRows(r)
	if err != nil {
		s.fail(w, "build install rows", err)
		return
	}
	result, err := stats.QueryInstalls(rows, stats.InstallQuery{
		Sort: q.Get("sort"), Order: q.Get("order"), Q: q.Get("q"), Status: q.Get("status"), Page: page,
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

type installDetailResponse struct {
	Install stats.InstallRow  `json:"install"`
	Daily   []stats.DetailDay `json:"daily"`
}

// lookupInstall validates the path hash and loads the install, writing the
// error response itself when it returns false.
func (s *Server) lookupInstall(w http.ResponseWriter, r *http.Request) (store.Install, bool) {
	hash := r.PathValue("hash")
	if !validHash(hash) {
		writeError(w, http.StatusBadRequest, "bad_request")
		return store.Install{}, false
	}
	in, err := s.store.Install(r.Context(), hash)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return store.Install{}, false
	}
	if err != nil {
		s.fail(w, "load install", err)
		return store.Install{}, false
	}
	return in, true
}

func (s *Server) installDetail(w http.ResponseWriter, r *http.Request) {
	in, ok := s.lookupInstall(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	usage, err := s.store.UsageForInstall(ctx, in.IDHash)
	if err != nil {
		s.fail(w, "load install usage", err)
		return
	}
	days, err := s.store.InstallDays(ctx, in.IDHash)
	if err != nil {
		s.fail(w, "load install days", err)
		return
	}
	limit, err := s.dailyLimit(r)
	if err != nil {
		s.fail(w, "load server info", err)
		return
	}
	today := s.today()
	row := stats.BuildInstallRows([]store.Install{in}, usage, today, limit)[0]
	writeJSON(w, http.StatusOK, installDetailResponse{
		Install: row,
		Daily:   stats.InstallDaily(in.FirstSeen.UTC().Format(stats.DayLayout), today, usage, days),
	})
}

type banRequest struct {
	Reason string `json:"reason"`
}

func (s *Server) ban(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req banRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	reason := strings.TrimSpace(req.Reason)
	if reason == "" || utf8.RuneCountInString(reason) > maxBanReason {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	in, ok := s.lookupInstall(w, r)
	if !ok {
		return
	}
	if err := s.store.Ban(r.Context(), in.IDHash, reason); err != nil {
		s.fail(w, "ban install", err)
		return
	}
	s.logger.Info("admin banned install", "installHash", in.IDHash[:8])
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) unban(w http.ResponseWriter, r *http.Request) {
	in, ok := s.lookupInstall(w, r)
	if !ok {
		return
	}
	if err := s.store.Unban(r.Context(), in.IDHash); err != nil {
		s.fail(w, "unban install", err)
		return
	}
	s.logger.Info("admin unbanned install", "installHash", in.IDHash[:8])
	w.WriteHeader(http.StatusNoContent)
}

type engagementResponse struct {
	Range             stats.Range         `json:"range"`
	Mode              stats.Mode          `json:"mode"`
	Daily             []stats.ActiveCount `json:"daily"`
	Cohorts           []stats.Cohort      `json:"cohorts"`
	CallsDistribution []stats.Bucket      `json:"callsDistribution"`
	Dormant           int                 `json:"dormant"`
	CollectingSince   collectingSince     `json:"collectingSince"`
}

func (s *Server) engagement(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	today := s.today()
	rng, earliest, err := s.rangeFor(r)
	if err != nil {
		s.writeRangeError(w, err)
		return
	}
	mode, err := stats.ParseMode(r.URL.Query().Get("active"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	installs, err := s.store.AllInstalls(ctx)
	if err != nil {
		s.fail(w, "load installs", err)
		return
	}
	usage, err := s.store.AllUsage(ctx)
	if err != nil {
		s.fail(w, "load usage", err)
		return
	}
	activityFrom := min(stats.AddDays(rng.From, -29), stats.AddDays(stats.WeekStart(today), -7*(cohortCount-1)))
	sessions, err := s.store.InstallDaysBetween(ctx, activityFrom, today)
	if err != nil {
		s.fail(w, "load sessions", err)
		return
	}
	limit, err := s.dailyLimit(r)
	if err != nil {
		s.fail(w, "load server info", err)
		return
	}

	activity := stats.BuildActivity(usage, sessions, mode)
	dormant := 0
	for _, row := range stats.BuildInstallRows(installs, usage, today, limit) {
		if row.Dormant {
			dormant++
		}
	}
	writeJSON(w, http.StatusOK, engagementResponse{
		Range:             rng,
		Mode:              mode,
		Daily:             stats.ActiveSeries(activity, stats.Days(rng.From, rng.To)),
		Cohorts:           stats.Cohorts(installs, activity, today, cohortCount),
		CallsDistribution: stats.CallsDistribution(usage, rng.From, rng.To, limit),
		Dormant:           dormant,
		CollectingSince:   newCollectingSince(earliest),
	})
}

type reliabilityResponse struct {
	Range stats.Range `json:"range"`
	stats.Reliability
	CollectingSince collectingSince `json:"collectingSince"`
}

func (s *Server) reliability(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	rng, earliest, err := s.rangeFor(r)
	if err != nil {
		s.writeRangeError(w, err)
		return
	}
	counters, err := s.store.CountersBetween(ctx, rng.From, rng.To)
	if err != nil {
		s.fail(w, "load counters", err)
		return
	}
	usage, err := s.store.UsageBetween(ctx, rng.From, rng.To)
	if err != nil {
		s.fail(w, "load usage", err)
		return
	}
	writeJSON(w, http.StatusOK, reliabilityResponse{
		Range:           rng,
		Reliability:     stats.BuildReliability(stats.Days(rng.From, rng.To), counters, usage, metrics.LatencyBoundsMs()),
		CollectingSince: newCollectingSince(earliest),
	})
}

type fleetResponse struct {
	stats.Fleet
	CollectingSince collectingSince `json:"collectingSince"`
}

func (s *Server) fleet(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	today := s.today()
	earliest, err := s.store.EarliestDays(ctx)
	if err != nil {
		s.fail(w, "load earliest days", err)
		return
	}
	installs, err := s.store.AllInstalls(ctx)
	if err != nil {
		s.fail(w, "load installs", err)
		return
	}
	recentFrom := stats.AddDays(today, -(stats.FleetWindowDays - 1))
	adoptionFrom := stats.AddDays(today, -(adoptionDays - 1))
	usage, err := s.store.UsageBetween(ctx, recentFrom, today)
	if err != nil {
		s.fail(w, "load usage", err)
		return
	}
	sessions, err := s.store.InstallDaysBetween(ctx, adoptionFrom, today)
	if err != nil {
		s.fail(w, "load sessions", err)
		return
	}
	recent := stats.BuildActivity(usage, sessions, stats.ModeAny)
	writeJSON(w, http.StatusOK, fleetResponse{
		Fleet:           stats.BuildFleet(installs, recent, sessions, stats.Days(adoptionFrom, today), today),
		CollectingSince: newCollectingSince(earliest),
	})
}

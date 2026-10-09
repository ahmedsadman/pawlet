package stats

import (
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestBuildFleet(t *testing.T) {
	today := "2026-10-09"
	installs := []store.Install{
		install("a", "2026-09-01"), install("b", "2026-09-01"), install("c", "2026-09-01"),
		install("d", "2026-08-01"), install("e", "2026-09-01"),
	}
	installs[0].Meta = store.InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG", Licensing: "LICENSED", SDKVersion: 34}
	installs[1].Meta = store.InstallMeta{AppVersionCode: 17, DeviceTier: "DEVICE", Licensing: "LICENSED"}
	installs[2].Meta = store.InstallMeta{AppVersionCode: 18, DeviceTier: "DEVICE", Licensing: "UNLICENSED", SDKVersion: 33}
	installs[4].Banned = true

	recent := Activity{}
	recent.mark("2026-10-09", "a")
	recent.mark("2026-09-20", "b")
	recent.mark("2026-10-01", "c")
	recent.mark("2026-08-20", "d") // more than 30 days ago
	recent.mark("2026-10-09", "e") // banned

	sessions := []store.DayRow{
		{IDHash: "a", Day: "2026-10-08", AppVersionCode: 17},
		{IDHash: "a", Day: "2026-10-09", AppVersionCode: 18},
		{IDHash: "b", Day: "2026-10-09", AppVersionCode: 0},
	}
	f := BuildFleet(installs, recent, sessions, []string{"2026-10-08", "2026-10-09"}, today)

	if f.ActiveInstalls != 3 {
		t.Fatalf("active = %d", f.ActiveInstalls)
	}
	if len(f.Versions) != 2 || f.Versions[0] != (KeyCount{"18", 2}) || f.Versions[1] != (KeyCount{"17", 1}) {
		t.Fatalf("versions = %+v", f.Versions)
	}
	if f.DeviceTier[0] != (KeyCount{"DEVICE", 2}) || f.Licensing[0] != (KeyCount{"LICENSED", 2}) {
		t.Fatalf("tier/licensing = %+v %+v", f.DeviceTier, f.Licensing)
	}
	if len(f.SDK) != 3 || f.SDK[0] != (KeyCount{"34", 1}) || f.SDK[2] != (KeyCount{Unknown, 1}) {
		t.Fatalf("sdk = %+v (numeric desc, unknown last)", f.SDK)
	}
	if f.Adoption[0].Counts["17"] != 1 || f.Adoption[1].Counts["18"] != 1 || f.Adoption[1].Counts[Unknown] != 1 {
		t.Fatalf("adoption = %+v", f.Adoption)
	}
}

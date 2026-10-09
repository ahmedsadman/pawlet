package httpapi

import (
	"slices"
	"strconv"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// installMeta extracts what the dashboard records about an install from a
// verdict that has already passed attest.Verify. Anything missing or
// unrecognised becomes the zero value, stored as NULL: a session that has
// attested must never fail over bookkeeping.
func installMeta(p attest.Payload) store.InstallMeta {
	var meta store.InstallMeta

	if v, err := strconv.ParseInt(p.AppIntegrity.VersionCode, 10, 64); err == nil && v > 0 {
		meta.AppVersionCode = v
	}

	verdicts := p.DeviceIntegrity.DeviceRecognitionVerdict
	switch {
	case slices.Contains(verdicts, "MEETS_STRONG_INTEGRITY"):
		meta.DeviceTier = "STRONG"
	case slices.Contains(verdicts, "MEETS_DEVICE_INTEGRITY"):
		meta.DeviceTier = "DEVICE"
	}

	switch l := p.AccountDetails.AppLicensingVerdict; l {
	case "LICENSED", "UNLICENSED", "UNEVALUATED":
		meta.Licensing = l
	}

	if sdk := p.DeviceIntegrity.DeviceAttributes.SdkVersion; sdk > 0 {
		meta.SDKVersion = sdk
	}
	return meta
}

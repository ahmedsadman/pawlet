package httpapi

import (
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestInstallMeta(t *testing.T) {
	build := func(version string, verdicts []string, licensing string, sdk int64) attest.Payload {
		var p attest.Payload
		p.AppIntegrity.VersionCode = version
		p.DeviceIntegrity.DeviceRecognitionVerdict = verdicts
		p.AccountDetails.AppLicensingVerdict = licensing
		p.DeviceIntegrity.DeviceAttributes.SdkVersion = sdk
		return p
	}

	cases := []struct {
		name string
		in   attest.Payload
		want store.InstallMeta
	}{
		{
			name: "strong licensed with sdk",
			in:   build("18", []string{"MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY", "MEETS_STRONG_INTEGRITY"}, "LICENSED", 34),
			want: store.InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG", Licensing: "LICENSED", SDKVersion: 34},
		},
		{
			name: "device tier unlicensed, no device attributes",
			in:   build("17", []string{"MEETS_DEVICE_INTEGRITY"}, "UNLICENSED", 0),
			want: store.InstallMeta{AppVersionCode: 17, DeviceTier: "DEVICE", Licensing: "UNLICENSED"},
		},
		{
			name: "unevaluated licensing kept",
			in:   build("17", []string{"MEETS_DEVICE_INTEGRITY"}, "UNEVALUATED", 0),
			want: store.InstallMeta{AppVersionCode: 17, DeviceTier: "DEVICE", Licensing: "UNEVALUATED"},
		},
		{
			name: "unparsable version and unknown licensing become unknown",
			in:   build("seventeen", []string{"MEETS_DEVICE_INTEGRITY"}, "SOMETHING_NEW", 0),
			want: store.InstallMeta{DeviceTier: "DEVICE"},
		},
		{
			name: "negative values dropped",
			in:   build("-3", []string{"MEETS_DEVICE_INTEGRITY"}, "", -1),
			want: store.InstallMeta{DeviceTier: "DEVICE"},
		},
		{
			name: "no recognised verdict",
			in:   build("", nil, "", 0),
			want: store.InstallMeta{},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := installMeta(c.in); got != c.want {
				t.Fatalf("installMeta() = %+v, want %+v", got, c.want)
			}
		})
	}
}

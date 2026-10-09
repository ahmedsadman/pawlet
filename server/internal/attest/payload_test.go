package attest

import (
	"encoding/json"
	"testing"
)

func TestPayloadDecodesRecordedFields(t *testing.T) {
	// Shape of tokenPayloadExternal as Play Integrity returns it: versionCode
	// is a JSON string, sdkVersion a number.
	const raw = `{
	  "appIntegrity": {"appRecognitionVerdict": "PLAY_RECOGNIZED", "versionCode": "42"},
	  "deviceIntegrity": {
	    "deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY", "MEETS_STRONG_INTEGRITY"],
	    "deviceAttributes": {"sdkVersion": 34}
	  },
	  "accountDetails": {"appLicensingVerdict": "LICENSED"}
	}`

	var p Payload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("Unmarshal() error = %v", err)
	}
	if p.AppIntegrity.VersionCode != "42" {
		t.Errorf("VersionCode = %q, want 42", p.AppIntegrity.VersionCode)
	}
	if p.DeviceIntegrity.DeviceAttributes.SdkVersion != 34 {
		t.Errorf("SdkVersion = %d, want 34", p.DeviceIntegrity.DeviceAttributes.SdkVersion)
	}
	if p.AccountDetails.AppLicensingVerdict != "LICENSED" {
		t.Errorf("AppLicensingVerdict = %q, want LICENSED", p.AccountDetails.AppLicensingVerdict)
	}
}

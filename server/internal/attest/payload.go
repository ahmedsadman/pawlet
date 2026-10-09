package attest

// Payload mirrors the fields of a decoded Play Integrity token that this
// service checks or records. Fields the service ignores are omitted.
type Payload struct {
	RequestDetails struct {
		RequestPackageName string `json:"requestPackageName"`
		RequestHash        string `json:"requestHash"`
		TimestampMillis    string `json:"timestampMillis"`
	} `json:"requestDetails"`
	AppIntegrity struct {
		AppRecognitionVerdict   string   `json:"appRecognitionVerdict"`
		PackageName             string   `json:"packageName"`
		CertificateSha256Digest []string `json:"certificateSha256Digest"`
		// VersionCode is the app's Play versionCode, sent as a JSON string.
		VersionCode string `json:"versionCode"`
	} `json:"appIntegrity"`
	DeviceIntegrity struct {
		DeviceRecognitionVerdict []string `json:"deviceRecognitionVerdict"`
		// DeviceAttributes is present only when "device attributes" is enabled
		// for the app in Play Console's Integrity API settings.
		DeviceAttributes struct {
			SdkVersion int64 `json:"sdkVersion"`
		} `json:"deviceAttributes"`
	} `json:"deviceIntegrity"`
	AccountDetails struct {
		AppLicensingVerdict string `json:"appLicensingVerdict"`
	} `json:"accountDetails"`
}

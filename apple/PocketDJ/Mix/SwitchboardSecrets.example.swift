// SwitchboardSecrets.example.swift — TEMPLATE (committed). Documents the shape of the gitignored
// SwitchboardSecrets.swift that apple/scripts/setup-switchboard-secrets.sh generates from
// <repo>/switchboard-credentials.json. This .example file is EXCLUDED from the PocketDJ target
// (see `excludes` in project.yml) so it never compiles — the real generated file provides the
// actual `SwitchboardSecrets` enum that MixEngine / SwitchboardRuntime read.
enum SwitchboardSecrets {
    static let appID = "YOUR_SWITCHBOARD_APP_ID"
    static let appSecret = "YOUR_SWITCHBOARD_APP_SECRET"
    // Public example key from switchboard-sdk/dj-app-ios; replace with a real Superpowered
    // license if/when one is issued (Levi has none dedicated yet — flagged).
    static let superpoweredLicenseKey = "ExampleLicenseKey-WillExpire-OnNextUpdate"
}

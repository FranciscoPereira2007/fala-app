# Fala public source

This is the complete Fala app source snapshot, published separately from private
working history. Keep all platform functionality and the original frontend.
Do not add signing teams, provisioning profiles, certificates, pairing codes,
account credentials, private transcripts, .wrangler state or personal handoffs.

Generate Xcode projects with xcodegen. Build FalaMac and Fala after shared/native
changes. Personal signing belongs in local Xcode settings, never in project.yml.
Shared keychain groups must derive AppIdentifierPrefix from the built app.
CI must explicitly select Xcode 26 or newer: the runner's default Xcode 16.4
cannot compile SpeechAnalyzer even when runtime availability checks are present.
Keep SwiftUI waveform frame arithmetic in CGFloat: explicitly convert Double
seeds, as mixed multiplication is ambiguous under the Xcode 26.3 compiler.

Keep AVCaptureSession work and preview-layer release off the main thread. Native
lifecycle/build changes need independent review. Test production regressions with
an automated guard and document the rule here.

Relay tests must default to a local worker, not the production endpoint.
FALA_TEST must never be enabled in production. Preserve OFL and other dependency
notices. Do not infer physical-device or Windows GUI validation from compilation.

# Security and privacy reports

Do not place real keystrokes, archived text, credentials, private server URLs,
Keychain exports or unredacted activity screenshots in a public issue.

If GitHub private vulnerability reporting is enabled for this repository, use
that private channel. Otherwise open a minimal issue asking for a private reporting
channel without exploit details or personal data. No dedicated security email is
published in this source snapshot; do not assume a placeholder is monitored.

A useful report states the affected version, platform, trigger, expected boundary
and a minimal synthetic reproduction. Tests should use isolated databases and
loopback-only services. Include token names or redacted examples, never token values.

The application is intended for a person's own devices. Covert collection,
permission bypass, public unauthenticated synchronization and silently enabled text
recording are outside its design. Optional text capture has coverage limitations;
see docs/privacy.md. OS permissions and encryption do not make plaintext exports safe
to share automatically.

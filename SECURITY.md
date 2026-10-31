# Security and privacy boundaries

Pairing grants access to powerful functions, including input, screen capture and
AI sessions. Keep codes secret, rotate them to revoke access, and use only devices
you trust. This is a personal-computer application, not a hardened multi-user server.

The Mac/phone v2 protocol authenticates and encrypts messages using the pairing
code. Relay room traffic is encrypted by the clients. However, the optional
account-sync service stores paired-computer records including their codes: an
operator with access to that account storage is therefore inside the trust
boundary. Do not describe account sync as a zero-knowledge service.

The Windows LAN HTTP endpoints authenticate with X-Fala-Token, but HTTP itself
is not encrypted. Restrict these endpoints to a trusted private network; never
forward them directly onto the public internet. Relay transport has separate
client encryption.

Do not expose test-mode account authentication (`FALA_TEST`) in a public deployment.
A fork/self-hosted deployment must configure its own Cloudflare resources, Apple
identifiers and signing credentials. Do not commit runtime code.txt/token.txt,
Cloudflare state, local credentials, screenshots of secrets or session histories.

No external cryptographic or comprehensive security audit is claimed. Report a
suspected vulnerability through GitHub private vulnerability reporting when
available; otherwise request a private contact without publishing secrets.

# Security

## Secrets

Do not commit provider API keys, gateway tokens, signing certificates, private keys, databases, recordings, or production logs.

The Web and HarmonyOS clients must receive only the HTTPS/WSS gateway address and a user-scoped gateway credential. Provider credentials stay on the server.

## Deployment boundary

Run the adapter and Hermes services as a dedicated non-root user. Limit `MEDIA:` artifacts to an explicit artifact directory, use HTTPS/WSS, and keep internal Hermes endpoints off the public network.

## Privacy

Review [`PRIVACY.md`](./PRIVACY.md) before enabling external providers, transcript retention, or diagnostics.

## Reporting

Do not disclose live credentials or private conversation data in a public issue. Report security problems privately to the repository owner.

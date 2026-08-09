# Repository Layout

This repository contains the Single-Agent product line.

```text
app/                    Native Adapter service
web_native/             Browser/PWA client
tests/                  Native Adapter and browser filter tests
deploy/                 Deployment templates
docs/                   Protocol, security, privacy, and migration docs
```

The HarmonyOS Single-Agent client is planned as a sibling client under this product repository. It must use the same Adapter protocol and security rules, but it is not copied from the Host HarmonyOS client.

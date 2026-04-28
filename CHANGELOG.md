# Changelog

All notable changes to `rest-mail/testbed` are recorded here.
Versioning follows [calver](https://calver.org/) — `YYYY.MM.DD` (with a `.N`
suffix for multiple releases on the same day).

## 2026.04.28

Initial release.

- `docker-compose.yml` brings up `mailnet` (10.99.0.0/16), `dnsmasq`,
  `certgen`, and (behind the `scanning` profile) shared `clamav`.
- `configs/dnsmasq/zones.conf` ships A/MX/PTR/TXT/SRV records for
  `mail1.test`, `mail2.test`, `mail3.test`, plus autoconfig, MTA-STS,
  TLS-RPT, SPF, DMARC.
- `Taskfile.yml` provides `up`, `up:full`, `down`, `down:clean`,
  `ca:fetch`, `ca:show`, `restart:dns`, `dig`, `smoke`, `logs`, `ps`.
- README documents the integration contract: network name, DNS IP, CA
  cert install, supported `*.test` records, IP allocation, how to add
  domains.
- Pinned images: `reference-dnsmasq:2026.04.28`,
  `reference-certgen:2026.04.28`, `reference-clamav:2026.04.28`.

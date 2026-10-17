# rest-mail/testbed

Dev-only network/DNS/cert substrate for the [`rest-mail`](https://github.com/rest-mail) ecosystem.

This repo runs three things on a shared docker network called `mailnet`:

1. **dnsmasq** — authoritative DNS for `*.test` (mail1.test, mail2.test, mail3.test, plus MX, SRV, SPF, DMARC, autoconfig, MTA-STS records).
2. **certgen** — a one-shot init container that issues a self-signed CA + per-domain TLS certs into a shared volume.
3. **clamav** *(optional)* — a shared antivirus singleton, brought up by `task up:full`.

That's it. There's no daemon source code in this repo and no Dockerfiles. It's a thin composer that pulls published `ghcr.io/rest-mail/reference-*` images and wires them onto a shared network.

The point: any project can `git clone rest-mail/testbed && task up`, then bring up its own services on the same network and instantly have a realistic fake-internet — DNS resolves, MX records work, TLS validates against a CA you can install in your trust store.

---

## Quick start

```bash
git clone https://github.com/rest-mail/testbed.git
cd testbed
task up                  # dnsmasq + certgen
task ca:fetch            # writes ./ca.crt for client trust-store install
task smoke               # verify everything works
```

To also bring up the shared clamav singleton:

```bash
task up:full
```

To tear down:

```bash
task down                # stop + remove (keeps the certs volume)
task down:clean          # also remove the certs volume (forces regen)
```

---

## The contract

This is what consumers (other rest-mail repos, your own projects) need to know.

### Network name

The shared network is called **`<COMPOSE_PROJECT_NAME>_mailnet`** — defaults to **`testbed_mailnet`**.

Other projects join it as `external`:

```yaml
# your-project/docker-compose.yml
services:
  myservice:
    image: ...
    networks:
      mailnet:
        ipv4_address: 10.99.0.50    # pick something not in the table below

networks:
  mailnet:
    external: true
    name: testbed_mailnet
```

If you change `COMPOSE_PROJECT_NAME` in this repo, peers must match. Easiest path is to leave it at the default.

### DNS server

Inside the network, the dnsmasq container is at **`10.99.0.10`**. To resolve `*.test` from your peer containers, configure them with:

```yaml
services:
  myservice:
    dns: [10.99.0.10]
    networks: [mailnet]
```

Peers can then `dig mail1.test`, `dig mail1.test MX`, `dig _imaps._tcp.mail1.test SRV`, etc., and get the records this repo's `configs/dnsmasq/zones.conf` declares.

### CA certs

`task ca:fetch` copies the CA root cert out of the shared volume to `./ca.crt`.

Trust it on your **host** (so e.g. `curl https://mail1.test` from your laptop works through a port-forward):

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./ca.crt

# Linux (Debian/Ubuntu)
sudo cp ./ca.crt /usr/local/share/ca-certificates/reference-test-ca.crt
sudo update-ca-certificates
```

Trust it inside a **peer container** (so `wget https://mail1.test` from inside the container works):

```yaml
# Mount the certs volume read-only and add the CA at startup, OR
# bake it into the image:
services:
  myservice:
    volumes:
      - testbed_certs:/etc/testbed-certs:ro
    # entrypoint: cp /etc/testbed-certs/ca.crt /usr/local/share/ca-certificates/ \
    #             && update-ca-certificates && exec myservice

volumes:
  testbed_certs:
    external: true
    name: testbed_certs
```

Per-domain server certs are also in the volume: `mail1.test.crt`, `mail1.test.key`, etc. Mount them into postfix/dovecot/whatever needs them.

### IP address allocation

The current zones config assigns these IPs on `mailnet` (10.99.0.0/16):

| IP | Hostname | Owner |
|----|----------|-------|
| `10.99.0.10` | `dnsmasq` (the DNS server) | this repo |
| `10.99.0.11` | `mail1.test` | reference-mailserver |
| `10.99.0.12` | `mail2.test` | reference-mailserver |
| `10.99.0.13` | `mail3.test` | rest-mail-server |
| `10.99.0.20` | `api` (REST API endpoint) | rest-mail-server |
| `10.99.0.21` | `clamav` (shared singleton) | this repo (optional) |
| `10.99.0.41` | `postgres-mail1` | reference-mailserver |
| `10.99.0.42` | `postgres-mail2` | reference-mailserver |
| `10.99.0.43` | `postgres-mail3` | rest-mail-server |

If you add a peer, pick an unused IP and add a matching `address=` entry to `configs/dnsmasq/zones.conf`.

### Supported `*.test` records

`configs/dnsmasq/zones.conf` declares:

- **A** for `mail{1,2,3}.test`, `postgres-mail{1,2,3}`, `api`, `clamav`, plus `autoconfig.<domain>`, `autodiscover.<domain>`, `mta-sts.<domain>` (all → `10.99.0.20` for the API)
- **MX** for `mail{1,2,3}.test` → self, priority 10
- **PTR** reverse-DNS for the three mail-server IPs
- **TXT** SPF, DMARC, MTA-STS, TLS-RPT
- **SRV** for IMAP/IMAPS, POP3/POP3S, SMTP submission

`task dig -- <name> [<type>]` runs a dig from inside the network.

```bash
task dig -- mail1.test
task dig -- mail1.test MX
task dig -- _imaps._tcp.mail1.test SRV
```

Non-`.test` queries forward to `8.8.8.8` / `8.8.4.4` so peers using us as their DNS server can still resolve the real internet.

---

## restmail.test fixture template

`configs/restmail/manifest.yml` and the `config.env` rendered from it describe the restmail.test instance on this substrate: the `10.99.0.0/16` plan, dnsmasq at `10.99.0.10`, `testbed_certs`, `cert_provider: testbed-certgen`. They are a **template**. A consumer copies them once, into a directory it owns, and from then on edits and re-renders its own copy. Nothing should symlink to them or read them out of a testbed clone at runtime: a branch switch or `git clean` here must never change how someone else's stack boots.

The template is those two files and nothing else. The per-instance siblings a consumer generates next to its copy (`secrets.env`, `dns.env`, `dkim.conf`) are gitignored here and never shipped, and neither are certs, keys or any other working-tree state.

### Release assets

Each GitHub release published with a `v<version>` tag gets two assets, attached by the [`release fixture`](.github/workflows/release-fixture.yml) workflow from that tag's committed tree:

| Asset | Contents |
|-------|----------|
| `restmail-fixture-<version>.tar.gz` | `restmail-fixture-<version>/manifest.yml` and `restmail-fixture-<version>/config.env`, mode 0644, owner 0:0, stamped with the tag's commit time |
| `restmail-fixture-<version>.tar.gz.sha256` | `sha256sum` line for the archive |

The workflow starts on publishing a release, not on a tag push; it never replaces assets a release already has. No release carries these assets yet; the first one published after this change will.

### Using a pinned version

```bash
V=0.2.0   # a published testbed release; pin it
base=https://github.com/rest-mail/testbed/releases/download/v$V
curl -fsSLO "$base/restmail-fixture-$V.tar.gz"
curl -fsSLO "$base/restmail-fixture-$V.tar.gz.sha256"
sha256sum -c "restmail-fixture-$V.tar.gz.sha256"    # macOS: shasum -a 256 -c

# Expect one directory and two regular files (-rw-r--r--); refuse anything else.
tar -tvzf "restmail-fixture-$V.tar.gz"

mkdir -p instances/restmail.test
tar -xzf "restmail-fixture-$V.tar.gz" -C instances/restmail.test \
  --strip-components=1 --no-same-owner --no-same-permissions
```

`gh release download "v$V" -R rest-mail/testbed -p "restmail-fixture-$V.tar.gz*"` fetches the same two files. `instances/restmail.test/` is now yours: commit it, edit it, generate `secrets.env` / `dns.env` / `dkim.conf` beside it. Moving to a newer template is another copy, at a new pinned version, merged by hand.

### Building and checking it locally

```bash
task fixture:pack -- 0.2.0          # dist/restmail-fixture-0.2.0.tar.gz (+ .sha256) from HEAD
task fixture:pack -- 0.2.0 v0.2.0   # from a tag: matches that release's asset byte for byte
task fixture:test                   # packaging + consumer-copy tests (no Docker)
```

`scripts/fixture-pack.sh <version> [<ref>] [<out-dir>]` takes a bare SemVer version and any ref naming a commit, packs only the allowlisted files from that commit, and writes the same bytes every time for the same ref (GNU tar and gzip; `cmp` a local build against a published asset to check one). CI runs `scripts/fixture-test.sh` on every pull request.

---

## Adding a domain

To add `mail4.test`:

1. Pick an unused IP, e.g. `10.99.0.14`.
2. Add records to `configs/dnsmasq/zones.conf`:

   ```
   address=/mail4.test/10.99.0.14
   mx-host=mail4.test,mail4.test,10
   ptr-record=14.0.99.10.in-addr.arpa,mail4.test
   txt-record=mail4.test,"v=spf1 ip4:10.99.0.14 -all"
   txt-record=_dmarc.mail4.test,"v=DMARC1; p=reject; rua=mailto:postmaster@mail4.test"
   # ...plus any SRV/autoconfig/etc you need
   ```

3. Add `mail4.test` to `CERTGEN_DOMAINS` in `docker-compose.yml`:

   ```yaml
   environment:
     CERTGEN_DOMAINS: "mail1.test mail2.test mail3.test mail4.test"
   ```

4. Restart:

   ```bash
   task down                # leaves certs volume in place
   task up                  # certgen issues mail4.test cert idempotently
   task dnsmasq:restart     # picks up zones.conf changes
   ```

   Or, if you want a fully fresh CA + certs:

   ```bash
   task down:clean
   task up
   task ca:fetch            # re-install on host
   ```

---

## Tasks reference

| Command | What it does |
|---------|--------------|
| `task up` | bootstrap network + volumes + start dnsmasq |
| `task up:full` | also brings up shared clamav |
| `task down` | stop dnsmasq, preserve network + volumes |
| `task down:clean` | destructive teardown (also removes certs volume) |
| `task dnsmasq:up` / `dnsmasq:down` / `dnsmasq:restart` | dnsmasq lifecycle |
| `task dnsmasq:reload` / `dnsmasq:reap` | reload zones.conf / force-recreate container |
| `task dnsmasq:logs` / `dnsmasq:ps` | tail dnsmasq logs / show its status |
| `task ca:fetch` | copy `ca.crt` out of the volume to `./ca.crt` |
| `task ca:show` | print the CA cert details without copying |
| `task ps` | list testbed containers |
| `task dig -- <name> [<type>]` | run dig against the testbed DNS from inside the network |
| `task smoke` | verify dnsmasq resolves `mail1.test` and `ca.crt` is a valid x509 |
| `task fixture:pack -- <version> [<ref>]` | pack the restmail.test fixture template into `dist/` |
| `task fixture:test` | test the fixture packaging and consumer-copy steps |

`VERBOSE=1 task ...` enables verbose output on any task.

### Layout

Container lifecycle tasks live under `tasks/<container>.yml` (e.g. `tasks/dnsmasq.yml` for the `dnsmasq:*` namespace). The root `Taskfile.yml` orchestrates substrate concerns — network, volumes, certs export, smoke — and includes the per-container task files.

---

## Image versions

This composer pins each reference image to a SemVer release, `0.1.0`, for reproducibility (`IMAGE_TAG` in the Taskfiles). Bump it when you want a newer wrapper.

| Image | Tag | Purpose |
|-------|-----|---------|
| [`ghcr.io/rest-mail/reference-dnsmasq`](https://github.com/rest-mail/reference-dnsmasq) | `0.1.0` | DNS for `*.test` |
| [`ghcr.io/rest-mail/reference-certgen`](https://github.com/rest-mail/reference-certgen) | `0.1.0` | one-shot CA + cert issuer |
| [`ghcr.io/rest-mail/reference-clamav`](https://github.com/rest-mail/reference-clamav) | `0.1.0` | shared antivirus (optional) |

`:latest` also works in dev — see the comment in `docker-compose.yml`.

---

## What this repo does **not** do

- It doesn't run mail servers (postfix, dovecot). Use [`rest-mail/reference-mailserver`](https://github.com/rest-mail/reference-mailserver) for that.
- It doesn't run the rest-mail API. Use [`rest-mail/rest-mail-server`](https://github.com/rest-mail/rest-mail-server).
- It doesn't manage real internet certs. It's dev-only — the CA is self-signed with neutral defaults.
- It doesn't ship any daemon code. Sources for the daemons live in the `rest-mail/reference-*` repos.

---

## See also

- [`rest-mail/conventions`](https://github.com/rest-mail/conventions) — the contract every `reference-*` image follows
- [`rest-mail/reference-dnsmasq`](https://github.com/rest-mail/reference-dnsmasq)
- [`rest-mail/reference-certgen`](https://github.com/rest-mail/reference-certgen)
- [`rest-mail/reference-clamav`](https://github.com/rest-mail/reference-clamav)

## License

[MIT](./LICENSE).

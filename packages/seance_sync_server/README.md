# seance_sync_server

A tiny, self-hostable sync server for Séance. It stores **end-to-end encrypted**
record blobs and resolves conflicts by last-write-wins. It can decrypt nothing:
a full database compromise leaks only opaque ciphertext.

## Run with Docker

```bash
# from the repository root
docker compose -f packages/seance_sync_server/docker-compose.yml up -d --build
```

Or build the image directly (build context must be the repo root so the pub
workspace resolves):

```bash
docker build -f packages/seance_sync_server/Dockerfile -t seance-sync .
docker run -p 127.0.0.1:8787:8787 -v seance-data:/data \
  -e SEANCE_OPEN_REGISTRATION=true seance-sync
```

Flip `SEANCE_OPEN_REGISTRATION=true` only long enough to enrol your devices,
then set it back to `false` and restart. Put a TLS-terminating reverse proxy
(Caddy, nginx, Traefik) in front — the server speaks plain HTTP by design.
The compose file and `docker run` example bind the host port to loopback only;
publish it more broadly only behind TLS or on a trusted private network.

To update a running deployment (pull the latest code, rebuild the image,
recreate the container in one step), run `./update.sh` from the repository
root.

## Run without Docker

```bash
dart pub get
dart run packages/seance_sync_server/bin/seance_sync_server.dart \
  --port 8787 --db ./seance.sqlite --open-registration
# or compile a native binary:
dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart -o seance-sync
./seance-sync --help
```

SQLite mode needs `libsqlite3` at runtime (`libsqlite3-0` on Debian/Ubuntu).
Omit `--db` for an ephemeral in-memory store.

## Configuration

| Env var | CLI flag | Default | Meaning |
|---|---|---|---|
| `SEANCE_BIND` | `--bind` | `0.0.0.0` | Bind address |
| `SEANCE_PORT` | `--port` | `8787` | Listen port |
| `SEANCE_DB_PATH` | `--db` | *(in-memory)* | SQLite file path |
| `SEANCE_OPEN_REGISTRATION` | `--open-registration` | `false` | Allow `/v1/register` |
| `SEANCE_LOGIN_MAX_ATTEMPTS` | — | `10` | Login attempts per window |
| `SEANCE_LOGIN_WINDOW_SECONDS` | — | `60` | Rate-limit window |

## API (protocol v1)

All request/response bodies are JSON; every request carries a `protocolVersion`
so an old client and new server detect a mismatch instead of corrupting data.

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /healthz` | — | Liveness check |
| `POST /v1/register` | — | Create an account, returns a bearer token |
| `POST /v1/prelogin` | — | Return the KDF salt/params for a username |
| `POST /v1/login` | — | Exchange the auth verifier for a token |
| `GET /v1/sync?since=<seq>` | Bearer | Pull records newer than a sequence number |
| `PUT /v1/records` | Bearer | Push a batch of encrypted records (LWW) |
| `DELETE /v1/account` | Bearer | Delete the account and all its data |

## Security model

- The client derives a vault key and an **independent** auth verifier from the
  passphrase (Argon2id + HKDF domain separation). Only the verifier reaches the
  server, and it is stored as a salted SHA-256 hash — a DB leak does not allow
  login (the raw verifier is needed and cannot be recovered from the hash).
- Record payloads are sealed client-side with XChaCha20-Poly1305. The server
  stores `nonce ‖ ciphertext ‖ mac` and never holds a key.
- Login is rate-limited to blunt online guessing.
- Conflict resolution is deterministic last-write-wins keyed by
  `(updatedAt, deviceId)`, identical to the client, so both sides agree.

## Tests

```bash
dart test packages/seance_sync_server
```

Covers the endpoints (register/prelogin/login/push/pull/delete, auth, rate
limiting, protocol-version and open-registration gating), the SQLite backend
(round-trips + durability across reopen), and a full end-to-end run of the real
client against a live server with two devices converging.

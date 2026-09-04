# seance_protocol

The shared foundation, used **verbatim by both the client (`seance_core`) and
the sync server (`seance_sync_server`)** so the wire format and conflict rules
can never drift. Pure Dart, no Flutter.

## Contents

- **Crypto** (`src/crypto/`): `VaultCrypto` (Argon2id KDF → vault key + an
  independent HKDF auth verifier; XChaCha20-Poly1305 seal/open),
  `RecoveryKey` (checksummed Crockford-Base32 code for device enrolment),
  secure random + UUIDv4.
- **Models** (`src/models/`): `ServerConfig`, `Secret`, `HostKey`.
- **Records** (`src/records/`): `EncryptedRecord` (what the server sees — `kind`
  is inside the ciphertext) vs `DecryptedRecord`; `RecordCodec`; `Lww`
  conflict resolution keyed by `(updatedAt, deviceId, seq)`.
- **Sync DTOs** (`src/sync/dtos.dart`) + `kProtocolVersion`.

## Key design points

- Vault key and auth verifier come from **different HKDF salts**, so the server
  (which only ever holds the verifier's salted hash) learns nothing about the
  vault key. (`cryptography` 2.9's `Hkdf` has no `info` field — distinct salts
  are the domain separators.)
- Sealed blob layout is `nonce(24) ‖ ciphertext ‖ mac(16)`.

## KDF resource policy

Prelogin is untrusted. Parsing rejects non-integer JSON encodings, including
integral floating-point values such as `19456.0`. Parsing and derivation reject
memory above 64 MiB, more than 10 iterations or 4 lanes, memory below eight
blocks per lane, and output lengths other than 32 bytes. The app registers with
the default factors and checks `Argon2Params.minimum` before login derivation.
The server enforces resource validity, not that client-side strength policy;
`Argon2Params.fast()` remains test-only. Repository producers emit JSON integers.
These ceilings bound resource use, not execution time on every device.

Previously accepted accounts outside these limits cannot be opened by this
version. Do not edit their stored factors: that derives a different key.
Recover with a compatible trusted client and migrate by decrypting/re-encrypting
under supported factors; back up first. Default accounts are unchanged.

## Test

```bash
dart test packages/seance_protocol
```

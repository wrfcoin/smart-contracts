# Evidence Schema Versioning

`OffenseEvidenceRegistry` currently accepts schema version `1`.

Version `1` canonical fields:
- `offenseCode`
- `evidenceType`
- `reporter`
- `payloadHash`
- `observedAt`
- `validAfter`
- `expiresAt`
- `version`

Versioning rules:
- `evidenceHash` is the deterministic digest of the canonical fields above.
- `reporterSignature` and `witnesses[].signature` are attestations over that digest and are not part of the digest itself.
- `timestamp` is assigned on-chain at submission time and is never part of the off-chain digest.
- A future schema revision must increment `version` and preserve backward validation for already-stored packets.
- Breaking field changes must use a new version number rather than reinterpret an older version's meaning.

Operational guidance:
- Detection systems should construct the canonical packet, compute `evidenceHash`, then collect reporter and witness signatures over that digest.
- Policy APIs should treat `version` as part of the evidence contract and reject packets they cannot decode deterministically.
- Counterpart systems should keep the underlying evidence document addressed by `payloadHash` immutable.

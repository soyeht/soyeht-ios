# Contract: Pair Device URL

## Supported URL

```text
soyeht://household/pair-device?
  v=1
  &hh_pub=<base64url 33-byte SEC1 P-256 public key>
  &nonce=<base64url 32-byte nonce>
  &ttl=<unix-seconds expiry>
```

## Client Validation

The app MUST reject before network action when:

- scheme is not `soyeht`
- host/path is not `household/pair-device`
- `v` is missing or unsupported
- `hh_pub` is missing, not base64url, or not a valid 33-byte compressed P-256 public key
- `nonce` is missing, not base64url, or not 32 bytes
- `ttl` is missing, malformed, or expired
- unknown critical fields are present

## Output

Successful parsing produces `PairDeviceQR` with derived `householdId`. Any non-critical display hints are not trusted for identity.

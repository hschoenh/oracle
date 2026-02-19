
# SSH Warning: "connection is not using a post-quantum key exchange algorithm"

## Summary

When connecting via SSH, the client displayed:

** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
** The server may need to be upgraded. See [https://openssh.com/pq.html](https://openssh.com/pq.html)

This warning does **not** mean the SSH session is unencrypted or broken. It means the SSH **key exchange (KEX)** negotiated between client and server did **not** include a *post-quantum (PQ) capable* hybrid algorithm. As a result, the session could be recorded today and decrypted in the future if large-scale quantum capabilities become practical ("store now, decrypt later").

In our case, the session negotiated:

kex: algorithm: curve25519-sha256

This is strong classical cryptography, but not PQ-hardened.

## Root Cause

The server was running:

- `OpenSSH_8.7p1` (RHEL/Oracle Linux 9.x packaging)
- Supported PQ hybrid KEX:
  - `sntrup761x25519-sha512@openssh.com`
- Did **not** support:
  - `mlkem768x25519-sha256` (newer OpenSSH versions)

The warning appeared because the negotiated KEX was still classical (`curve25519-sha256`) instead of a PQ hybrid KEX.

## Verification Commands

### On the client (macOS)

Show which KEX was negotiated:

```bash
ssh -i "$OCPAGT_KEY" -vv ocphsc10 2>&1 | grep -i 'kex: algorithm'
````

List supported KEX algorithms on the client:

```bash
ssh -Q kex | egrep 'sntrup|mlkem'
```

### On the server

Show supported KEX algorithms (what `sshd` can actually use):

```bash
sudo sshd -T | grep -i kexalgorithms
```

Show OpenSSH version and installed packages:

```bash
ssh -V
rpm -q openssh openssh-server
```

List supported KEX algorithms on the server:

```bash
ssh -Q kex | egrep 'sntrup|mlkem' || true
```

Example output (server):

* OpenSSH: `OpenSSH_8.7p1`
* Supported PQ KEX: `sntrup761x25519-sha512@openssh.com`

## Fix

### Important note

This warning can only be resolved if:

1. The **server** offers a PQ hybrid KEX, and
2. The **client** supports it, and
3. It is negotiated (either by preference order or enforced).

In our environment, the correct PQ hybrid KEX supported by OpenSSH 8.7p1 is:

* `sntrup761x25519-sha512@openssh.com`

### Server-side configuration

We enabled a PQ KEX preference on the server via an `sshd_config.d` drop-in file.

Create configuration file:

```bash
sudo tee /etc/ssh/sshd_config.d/10-pq-kex.conf >/dev/null <<'EOF'
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256
EOF
```

Validate configuration before restart:

```bash
sudo sshd -t
```

Restart sshd:

```bash
sudo systemctl restart sshd
```

Verify effective configuration:

```bash
sudo sshd -T | grep -i kexalgorithms
```

### Client-side validation

Reconnect and check the negotiated KEX:

```bash
ssh -i "$OCPAGT_KEY" -vv ocphsc10 2>&1 | grep -i 'kex: algorithm'
```

Expected result:

```
debug1: kex: algorithm: sntrup761x25519-sha512@openssh.com
```

When this is negotiated successfully, the PQ warning disappears.

## Pitfall we hit (and how to avoid it)

We initially configured:

* `mlkem768x25519-sha256`

But the server OpenSSH version (8.7p1) does **not** support it. This caused `sshd` to fail to start:

```
Unsupported KEX algorithm "mlkem768x25519-sha256"
Bad SSH2 KexAlgorithms ...
```

Lesson learned:

* Always check `ssh -Q kex` on the server before setting `KexAlgorithms`.

## Optional: Forcing the PQ KEX from the client (test)

If the client supports `sntrup...`, it can be forced for testing:

```bash
ssh -i "$OCPAGT_KEY" -o KexAlgorithms=sntrup761x25519-sha512@openssh.com -vv ocphsc10
```

If the client does not support it, you will see "no matching key exchange method found", and the client needs an OpenSSH update.

## Security impact (practical view)

* Without PQ KEX: strong encryption today, but susceptible to future decryption if traffic is recorded and quantum decryption becomes feasible.
* With PQ hybrid KEX (`sntrup + x25519`): protects against that specific future risk by combining classical + post-quantum components.

## References

* OpenSSH PQ status and explanation:
  [https://www.openssh.com/pq.html](https://www.openssh.com/pq.html)

```
::contentReference[oaicite:0]{index=0}
```

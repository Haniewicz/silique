# Test certificate fixtures

These are **test-only keys**. They are not secrets and must never be used
anywhere real (no server, no install, no production config).

Regenerate with:

```sh
tool/make_test_certs.sh
```

| File          | Meaning                                                   |
|---------------|-----------------------------------------------------------|
| `a.pem`/`a.key`       | Cert A — RSA-2048, valid now                                  |
| `b.pem`/`b.key`       | Cert B — a *different* key than A                             |
| `a-prime.pem`/`.key`  | Cert A′ — same key as A, later validity window                |
| `a-expired.pem`/`.key`| Cert A″ — same key as A, already expired                      |

The server-trust tests assert structural relations only: `spki(A) == spki(A′)`,
`spki(A) != spki(B)`, and A″ shares A's spki but is expired. Regenerating these
certificates changes the actual bytes but preserves those relations, so tests
remain meaningful regardless of when they were last generated.

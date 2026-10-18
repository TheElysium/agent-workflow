# `.gates.yml` convention

At the repo root of every project, one `key: single-line command` per gate:

```yaml
stack: rust                      # free-form: rust | go | node | python | tauri...
lint: cargo clippy -- -D warnings
typecheck: cargo check
build: cargo build
test: cargo test
sast: cargo audit
format: cargo fmt --check        # optional
```

- `lint`: the project's configured linter; none → a strict stack default (`clippy -D warnings`, `ruff --strict`, `eslint` strict), and tell the user.
- `sast`: a secrets scan plus the stack's audit tool. Run it when available; a missing tool is proposed for install, never skipped silently.
- Accepted gap = a dated comment on the affected key: `# cargo audit not installed — gap accepted 2026-09-14`.
- Local enforcement is the default: gates run before "done" and before commit. A `.github/workflows/ci.yml` mirror is optional, only where you control CI.

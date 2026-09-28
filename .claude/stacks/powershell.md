# PowerShell 7.5 traps

- Compares and hashtables are case-insensitive by default: `-ceq`/`-cmatch`, `[StringComparer]::Ordinal`, `[string]::CompareOrdinal`.
- Single-element pipeline results unwrap to a scalar: wrap in `@()`.
- Parameter `[Mandatory]` rejects empty strings: add `[AllowEmptyString()]`.
- Arrays returned or piped are flattened: `Write-Output -NoEnumerate` / `,$array` to keep nesting.
- Pipeline capture re-encodes output: write bytes/text via `[Console]::Out` or `[IO.File]`, read with `ReadAllBytes`.
- `Set-Location` does not change the process cwd (`[Environment]::CurrentDirectory`): pass absolute paths to .NET APIs.
- `GetNewClosure()` drops script-scope functions when the script runs via `&`: capture `${function:Name}` into the closure.
- Fail-open top-level `catch` hides bugs: test the exact deployed invocation (shim, hook command line), not only the script.
- Culture-sensitive formatting: set invariant culture on the thread.
- `Sort-Object` is culture-aware and case-insensitive (`-Stable` only keeps ties in order): `[Array]::Sort(..., [StringComparer]::Ordinal)`.
- Encoding: UTF-8 no BOM in and out, LF, ASCII-only sources; `ConvertFrom-Json -DateKind String` (needs 7.5) keeps timestamps verbatim.
- JSONL appends: one `AppendAllText` per line with retry on `IOException` (sharing violation).

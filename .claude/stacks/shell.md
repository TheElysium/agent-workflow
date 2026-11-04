# Shell (bash) traps

- Append JSONL with one external write per record, never a multi-write `printf` loop (Git Bash builtin `printf` splits writes over 1024 bytes).
- Never rely on `flock` for concurrent appends (absent under Git Bash).
- Batch into one `jq` call, never one `jq` per line (~30 ms per spawn, ~23 ms per fork).
- Always `jq -b` (native `jq.exe` writes CRLF).
- Start scripts with `export MSYS2_ARG_CONV_EXCL='*'` (MSYS rewrites `/...` arguments passed to native exes).
- Never trust the jq exit code alone for validity (1.7.1 exits 0 on invalid JSON): also require empty stderr and the expected output.
- Sort with `LC_ALL=C sort` (default order is locale-dependent).
- Require bash 4.4+ (`mapfile -d ''`, `${x,,}`); never target macOS `/bin/bash` 3.2.
- Guard `pwd -W` on `uname -s` (`MINGW*|MSYS*`); it gives the Windows path only under Git Bash.
- List file names with `-z` and read with `mapfile -d ''` (spaces, non-ASCII).
- Stage new executables with `git add --chmod=+x` (`core.filemode` is false on Windows).
- Every script: `set -euo pipefail`, LF endings, ASCII-only source, clean under `shellcheck`.
- `producer | cat >>` is one append only if the record fits the producer's stdio buffer (~4 KB for jq): cap record size.
- `cat >>` copies in 128 KiB chunks: write big appends as line-aligned groups <= 60000 bytes, one `cat <<<` each (fits the 64 KiB pipe buffer), sized under `LC_ALL=C`.
- `${#x}` counts bytes under `LC_ALL=C`: count characters under a probed UTF-8 locale (`C.UTF-8`, `en_US.UTF-8`).

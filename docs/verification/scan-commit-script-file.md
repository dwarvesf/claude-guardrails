# Verification: scan-commit reads the script files a command runs

Change: `lite/scan-commit.sh` and `full/scan-commit.sh` (byte-identical) find every script file a Bash command runs (`bash|sh|zsh|dash|ksh [opts] <file>`, also by path; `source <file>`; `. <file>`; `./file` or any path to an executable text file). Each one is read, never run, and its `cd` and `git commit` lines join the existing checks. A script that commits makes the command a commit; its existing `cd` directories and `git -C` targets become candidates. A script with no commit triggers nothing.

**Fail closed:** a script over the 256 KiB byte budget, or a command with more than 1024 words in its `cd` and script tokens, is not fully read, so the command counts as a commit and the cwd plus every repo the command names are scanned. **Caps** (exit 2): more than 32 candidate directories across command and scripts (script directories count only when they exist), 32 script files, 32 unique `git commit` lines, or 1024 `cd` words in scripts.

Base: `645d67a`. Host: macOS, bash 5.3 (default `bash`) and bash 3.2.57 (`/bin/bash`), BSD grep. Ubuntu 24.04 container: bash 5.2.21, GNU grep 3.11.

## Green run

Every scenario in `tests/ci-test.sh`, before (base) and after (fixed tree).

| Scenario | Before | After |
| --- | --- | --- |
| `lite-fresh` | 12 passed, 0 failed | 12 passed, 0 failed |
| `full-fresh` | 15 passed, 0 failed | 15 passed, 0 failed |
| `lite-idempotent` | 4 passed, 0 failed | 4 passed, 0 failed |
| `full-idempotent` | 5 passed, 0 failed | 5 passed, 0 failed |
| `lite-roundtrip` | 10 passed, 0 failed | 10 passed, 0 failed |
| `full-roundtrip` | 11 passed, 0 failed | 11 passed, 0 failed |
| `merge-existing` | 14 passed, 0 failed | 14 passed, 0 failed |
| `legacy-deny-migration` | 7 passed, 0 failed | 7 passed, 0 failed |
| `scan-commit` | 8 passed, 0 failed | 8 passed, 0 failed |
| `scan-commit-cargo-lock` | 15 passed, 0 failed | 15 passed, 0 failed |
| `scan-commit-target-repo` | 34 passed, 0 failed | 34 passed, 0 failed |
| `scan-commit-script-file` | (new) | 32 passed, 0 failed |
| `push-hook` | 13 passed, 0 failed | 13 passed, 0 failed |
| `schema-remediation` | 4 passed, 0 failed | 4 passed, 0 failed |
| `bip39-scan` | 16 passed, 0 failed | 16 passed, 0 failed |
| `wallet-key-regex` | 9 passed, 0 failed | 9 passed, 0 failed |
| `scan-secrets-hash-context` | 37 passed, 0 failed | 37 passed, 0 failed |
| `scan-commit`, `scan-commit-cargo-lock`, `scan-commit-target-repo`, `scan-commit-script-file` with `/bin/bash` 3.2.57 | | 8 / 15 / 34 / 32 passed, 0 failed |
| same four in `ubuntu:24.04` (GNU grep 3.11, bash 5.2.21) | | 8 / 15 / 34 / 32 passed, 0 failed |

Total before: 16 scenarios, 214 assertions. After: 17 scenarios, 246 assertions, 0 failed.

New scenario output (fixed hook):

```
  PASS: scan-commit hook is executable
  PASS: bash <script> that cds into a repo with a staged secret (blocked) (2)
  PASS: bash <script> that cds into a clean repo (allowed) (0)
  PASS: bash <script> without a commit does not trigger a scan (allowed) (0)
  PASS: sh <script> (blocked) (2)
  PASS: zsh <script> (blocked) (2)
  PASS: bash -x -e <script> (blocked) (2)
  PASS: /bin/bash <script> (blocked) (2)
  PASS: /usr/bin/env bash <script> 2>&1 (blocked) (2)
  PASS: source <script> (blocked) (2)
  PASS: . <script> (blocked) (2)
  PASS: <absolute path to an executable script> (blocked) (2)
  PASS: cd <dir> && ./<script> (blocked) (2)
  PASS: cd <dir> && bash <relative script> (blocked) (2)
  PASS: bash <script relative to the cwd> (blocked) (2)
  PASS: bash "<script>" after another command (blocked) (2)
  PASS: bash "<script path with space>" (blocked) (2)
  PASS: script with git -C <repoB> commit (blocked) (2)
  PASS: script with a cd relative to the cwd (blocked) (2)
  PASS: script with cd then a relative git -C (blocked) (2)
  PASS: non-executable ./<file> is not read (allowed) (0)
  PASS: bash <non-executable file> is read (blocked) (2)
  PASS: absolute path to a binary is not read (allowed) (0)
  PASS: script over the size cap: cwd still scanned (blocked) (2)
  PASS: script with 80 cds into 2 directories (allowed, under the cap) (0)
  PASS: script with 80 cds into 2 directories, secret in one (blocked) (2)
  PASS: 16 command cds + 17 script cds (blocked at the combined cap) (2)
  PASS: 1 command cd + 17 script cds (allowed, under the cap) (0)
  PASS: 33 script files in one command (blocked at the cap) (2)
  PASS: script with 1050 cd words (blocked at the word cap) (2)
  PASS: command with 1100 path words, clean cwd (allowed) (0)
  PASS: command with 1100 path words: walk stops, cwd scanned (blocked) (2)
Results: 32 passed, 0 failed
```

## NEGATIVE CONTROL

The same scenario against the base hook (`git show HEAD:full/scan-commit.sh`, copied into a scratch tree). Case (1), `bash <script>` into a repo with a staged secret, is allowed:

```
  PASS: scan-commit hook is executable
  FAIL: bash <script> that cds into a repo with a staged secret (blocked) — expected '2', got '0'
  PASS: bash <script> that cds into a clean repo (allowed) (0)
  PASS: bash <script> without a commit does not trigger a scan (allowed) (0)
  FAIL: sh <script> (blocked) — expected '2', got '0'
  FAIL: zsh <script> (blocked) — expected '2', got '0'
  FAIL: bash -x -e <script> (blocked) — expected '2', got '0'
  FAIL: /bin/bash <script> (blocked) — expected '2', got '0'
  FAIL: /usr/bin/env bash <script> 2>&1 (blocked) — expected '2', got '0'
  FAIL: source <script> (blocked) — expected '2', got '0'
  FAIL: . <script> (blocked) — expected '2', got '0'
  FAIL: <absolute path to an executable script> (blocked) — expected '2', got '0'
  FAIL: cd <dir> && ./<script> (blocked) — expected '2', got '0'
  FAIL: cd <dir> && bash <relative script> (blocked) — expected '2', got '0'
  FAIL: bash <script relative to the cwd> (blocked) — expected '2', got '0'
  FAIL: bash "<script>" after another command (blocked) — expected '2', got '0'
  FAIL: bash "<script path with space>" (blocked) — expected '2', got '0'
  FAIL: script with git -C <repoB> commit (blocked) — expected '2', got '0'
  FAIL: script with a cd relative to the cwd (blocked) — expected '2', got '0'
  FAIL: script with cd then a relative git -C (blocked) — expected '2', got '0'
  PASS: non-executable ./<file> is not read (allowed) (0)
  FAIL: bash <non-executable file> is read (blocked) — expected '2', got '0'
  PASS: absolute path to a binary is not read (allowed) (0)
  FAIL: script over the size cap: cwd still scanned (blocked) — expected '2', got '0'
  PASS: script with 80 cds into 2 directories (allowed, under the cap) (0)
  FAIL: script with 80 cds into 2 directories, secret in one (blocked) — expected '2', got '0'
  FAIL: 16 command cds + 17 script cds (blocked at the combined cap) — expected '2', got '0'
  PASS: 1 command cd + 17 script cds (allowed, under the cap) (0)
  FAIL: 33 script files in one command (blocked at the cap) — expected '2', got '0'
  FAIL: script with 1050 cd words (blocked at the word cap) — expected '2', got '0'
  PASS: command with 1100 path words, clean cwd (allowed) (0)
  FAIL: command with 1100 path words: walk stops, cwd scanned (blocked) — expected '2', got '0'
Results: 8 passed, 24 failed
```

## Timing against the 10 s hook timeout

Crafted scripts near the byte budget, hook run directly (`exit` is the hook's):

| Script | bash 5.3 | bash 3.2 |
| --- | --- | --- |
| 18600 `cd /nx/dNNNNN` lines (260 KB), before the word cap | 1.12 s | 1.44 s |
| 6000 `cd a b ... y` lines (255 KB), before the word cap | 14.46 s | 35.96 s (fail open) |
| 18600 one-word `cd` lines, with the word cap | 0.19 s, exit 2 | 0.20 s, exit 2 |
| 6000 25-word `cd` lines, with the word cap | 0.13 s, exit 2 | 0.19 s, exit 2 |
| 9000 `git -C /nx/rNN commit` lines (225 KB, 20 unique) | 0.27 s, exit 0 | 0.46 s, exit 0 |
| non-commit `ls -la /tmp ./x` | 0.03 s | 0.03 s |

Self-check: the hook on `bash tests/ci-test.sh scan-commit` with this repo as cwd (the test file has 35 `cd`s and several `git commit` strings) exits 0: it reads the file, counts the command as a commit, scans the clean cwd, and stays under the caps.

## Reproduce

```bash
bash tests/ci-test.sh scan-commit-script-file
PATH=/bin:$PATH bash tests/ci-test.sh scan-commit-script-file
```

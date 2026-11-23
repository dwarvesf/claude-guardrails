# Verification: scan-commit reads the script files a command runs

Change: `lite/scan-commit.sh` and `full/scan-commit.sh` (byte-identical) find every script file a Bash command runs (`bash|sh|zsh|dash|ksh [opts] <file>`, also by path; `source <file>`; `. <file>`; `./file` or any path to an executable text file). Each one is read, never run, and its `cd` and `git commit` lines join the existing checks. A script that commits makes the command a commit; its existing `cd` directories and `git -C` targets become candidates. A script with no commit triggers nothing.

**Fail closed:** a script over 256 KiB (a per-file cap; a shared budget let a filler script leave the commit script unread), or a command with more than 1024 words in its `cd` and script tokens, is not fully read, so the command counts as a commit and the cwd plus every repo the command names are scanned. **Caps** (exit 2): more than 32 candidate directories across command and scripts (script directories count only when they exist), 32 unique `git commit` lines, or 1024 `cd` words in scripts. Only 32 scripts are parsed. The rest are grepped once for a commit and block only if one commits, or if together they exceed 8 MiB. **Timeout bounds:** a token line over 4096 characters is not parsed (counts as a commit). A no-`#!` executable is size-checked before its text probe, and at most 32 are probed. The overflow list is an array (a string append was quadratic).

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
| `scan-commit-script-file` | (new) | 33 passed, 0 failed |
| `push-hook` | 13 passed, 0 failed | 13 passed, 0 failed |
| `schema-remediation` | 4 passed, 0 failed | 4 passed, 0 failed |
| `bip39-scan` | 16 passed, 0 failed | 16 passed, 0 failed |
| `wallet-key-regex` | 9 passed, 0 failed | 9 passed, 0 failed |
| `scan-secrets-hash-context` | 37 passed, 0 failed | 37 passed, 0 failed |
| `scan-commit`, `scan-commit-cargo-lock`, `scan-commit-target-repo`, `scan-commit-script-file` with `/bin/bash` 3.2.57 | | 8 / 15 / 34 / 33 passed, 0 failed |
| same four in `ubuntu:24.04` (GNU grep 3.11, bash 5.2.21) | | 8 / 15 / 34 / 33 passed, 0 failed |

Total before: 16 scenarios, 214 assertions. After: 17 scenarios, 247 assertions, 0 failed.

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
  PASS: filler script just under the cap, then the commit script (blocked) (2)
  PASS: script with 80 cds into 2 directories (allowed, under the cap) (0)
  PASS: script with 80 cds into 2 directories, secret in one (blocked) (2)
  PASS: 16 command cds + 17 script cds (blocked at the combined cap) (2)
  PASS: 1 command cd + 17 script cds (allowed, under the cap) (0)
  PASS: 33 script files in one command (blocked at the cap) (2)
  PASS: script with 1050 cd words (blocked at the word cap) (2)
  PASS: command with 1100 path words, clean cwd (allowed) (0)
  PASS: command with 1100 path words: walk stops, cwd scanned (blocked) (2)
Results: 33 passed, 0 failed
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
  FAIL: filler script just under the cap, then the commit script (blocked) — expected '2', got '0'
  PASS: script with 80 cds into 2 directories (allowed, under the cap) (0)
  FAIL: script with 80 cds into 2 directories, secret in one (blocked) — expected '2', got '0'
  FAIL: 16 command cds + 17 script cds (blocked at the combined cap) — expected '2', got '0'
  PASS: 1 command cd + 17 script cds (allowed, under the cap) (0)
  FAIL: 33 script files in one command (blocked at the cap) — expected '2', got '0'
  FAIL: script with 1050 cd words (blocked at the word cap) — expected '2', got '0'
  PASS: command with 1100 path words, clean cwd (allowed) (0)
  FAIL: command with 1100 path words: walk stops, cwd scanned (blocked) — expected '2', got '0'
Results: 8 passed, 25 failed
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
| 32 scripts of 250 KB, each all `git commit` lines (per-file cap) | 1.06 s, exit 0 | 1.10 s, exit 0 |
| `git commit -m x; ls <1000 real executables>` | 0.08 s, exit 2 (more than 32 script files) | 0.10 s, exit 2 |

Budget decoy (`bash <262 KB filler>; bash commit.sh`, secret only in the commit script's repo): exit 0 with a shared 256 KiB budget (first version of this change), exit 2 with the per-file cap.

Self-check: the hook on `bash tests/ci-test.sh scan-commit` with this repo as cwd (the test file has 35 `cd`s and several `git commit` strings) exits 0: it reads the file, counts the command as a commit, scans the clean cwd, and stays under the caps.

## Reproduce

```bash
bash tests/ci-test.sh scan-commit-script-file
PATH=/bin:$PATH bash tests/ci-test.sh scan-commit-script-file
```

## Security review round (commit after 0401775)

An independent review found two timeout fail-opens and one blocking bug. Full suite, every scenario, before (`0401775`, exported to a scratch tree) and after:

| Scenario | Before (`0401775`) | After |
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
| `scan-commit-script-file` | 33 passed, 0 failed | 46 passed, 0 failed |
| `push-hook` | 13 passed, 0 failed | 13 passed, 0 failed |
| `schema-remediation` | 4 passed, 0 failed | 4 passed, 0 failed |
| `bip39-scan` | 16 passed, 0 failed | 16 passed, 0 failed |
| `wallet-key-regex` | 9 passed, 0 failed | 9 passed, 0 failed |
| `scan-secrets-hash-context` | 37 passed, 0 failed | 37 passed, 0 failed |

Total before: 17 scenarios, 247 passed, 0 failed. After: 17 scenarios, 260 passed, 0 failed. `/bin/bash` 3.2.57: `scan-commit-script-file` 46 passed, 0 failed. `ubuntu:24.04` (GNU grep 3.11, bash 5.2.21): 8 / 15 / 34 / 46 passed, 0 failed.

Negative control, the final scenario against the `0401775` hook:

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
  PASS: filler script just under the cap, then the commit script (blocked) (2)
  PASS: script with 80 cds into 2 directories (allowed, under the cap) (0)
  PASS: script with 80 cds into 2 directories, secret in one (blocked) (2)
  PASS: 16 command cds + 17 script cds (blocked at the combined cap) (2)
  PASS: 1 command cd + 17 script cds (allowed, under the cap) (0)
  FAIL: git add <40 scripts>, no commit (allowed) — expected '0', got '2'
  FAIL: shellcheck <40 scripts>, no commit (allowed) — expected '0', got '2'
  FAIL: git add <40 scripts> && git commit, none commits (allowed) — expected '0', got '2'
  PASS: 40 scripts, the 40th commits (blocked at the cap) (2)
  PASS: script with a 255 KB cd word, secret in repoB (blocked) (2)
  FAIL: script with a 255 KB cd word, secret in repoB (blocked) took 44s (limit 4s)
  PASS: script with a 240 KB line of quoted cd words, secret in repoB (blocked) (2)
  FAIL: script with a 240 KB line of quoted cd words, secret in repoB (blocked) took 10s (limit 4s)
  PASS: 100 MB executable named 20 times, secret in cwd (blocked) (2)
  FAIL: 100 MB executable named 20 times, secret in cwd (blocked) took 5s (limit 2s)
  PASS: 66 scripts of 255 KB: the 34 past the parse cap exceed 8 MiB (blocked) (2)
  PASS: 66 scripts of 255 KB: the 34 past the parse cap exceed 8 MiB (blocked) finished in 0s (limit 4s)
  FAIL: 40 scripts of 255 KB, no commit (allowed) — expected '0', got '2'
  PASS: 40 scripts of 255 KB, no commit (allowed) finished in 0s (limit 4s)
  PASS: script with 1050 cd words (blocked at the word cap) (2)
  PASS: command with 1100 path words, clean cwd (allowed) (0)
  PASS: command with 1100 path words: walk stops, cwd scanned (blocked) (2)
Results: 39 passed, 7 failed
```

Timing, final hook (bash 5.3 then `/bin/bash` 3.2):

```
1: git commit && bash p1.sh (long cd word)     /opt/homebrew/bin/bash exit=0   0.07s 
1: git commit && bash p1.sh (long cd word)     /bin/bash              exit=0   0.07s 
1b: git commit && bash p2.sh ("a b" words)     /opt/homebrew/bin/bash exit=2   0.12s within the hook's time limit (more than 1024 cd arguments in script files).
1b: git commit && bash p2.sh ("a b" words)     /bin/bash              exit=2   0.16s within the hook's time limit (more than 1024 cd arguments in script files).
2: git commit; : ./big x6                      /opt/homebrew/bin/bash exit=0   0.05s 
2: git commit; : ./big x6                      /bin/bash              exit=0   0.04s 
3: git add <40 scripts>                        /opt/homebrew/bin/bash exit=0   0.21s 
3: git add <40 scripts>                        /bin/bash              exit=0   0.20s 
3: shellcheck <40 scripts>                     /opt/homebrew/bin/bash exit=0   0.22s 
3: shellcheck <40 scripts>                     /bin/bash              exit=0   0.21s 
3: git add <40 scripts> && git commit          /opt/homebrew/bin/bash exit=0   0.23s 
3: git add <40 scripts> && git commit          /bin/bash              exit=0   0.23s 
one-word-cds.sh bytes=260428
  /opt/homebrew/bin/bash   exit=2  0.16s
  /bin/bash                exit=2  0.19s
many-word-cds.sh bytes=255029
  /opt/homebrew/bin/bash   exit=2  0.12s
  /bin/bash                exit=2  0.15s
git-c-lines.sh bytes=225013
  /opt/homebrew/bin/bash   exit=0  0.09s
  /bin/bash                exit=0  0.09s
git commit; ls <1000 real executables>       /opt/homebrew/bin/bash   exit=0 0.08s 
git commit; ls <1000 real executables>       /bin/bash                exit=0 0.07s 
bash filler.sh; bash commit.sh (secret in B) /opt/homebrew/bin/bash   exit=2 0.12s Repository: 
bash filler.sh; bash commit.sh (secret in B) /bin/bash                exit=2 0.11s Repository: 
bash commit.sh alone (secret in B)           /opt/homebrew/bin/bash   exit=2 0.09s Repository: 
bash commit.sh alone (secret in B)           /bin/bash                exit=2 0.09s Repository: 
32 x 250 KB of git commit lines              /opt/homebrew/bin/bash   exit=0 0.95s 
32 x 250 KB of git commit lines              /bin/bash                exit=0 0.96s 
1000 x 250 KB scripts, git add && git commit  /opt/homebrew/bin/bash exit=2 1.23s
1000 x 250 KB scripts, git add && git commit  /bin/bash              exit=2 1.10s
```

Before the fix, case 1 took 43.87 s on bash 5.3. Its `/bin/bash` 3.2 run had not finished after 15 minutes and was stopped.

## Rescope (review round 2, after ab2cc08)

The cap-by-cap fixes kept leaking: a per-word bash loop stayed quadratic below every cap (13.64 s repro), an oversize executable and an over-long token line were skipped silently, and every argument after `bash` was taken as a script. The script section was rewritten around one awk lexer: scripts are found at command position only, all of them are lexed in one linear pass, and every limit blocks outright. `full/scan-commit.sh`: 556 lines at `ab2cc08`, 543 after.

| Scenario | Before (`ab2cc08`) | After |
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
| `scan-commit-script-file` | 46 passed, 0 failed | 67 passed, 0 failed |
| `push-hook` | 13 passed, 0 failed | 13 passed, 0 failed |
| `schema-remediation` | 4 passed, 0 failed | 4 passed, 0 failed |
| `bip39-scan` | 16 passed, 0 failed | 16 passed, 0 failed |
| `wallet-key-regex` | 9 passed, 0 failed | 9 passed, 0 failed |
| `scan-secrets-hash-context` | 37 passed, 0 failed | 37 passed, 0 failed |

Total before: 17 scenarios, 260 passed, 0 failed. After: 17 scenarios, 281 passed, 0 failed. The four scan-commit scenarios (8 / 15 / 34 / 67 passed, 0 failed) also pass with `/bin/bash` 3.2.57, with mawk 1.3.4 and gawk 5.4.1 as `awk`, and in `ubuntu:24.04` (mawk 1.3.4, GNU grep 3.11, bash 5.2.21).

Negative control, the final scenario against the `ab2cc08` hook:

```
  FAIL: script over the 2 MiB budget (blocked) — expected '2', got '0'
  FAIL: git add <40 scripts>, the 40th commits but does not run (allowed) — expected '0', got '2'
  FAIL: git add <66 scripts of 255 KB> (allowed, nothing runs) — expected '0', got '2'
  FAIL: 9 scripts of 255 KB run (blocked: over 2 MiB) — expected '2', got '0'
  FAIL: command with 1100 path words, secret in cwd, no commit (allowed) — expected '0', got '2'
  FAIL: 32x32 quoted cd words named, secret in cwd (blocked) took 14s (limit 2s)
  FAIL: 32x16 quoted cd words run (2 MB), secret in cwd (blocked) took 7s (limit 2s)
  FAIL: 32x32 quoted cd words run (4 MB, over budget) (blocked) took 14s (limit 2s)
  FAIL: #! executable over 2 MiB run by path (blocked) — expected '2', got '0'
  FAIL: text executable over 2 MiB run by path (blocked) — expected '2', got '0'
  FAIL: script git -C <repoB> beside a 5000-char option (blocked) — expected '2', got '0'
  FAIL: bash <5000-char script path> (blocked) — expected '2', got '0'
  FAIL: bash <script> <commit script as an argument> (allowed) — expected '0', got '2'
  FAIL: bash -c <string> (no script file, allowed) — expected '0', got '2'
  FAIL: bash <missing script> (blocked) — expected '2', got '0'
  FAIL: bash <variable script path> (blocked) — expected '2', got '0'
Results: 51 passed, 16 failed
```

Timing, final hook (bash 5.3 then `/bin/bash` 3.2):

```
reviewer repro: git commit; : <32 scripts>           /opt/homebrew/bin/bash exit=2  0.07s
reviewer repro: git commit; : <32 scripts>           /bin/bash              exit=2  0.07s
32 x 16 lines run (2 MB, quote-heavy)                /opt/homebrew/bin/bash exit=2  0.92s
32 x 16 lines run (2 MB, quote-heavy)                /bin/bash              exit=2  0.94s
255 KB quoted cd word                                /opt/homebrew/bin/bash exit=2  0.15s
255 KB quoted cd word                                /bin/bash              exit=2  0.15s
2 MB plain-text script                               /opt/homebrew/bin/bash exit=2  0.17s
2 MB plain-text script                               /bin/bash              exit=2  0.16s
2 MB of short cd lines and separators                /opt/homebrew/bin/bash exit=2  0.05s
2 MB of short cd lines and separators                /bin/bash              exit=2  0.04s
2 MB of git -C commit lines (50 targets)             /opt/homebrew/bin/bash exit=2  0.38s
2 MB of git -C commit lines (50 targets)             /bin/bash              exit=2  0.40s
2 MB single line of short words                      /opt/homebrew/bin/bash exit=2  0.42s
2 MB single line of short words                      /bin/bash              exit=2  0.46s
2 MB single line of quoted words                     /opt/homebrew/bin/bash exit=2  0.87s
2 MB single line of quoted words                     /bin/bash              exit=2  0.89s
1 MB single-line command, no script                  /opt/homebrew/bin/bash exit=0  0.27s
1 MB single-line command, no script                  /bin/bash              exit=0  0.33s
plain non-commit command                             /opt/homebrew/bin/bash exit=0  0.04s
plain non-commit command                             /bin/bash              exit=0  0.03s
```

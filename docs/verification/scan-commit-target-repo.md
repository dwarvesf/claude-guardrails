# Verification: scan-commit scans the repo the commit targets

Change: `lite/scan-commit.sh` and `full/scan-commit.sh` (byte-identical) detect `git [-C <dir>] [-c <k=v>] commit` and scan the staged diff of the target repo: each `cd <dir>` before the commit applied in order, then the commit's own `-C`; a target that is not a git repo falls back to the payload cwd. Base: `39440d9`. Host: macOS, bash 5.3 (default `bash`), bash 3.2.57 (`/bin/bash`), BSD awk (default), mawk 1.3.4, gawk 5.4.1. The Ubuntu workflow matrix was not dispatched.

## Green run

Every scenario in `tests/ci-test.sh`, run on the fixed tree with `bash tests/ci-test.sh <scenario>`.

| Command | Exit | Verdict |
| --- | --- | --- |
| `bash tests/ci-test.sh lite-fresh` | 0 | PASS, `Results: 12 passed, 0 failed` |
| `bash tests/ci-test.sh full-fresh` | 0 | PASS, `Results: 15 passed, 0 failed` |
| `bash tests/ci-test.sh lite-idempotent` | 0 | PASS, `Results: 4 passed, 0 failed` |
| `bash tests/ci-test.sh full-idempotent` | 0 | PASS, `Results: 5 passed, 0 failed` |
| `bash tests/ci-test.sh lite-roundtrip` | 0 | PASS, `Results: 10 passed, 0 failed` |
| `bash tests/ci-test.sh full-roundtrip` | 0 | PASS, `Results: 11 passed, 0 failed` |
| `bash tests/ci-test.sh merge-existing` | 0 | PASS, `Results: 14 passed, 0 failed` |
| `bash tests/ci-test.sh legacy-deny-migration` | 0 | PASS, `Results: 7 passed, 0 failed` |
| `bash tests/ci-test.sh scan-commit` | 0 | PASS, `Results: 8 passed, 0 failed` |
| `bash tests/ci-test.sh scan-commit-cargo-lock` | 0 | PASS, `Results: 15 passed, 0 failed` |
| `bash tests/ci-test.sh scan-commit-target-repo` | 0 | PASS, `Results: 22 passed, 0 failed` |
| `bash tests/ci-test.sh push-hook` | 0 | PASS, `Results: 13 passed, 0 failed` |
| `bash tests/ci-test.sh schema-remediation` | 0 | PASS, `Results: 4 passed, 0 failed` |
| `bash tests/ci-test.sh bip39-scan` | 0 | PASS, `Results: 16 passed, 0 failed` |
| `bash tests/ci-test.sh wallet-key-regex` | 0 | PASS, `Results: 9 passed, 0 failed` |
| `bash tests/ci-test.sh scan-secrets-hash-context` | 0 | PASS, `Results: 37 passed, 0 failed` |
| `scan-commit`, `scan-commit-cargo-lock`, `scan-commit-target-repo` with `bash` = `/bin/bash` 3.2.57 | 0 | PASS, 8 / 15 / 22 passed, 0 failed |
| same three with `awk` = mawk 1.3.4 and `bash` = 3.2.57 | 0 | PASS, 8 / 15 / 22 passed, 0 failed |
| same three with `awk` = gawk 5.4.1 and `bash` = 3.2.57 | 0 | PASS, 8 / 15 / 22 passed, 0 failed |

Total: 16 scenarios, 202 assertions, 0 failed.

New scenario output (fixed hook):

```text
  PASS: scan-commit hook is executable
  PASS: git -C <repoB> commit scans repoB (blocked) (2)
  PASS: git -C relative path resolves against cwd (blocked) (2)
  PASS: git -c k="v w" -C "<repoB>" commit (blocked) (2)
  PASS: git -C <repoB> commit-tree not intercepted (0)
  PASS: cd then relative -C composes (blocked) (2)
  PASS: "git commit" inside the message does not hide -C (blocked) (2)
  PASS: cd <repoB> && commit ignores repoA's staged secret (allowed) (0)
  PASS: cd <repoB> && commit scans repoB (blocked) (2)
  PASS: relative cd resolves against cwd (blocked) (2)
  PASS: cd ~/<path> expands to HOME (blocked) (2)
  PASS: last cd before the commit wins (blocked) (2)
  PASS: cd "<path with space>" (blocked) (2)
  PASS: git -C '<path with space>' (blocked) (2)
  PASS: plain commit, clean cwd repo (allowed) (0)
  PASS: plain commit, secret in cwd repo (blocked) (2)
  PASS: missing cd target falls back to cwd (blocked) (2)
  PASS: variable cd target falls back to cwd (blocked) (2)
  PASS: non-repo cd target falls back to cwd (blocked) (2)
  PASS: cd inside quoted text falls back to cwd (blocked) (2)
  PASS: cd sub && cd .. returns to the cwd repo (blocked) (2)
  PASS: cd into a repo subdir scans that repo (blocked) (2)
Results: 22 passed, 0 failed
```

Large-input check under bash 3.2 and 5.3: a 100 KB `git -C "<100 KB path>" commit`, a 200 KB `echo "<100 KB>" && cd /tmp && git -c a=b commit -m "<100 KB>"`, and a command with 1,000 `cd /tmp;` before the commit each finish in 2 s or less. The prefix before the commit comes from awk `index()` and each `cd` regex pass captures the remainder, so there are no quadratic `${var%%...}` / `${var#*...}` strips.

## NEGATIVE CONTROL

Control 1: both hooks reverted to the base version, new scenario rerun.

Command:

```bash
git show 39440d9:full/scan-commit.sh >| full/scan-commit.sh
git show 39440d9:lite/scan-commit.sh >| lite/scan-commit.sh
bash tests/ci-test.sh scan-commit-target-repo
```

Exit: 1 (the runner prints an em dash before "expected"; shown here as a hyphen)

Output:

```text
  FAIL: git -C <repoB> commit scans repoB (blocked) - expected '2', got '0'
  FAIL: git -C relative path resolves against cwd (blocked) - expected '2', got '0'
  FAIL: git -c k="v w" -C "<repoB>" commit (blocked) - expected '2', got '0'
  FAIL: cd then relative -C composes (blocked) - expected '2', got '0'
  FAIL: "git commit" inside the message does not hide -C (blocked) - expected '2', got '0'
  FAIL: cd <repoB> && commit ignores repoA's staged secret (allowed) - expected '0', got '2'
  FAIL: cd <repoB> && commit scans repoB (blocked) - expected '2', got '0'
  FAIL: relative cd resolves against cwd (blocked) - expected '2', got '0'
  FAIL: cd ~/<path> expands to HOME (blocked) - expected '2', got '0'
  FAIL: last cd before the commit wins (blocked) - expected '2', got '0'
  FAIL: cd "<path with space>" (blocked) - expected '2', got '0'
  FAIL: git -C '<path with space>' (blocked) - expected '2', got '0'
Results: 10 passed, 12 failed
```

Verdict: the scenario detects both reported failures. The base hook lets `git -C <repoB> commit` through with a staged secret (failure 1) and blocks a clean repoB's `cd && git commit` on repoA's staged secret while leaving repoB unscanned (failure 2). The 10 passing cases are unchanged behaviour: plumbing pass-through, plain commits in the cwd, and the cwd fallbacks.

Control 2: both hooks set to the first fix commit (`48225c1`, last `cd` only, non-repo target exited 0), new scenario rerun.

Command:

```bash
git show 48225c1:full/scan-commit.sh >| full/scan-commit.sh
git show 48225c1:lite/scan-commit.sh >| lite/scan-commit.sh
bash tests/ci-test.sh scan-commit-target-repo
```

Exit: 1

Output:

```text
  FAIL: non-repo cd target falls back to cwd (blocked) - expected '2', got '0'
  FAIL: cd inside quoted text falls back to cwd (blocked) - expected '2', got '0'
  FAIL: cd sub && cd .. returns to the cwd repo (blocked) - expected '2', got '0'
Results: 19 passed, 3 failed
```

Verdict: the added cases catch the silent allows that version introduced (`cd sub && make && cd .. && git commit` resolved to the parent of the cwd repo and exited 0).

After both controls the fixed hooks were restored (`cmp` equal to the saved copy) and the scenario rerun: `Results: 22 passed, 0 failed`, exit 0.

## Reproduce

```bash
bash tests/ci-test.sh scan-commit-target-repo
```

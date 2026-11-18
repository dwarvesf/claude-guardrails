# Verification: scan-commit scans the repo the commit targets

Change: `lite/scan-commit.sh` and `full/scan-commit.sh` (byte-identical) detect `git [-C <dir>] [-c <k=v>] commit` and scan the staged diff of the target repo: the last `cd <dir>` before the commit, then the commit's own `-C`, else the payload cwd. Base: `39440d9`. Host: macOS, bash 5.3 (default `bash`) and bash 3.2.57 (`/bin/bash`).

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
| `bash tests/ci-test.sh scan-commit-target-repo` | 0 | PASS, `Results: 18 passed, 0 failed` |
| `bash tests/ci-test.sh push-hook` | 0 | PASS, `Results: 13 passed, 0 failed` |
| `bash tests/ci-test.sh schema-remediation` | 0 | PASS, `Results: 4 passed, 0 failed` |
| `bash tests/ci-test.sh bip39-scan` | 0 | PASS, `Results: 16 passed, 0 failed` |
| `bash tests/ci-test.sh wallet-key-regex` | 0 | PASS, `Results: 9 passed, 0 failed` |
| `bash tests/ci-test.sh scan-secrets-hash-context` | 0 | PASS, `Results: 37 passed, 0 failed` |
| `scan-commit-target-repo` with `bash` resolving to `/bin/bash` 3.2.57 | 0 | PASS, `Results: 18 passed, 0 failed` |
| `scan-commit`, `scan-commit-cargo-lock`, `scan-commit-target-repo` with `awk` = mawk 1.3.4, then gawk 5.4.1, bash 3.2 | 0 | PASS, 8/15/18 passed, 0 failed each |

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
Results: 18 passed, 0 failed
```

Large-input check: a 100 KB `git -C "<100 KB path>" commit` and a 200 KB `echo "<100 KB>" && cd /tmp && git -c a=b commit -m "<100 KB>"` each finish in about 1 s or less under bash 3.2 and 5.3 (prefix found with awk `index()`, last `cd` with one greedy regex, no quadratic `${var%%...}` strips).

## NEGATIVE CONTROL

Both hooks reverted to the base version, the new scenario rerun, then the fixed hooks restored (`cmp` equal) and rerun green.

Command:

```bash
git show HEAD:full/scan-commit.sh >| full/scan-commit.sh
git show HEAD:lite/scan-commit.sh >| lite/scan-commit.sh
bash tests/ci-test.sh scan-commit-target-repo
```

Exit: 1 (the runner prints an em dash before "expected"; shown here as a hyphen)

Output:

```text
  PASS: scan-commit hook is executable
  FAIL: git -C <repoB> commit scans repoB (blocked) - expected '2', got '0'
  FAIL: git -C relative path resolves against cwd (blocked) - expected '2', got '0'
  FAIL: git -c k="v w" -C "<repoB>" commit (blocked) - expected '2', got '0'
  PASS: git -C <repoB> commit-tree not intercepted (0)
  FAIL: cd then relative -C composes (blocked) - expected '2', got '0'
  FAIL: "git commit" inside the message does not hide -C (blocked) - expected '2', got '0'
  FAIL: cd <repoB> && commit ignores repoA's staged secret (allowed) - expected '0', got '2'
  FAIL: cd <repoB> && commit scans repoB (blocked) - expected '2', got '0'
  FAIL: relative cd resolves against cwd (blocked) - expected '2', got '0'
  FAIL: cd ~/<path> expands to HOME (blocked) - expected '2', got '0'
  FAIL: last cd before the commit wins (blocked) - expected '2', got '0'
  FAIL: cd "<path with space>" (blocked) - expected '2', got '0'
  FAIL: git -C '<path with space>' (blocked) - expected '2', got '0'
  PASS: plain commit, clean cwd repo (allowed) (0)
  PASS: plain commit, secret in cwd repo (blocked) (2)
  PASS: missing cd target falls back to cwd (blocked) (2)
  PASS: variable cd target falls back to cwd (blocked) (2)
Results: 6 passed, 12 failed
```

Verdict: the scenario detects the bug. The old hook lets `git -C <repoB> commit` through with a staged secret (failure 1) and blocks a clean repoB's `cd && git commit` on repoA's staged secret (failure 2). The six cases that still pass are the unchanged behaviour: plumbing pass-through, plain commits in the cwd, and the cwd fallback. After restoring the fix: `Results: 18 passed, 0 failed`, exit 0.

## Reproduce

```bash
bash tests/ci-test.sh scan-commit-target-repo
```

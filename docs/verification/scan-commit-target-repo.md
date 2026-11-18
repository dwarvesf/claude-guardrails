# Verification: scan-commit scans every repo a commit command names (fail closed)

Change: `lite/scan-commit.sh` and `full/scan-commit.sh` (byte-identical) detect `git [-C <dir>] [-c <k=v>] commit` and scan the staged diff of every candidate repo: the payload cwd (always, never replaced), every argument of every `cd` in the command (composed against the preceding `cd`s and raw against the cwd), and every `-C` of every `git commit` occurrence (against each of those directories and raw against the cwd). Candidates are deduped by `git rev-parse --show-toplevel`. The hook blocks if any of them has a staged secret, and the block message names each matching repo.

**Accepted tradeoff:** a secret staged in the session cwd repo now also blocks `cd <other repo> && git commit` (case b). Fail closed beats a bypass, so case (b) now expects BLOCK.

Base: `39440d9`. Earlier single-target versions on this branch: `48225c1`, `6218125`. Host: macOS, bash 5.3 (default `bash`), bash 3.2.57 (`/bin/bash`), BSD awk (default), mawk 1.3.4, gawk 5.4.1. The Ubuntu workflow matrix was not dispatched.

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
| `bash tests/ci-test.sh scan-commit-target-repo` | 0 | PASS, `Results: 28 passed, 0 failed` |
| `bash tests/ci-test.sh push-hook` | 0 | PASS, `Results: 13 passed, 0 failed` |
| `bash tests/ci-test.sh schema-remediation` | 0 | PASS, `Results: 4 passed, 0 failed` |
| `bash tests/ci-test.sh bip39-scan` | 0 | PASS, `Results: 16 passed, 0 failed` |
| `bash tests/ci-test.sh wallet-key-regex` | 0 | PASS, `Results: 9 passed, 0 failed` |
| `bash tests/ci-test.sh scan-secrets-hash-context` | 0 | PASS, `Results: 37 passed, 0 failed` |
| `scan-commit`, `scan-commit-cargo-lock`, `scan-commit-target-repo` with `bash` = `/bin/bash` 3.2.57 | 0 | PASS, 8 / 15 / 28 passed, 0 failed |
| same three with `awk` = mawk 1.3.4 and `bash` = 3.2.57 | 0 | PASS, 8 / 15 / 28 passed, 0 failed |
| same three with `awk` = gawk 5.4.1 and `bash` = 3.2.57 | 0 | PASS, 8 / 15 / 28 passed, 0 failed |

Total: 16 scenarios, 208 assertions, 0 failed.

New scenario output (fixed hook):

```text
  PASS: scan-commit hook is executable
  PASS: git -C <repoB> commit scans repoB (blocked) (2)
  PASS: git -C relative path resolves against cwd (blocked) (2)
  PASS: git -c k="v w" -C "<repoB>" commit (blocked) (2)
  PASS: git -C <repoB> commit-tree not intercepted (0)
  PASS: cd then relative -C composes (blocked) (2)
  PASS: "git commit" inside the message does not hide -C (blocked) (2)
  PASS: cd <repoB> && commit, no secret staged anywhere (allowed) (0)
  PASS: cd <repoB> && commit still blocks on the cwd repo's secret (fail closed) (2)
  PASS: cd <repoB> && commit scans repoB (blocked) (2)
  PASS: relative cd resolves against cwd (blocked) (2)
  PASS: cd ~/<path> expands to HOME (blocked) (2)
  PASS: last cd before the commit wins (blocked) (2)
  PASS: cd "<path with space>" (blocked) (2)
  PASS: git -C '<path with space>' (blocked) (2)
  PASS: decoy git -C <clean repo> commit before the real one (blocked) (2)
  PASS: second git -C commit in the command is scanned (blocked) (2)
  PASS: cd -P -- <repoB>: option words do not hide the target (blocked) (2)
  PASS: cd <path\ with\ escaped\ space> (blocked) (2)
  PASS: block message names repoB, not the clean cwd repo
  PASS: plain commit, clean cwd repo (allowed) (0)
  PASS: plain commit, secret in cwd repo (blocked) (2)
  PASS: missing cd target falls back to cwd (blocked) (2)
  PASS: variable cd target falls back to cwd (blocked) (2)
  PASS: non-repo cd target falls back to cwd (blocked) (2)
  PASS: cd inside quoted text falls back to cwd (blocked) (2)
  PASS: cd sub && cd .. returns to the cwd repo (blocked) (2)
  PASS: cd into a repo subdir scans that repo (blocked) (2)
Results: 28 passed, 0 failed
```

Large-input check under bash 3.2 and 5.3: a 100 KB `git -C "<100 KB path>" commit`, a 200 KB `echo "<100 KB>" && cd /tmp && git -c a=b commit -m "<100 KB>"`, 1,000 `cd /tmp;` before a commit, and 1,000 distinct `cd /tmp/dN;` before a relative `git -C sub commit` each finish in 3 s or less. Every regex loop consumes the text it matched, the sets dedupe as they grow, and path resolution sets a variable instead of forking.

## NEGATIVE CONTROL

Both hooks swapped for an earlier version with `git show <ref>:<path> >| <path>`, the new scenario rerun, then the fixed hooks restored (`cmp` equal to the saved copy) and rerun green. The runner prints an em dash before "expected"; it is shown here as a hyphen.

Control 1, base version.

Command:

```bash
git show 39440d9:full/scan-commit.sh >| full/scan-commit.sh
git show 39440d9:lite/scan-commit.sh >| lite/scan-commit.sh
bash tests/ci-test.sh scan-commit-target-repo
```

Exit: 1

Output:

```text
  FAIL: git -C <repoB> commit scans repoB (blocked) - expected '2', got '0'
  FAIL: git -C relative path resolves against cwd (blocked) - expected '2', got '0'
  FAIL: git -c k="v w" -C "<repoB>" commit (blocked) - expected '2', got '0'
  FAIL: cd then relative -C composes (blocked) - expected '2', got '0'
  FAIL: "git commit" inside the message does not hide -C (blocked) - expected '2', got '0'
  FAIL: cd <repoB> && commit scans repoB (blocked) - expected '2', got '0'
  FAIL: relative cd resolves against cwd (blocked) - expected '2', got '0'
  FAIL: cd ~/<path> expands to HOME (blocked) - expected '2', got '0'
  FAIL: last cd before the commit wins (blocked) - expected '2', got '0'
  FAIL: cd "<path with space>" (blocked) - expected '2', got '0'
  FAIL: git -C '<path with space>' (blocked) - expected '2', got '0'
  FAIL: decoy git -C <clean repo> commit before the real one (blocked) - expected '2', got '0'
  FAIL: second git -C commit in the command is scanned (blocked) - expected '2', got '0'
  FAIL: cd -P -- <repoB>: option words do not hide the target (blocked) - expected '2', got '0'
  FAIL: cd <path\ with\ escaped\ space> (blocked) - expected '2', got '0'
  FAIL: block message does not name repoB alone
Results: 12 passed, 16 failed
```

Verdict: the base hook lets every `git -C` and `cd && git commit` into repoB through with a staged secret (both reported failures). It passes the case (b) block only because it scans the cwd.

Control 2, last single-target version (`6218125`).

Command:

```bash
git show 6218125:full/scan-commit.sh >| full/scan-commit.sh
git show 6218125:lite/scan-commit.sh >| lite/scan-commit.sh
bash tests/ci-test.sh scan-commit-target-repo
```

Exit: 1

Output:

```text
  FAIL: cd <repoB> && commit still blocks on the cwd repo's secret (fail closed) - expected '2', got '0'
  FAIL: decoy git -C <clean repo> commit before the real one (blocked) - expected '2', got '0'
  FAIL: second git -C commit in the command is scanned (blocked) - expected '2', got '0'
  FAIL: cd -P -- <repoB>: option words do not hide the target (blocked) - expected '2', got '0'
  FAIL: cd <path\ with\ escaped\ space> (blocked) - expected '2', got '0'
  FAIL: block message does not name repoB alone
Results: 22 passed, 6 failed
```

Verdict: every bypass test named by the security review fails on the single-target version. The decoy commit and the second `-C` commit steer it to the clean repoC. The `cd -P --` and escaped-space forms make it misread the `cd` and fall back to the clean cwd. All of them exit 0 with a secret staged in repoB. The cwd-repo secret no longer blocks once it switches target.

After both controls: fixed hooks restored, `Results: 28 passed, 0 failed`, exit 0.

## Reproduce

```bash
bash tests/ci-test.sh scan-commit-target-repo
```

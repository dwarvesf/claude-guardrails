# SPEC: wallet-key + seedphrase detection (false-positive-safe)

Status: VALIDATED (empirical corpus + kit 5-lens spec-validate; 2 defects + 7 review findings resolved)
Date: 2026-06-05
Repo: claude-guardrails (source of truth) + port to deployed personal hooks
Owner: Han

Note: this spec embeds NO literal key material (the guardrail under design
blocks that, correctly). Concrete test vectors live in `tests/ci-test.sh`.

---

## 1. Problem

Claude Code guardrails block known credential shapes (AWS, GitHub, Anthropic,
PEM, 64-hex). They do **not** reliably block two crypto-secret classes:

1. **BIP-39 seed phrases** (12/24-word mnemonics). The only mnemonic-aware rule
   in `patterns/secrets.json` is the `(...|mnemonic|seed_phrase)\s*[=:]\s*"..."`
   assignment regex, whose value class `[A-Za-z0-9+/=_-]{16,}` excludes spaces.
   A real space-separated phrase never matches. A bare phrase has zero coverage.
2. **Non-hex wallet private keys**: Bitcoin WIF (Base58, leading `5`/`K`/`L`) and
   BIP-32 extended private keys (`xprv`/`yprv`/`zprv` + testnet variants). EVM
   64-hex keys are already caught incidentally by the hex-64 rule.

A correct, wordlist-based BIP-39 scanner **already exists** in this repo
(`full/scan-secrets.sh`, `lite/scan-secrets.sh`, `patterns/bip39-english.txt`)
and is exercised by `tests/ci-test.sh::test_bip39_scan`. The deployed personal
layer (`~/.claude/hooks/secret-guard/`) does **not** run it. So the gap is
(a) two missing key formats here, and (b) the seedphrase scanner not reaching
live sessions.

## 2. Goal / non-goals

**Goal**: every true wallet secret in the TP corpus (§6) is blocked, and **every**
item in the FP corpus (§7) passes clean, in both the product scanners and the
ported personal layer.

**Non-goals**:
- Solana / raw Base58 keys (no structural prefix; FP-prone). Explicitly out.
- Detecting wallets by file path beyond existing MetaMask/Electrum deny rules.
- Encrypted keystore JSON (already opaque; not a paste risk).
- Changing the BIP-39 consecutive-run algorithm. We extend its corpus, not relax it.

## 2a. Approaches considered

- **A. Loose word-run regex** (`([a-z]{3,8}\s+){11}...`, no wordlist). Rejected:
  catches any 12 short lowercase words -> high FP on prose. This was the original
  round-1 proposal; superseded by the existing wordlist approach.
- **B. Wordlist membership of every token in a 12+ whitespace run** (chosen).
  FP only on text that is itself mnemonic-shaped (R4). Already implemented and
  CI-tested in this repo; we extend its corpus rather than rebuild.
- **C. Entropy / checksum validation** (decode the 12 words, verify the BIP-39
  checksum). Lowest FP (rejects non-checksummed word runs) but needs a SHA-256
  decode step in bash/jq, far more complexity for a marginal FP reduction over B.
  Deferred; noted as a Phase-2 hardening if R4's accepted ambiguity ever bites.

## 3. Design

Two detection engines, unchanged in shape:

### 3a. Regex rules (added to `patterns/secrets.json`)

| Name | Regex (Oniguruma) | Why FP-safe |
|---|---|---|
| BIP-32 extended private key | `\b([xyz]prv\|[tuv]prv)[1-9A-HJ-NP-Za-km-z]{107,108}\b` | 4-char magic prefix (`xprv`/`yprv`/`zprv`/`tprv`/`uprv`/`vprv`) + fixed ~111-char Base58 length. Collision with non-key text ~0. |
| Bitcoin WIF private key | `\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\b` | Base58 alphabet (no `0OIl`), exact 51/52-char length, leading `5`/`K`/`L`. Loosest of the set -> largest FP corpus (§7). |

EVM 64-hex stays on the existing "Hex private key" rule (no change).

The mnemonic **assignment** regex is left as-is (still useful for
`mnemonic = "<single-token>"`); the wordlist engine below is the real
seedphrase catch.

### 3b. Wordlist engine (already present; extend coverage, do not weaken)

Keep the existing `scan-secrets.sh` BIP-39 algorithm verbatim:
run of **12+ consecutive** whitespace-separated tokens, each **3-8 lowercase
letters**, where **every** token is a wordlist member. Verified fact: all 2048
BIP-39 English words are length 3-8, so `{3,8}` is lossless and also drops short
prose words for free.

Two coverage extensions (additive, must not raise FP):
- **24-word**: current `{11,}` quantifier already covers 12 and 24. Add an
  explicit 24-word TP case so a regression that caps the run is caught.
- **Newline / multi-space wrapping**: `\s+` already spans newlines and runs of
  spaces. Add a TP case for the plain 4-per-line wallet grid (whitespace-only) to
  lock it. Numbered-list renderings are explicitly NOT covered in v1 (L1 / R5).

### 3c. Personal-layer port

The deployed `~/.claude/hooks/secret-guard/secret-guard.sh` consumes
`patterns/secrets.json` but runs no BIP-39 wordlist pass. Port plan:
1. Sync the two new regex rules into the personal `patterns/secrets.json`
   (chezmoi source `dot_claude/hooks/patterns/secrets.json`).
2. Wire a UserPromptSubmit (and Edit/Write payload) BIP-39 wordlist pass into the
   personal layer, reusing the exact jq filter from `scan-secrets.sh`. Ship
   `bip39-english.txt` alongside.
3. Re-run the FP corpus against the personal layer before committing the chezmoi
   change (anti-drift: source repo is truth, personal is derived).

## 4. Files touched

- `patterns/secrets.json` (2 new rules)
- `tests/ci-test.sh` (TP + FP corpus, §6/§7; new asserts in `test_bip39_scan`
  plus a new `test_wallet_key_regex`)
- `CHANGELOG.md` (entry)
- chezmoi `dot_claude/hooks/patterns/secrets.json` + personal BIP-39 wiring (port)

## 5. Acceptance criteria

1. Every TP item (§6) is blocked (exit 2) by the relevant engine.
2. **Every** FP item (§7) passes clean (exit 0). This is the gating criterion;
   one FP hit fails the spec.
3. `tests/ci-test.sh` (full + lite) green, including the new asserts.
4. Personal layer reproduces 1+2 after port; `git diff` of chezmoi source
   reviewed before commit.
5. No change to the BIP-39 consecutive-run algorithm or the `{3,8}` filter.

## 6. True-positive corpus (must ALL block), vectors generated in the test file

- T1 EVM key: canonical 64-hex with `0x` (already caught; regression guard).
- T2 EVM key: bare 64-hex, no `0x`.
- T3 WIF uncompressed: leading `5`, 51 chars (standard test vector).
- T4 WIF compressed: leading `K`/`L`, 52 chars.
- T5 xprv: mainnet BIP-32 extended private key, `xprv` + ~107 Base58 chars.
- T6 12-word mnemonic embedded in a sentence (all wordlist words, space-separated).
- T7 24-word mnemonic.
- T8 plain newline / 4-per-line wallet grid, whitespace-only separators (validated: blocks).

Test fixtures construct these programmatically (e.g. WIF/xprv from a throwaway
all-zero or documented BIP test seed) so no real wallet secret is committed.

**Known v1 limitation (NOT a TP, by decision)**:
- L1 numbered-list mnemonic (`1. word 2. word ...`). Validated: PASSES (not
  caught) because digit+dot enumerators break the consecutive whitespace run.
  A `\d+[.):]`-stripping normalization would close it but changes the algorithm
  and adds FP surface, so it is deferred to Phase 2 (see §9 R5). Han prioritised
  FP-safety over coverage for v1.

## 7. False-positive corpus (must ALL pass clean), the safety contract

Hash / SHA / id-shaped:
- F1 git long SHA-1 (40 hex). hex-64 rule must not catch 40-hex.
- F2 SHA-256 digest in prose (`sha256:<64hex>`). KNOWN: the hex-64 rule blocks
  64-hex by design. Documented existing behavior, not introduced here; corpus
  records it so the WIF/xprv additions are proven not to widen it.
- F3 UUID v4.
- F4 base64 blob (44 char, `==` padded).

Base58 non-keys (guard the WIF/xprv additions):
- F5 IPFS CIDv0 `Qm...` (46 char), leading `Q`, must not hit WIF.
- F6 P2PKH address (leading `1`, ~34 char), must not hit WIF.
- F7 Solana address (32-44 Base58), explicitly out of scope, must pass.
- F8 a 51-char Base58 string NOT starting with `5`/`K`/`L`.
- F9 `xpub...` extended PUBLIC key, must NOT hit the xprv rule.

Prose that tokenises to wordlist words (guard the BIP-39 engine):
- F10 punctuation-separated wordlist words (the real CI form): "question, what,
  else, you, need, feel, that, ready, then, okay, that, ready". Validated: PASSES.
  NOTE (validated, accepted ambiguity): the SPACE-separated form of the same
  words DOES block (exit 2), because 12+ consecutive whitespace-separated BIP-39
  words are structurally identical to a real mnemonic. That is not a fixable FP;
  it is the irreducible cost of mnemonic detection. See §9 R4.
- F11 12+ common English words separated by commas/punctuation (broken run).
- F12 a paragraph mixing wordlist + non-wordlist words (run never reaches 12).
- F13 a list of 12 wordlist words with one 9-letter or one 2-letter word in the
  middle (breaks the `{3,8}` consecutive run).
- F14 code identifiers joined by underscores, not whitespace (no run).

## 8. Test plan (coverage matrix)

| Category | Cases | Engine | Assert |
|---|---|---|---|
| EVM hex | T1,T2 / F1,F2 | regex | block / (F1 pass, F2 documented-block) |
| WIF | T3,T4 / F5,F6,F8 | regex | block / pass |
| xprv | T5 / F9 | regex | block / pass |
| Mnemonic | T6,T7,T8 / F10,F11,F12,F13,F14 | wordlist | block / pass |
| Known gap | L1 (numbered list) | wordlist | documented PASS (v1 limitation) |
| Out-of-scope | (none) / F3,F4,F7 | both | pass |

Each row is a CI assert. The spec is DONE only when the FP column is 100% pass.
All §6/§7 cases above were validated empirically against the real
`full/scan-secrets.sh` and the proposed jq regexes before this spec left Draft.

## 9. Risks

- **R1 WIF leading-char breadth**: `5/K/L` + 51 Base58 chars could in theory hit a
  non-key Base58 blob of that exact length. Mitigation: exact length bound
  (50-51 after lead) + FP corpus F5/F6/F8. If a real FP appears post-ship, gate
  WIF behind a context word (`priv`, `wif`, `key`) rather than widening.
- **R2 F2 hex-64 over-block**: pre-existing; not introduced. Flag to Han that
  SHA-256 digests in prompts already trip the hex rule (acceptable: rare in
  Han's flows, and the block message tells him to rephrase).
- **R3 port drift**: personal layer diverges from product. Mitigation: AC#4
  re-runs the corpus against the personal layer; chezmoi source is the only
  edit point.
- **R4 accepted ambiguity (validated)**: 12+ consecutive whitespace-separated
  BIP-39 words always block, even in legitimate prose, because they are
  indistinguishable from a mnemonic. This is irreducible for any wordlist
  detector. Cost is low: such prose is rare, and the block message tells the
  user to rephrase. We do NOT widen the run threshold below 12 to reduce it
  (would raise FP) nor above (would miss real 12-word phrases). Threshold 12 is
  the floor of a valid BIP-39 mnemonic, so it is correct by construction.
- **R5 numbered-list false negative (Phase 2)**: `1. word 2. word` mnemonics are
  not caught (L1). Closing it needs an enumerator-stripping normalization that
  changes the algorithm and adds FP surface; out of v1 scope. Tracked as a
  follow-up, not a v1 blocker.
- **R6 silent fail-open if wordlist missing (Failure Mode)**: `scan-secrets.sh`
  exits 0 (no seedphrase detection) when `bip39-english.txt` is absent. A partial
  install therefore disables mnemonic catching silently. Mitigation: `install.sh`
  already copies the wordlist; ADD a CI assert (`assert_file_exists` already
  exists at line 587) and a one-line stderr warning on missing wordlist (the
  script already emits one for a missing patterns file; mirror it for the
  wordlist). The port (§3c) must ship the wordlist in the same commit as the
  wiring, never wiring-first.
- **R7 ReDoS / large-prompt cost (Failure Mode)**: the `(?:\b[a-z]{3,8}\b\s+){11,}`
  quantified scan can backtrack on a pathological multi-KB prompt of short words.
  Mitigation: Oniguruma `scan` is non-backtracking for this shape in practice, but
  add a perf guard test (a 10k-word input must return in <1s) and, if it regresses,
  cap the scanned prompt to the first N KB (mnemonics are short; truncation does
  not lose real secrets at the head).
- **R8 narrow key-format scope (Assumption Destroyer)**: the WIF rule covers only
  Bitcoin MAINNET WIF (`5/K/L`). Testnet WIF (`9/c`), altcoin WIF, and mnemonics
  whose words are separated by non-breaking spaces / Unicode spaces (jq `\s` is
  ASCII) are OUT of v1 scope by decision (low real-paste likelihood; testnet keys
  are worthless). Stated so the gap is intentional, not forgotten.
- **R9 triplicated BIP-39 filter (Design Critic)**: the jq filter exists in
  `full/scan-secrets.sh` and `lite/scan-secrets.sh` and will be copied into the
  personal layer (3 copies). Algorithm changes then need 3 edits. Mitigation
  (Phase 2, non-blocking): extract the filter to `patterns/bip39-scan.jq` sourced
  by all three. v1 keeps the copies to stay surgical; R9 tracks the debt.

## 10. Failure modes

| Class | Detection signal | Mitigation |
|---|---|---|
| Wordlist file missing | CI `assert_file_exists`; runtime stderr warning | Ship wordlist in install + port commit; fail-open is logged, not silent (R6) |
| Malformed prompt JSON | `jq -e .` guard | Fail-open by design (never block legit work) |
| Large/adversarial prompt | perf guard test <1s on 10k words | Truncate scanned prefix if regressed (R7) |
| Personal-layer port drift | AC#4 re-runs corpus on personal layer | chezmoi source is the single edit point (R3) |
| New FP class found post-ship | user report / a blocked legit prompt | WIF context-gate (R1); wordlist checksum approach C (R4) |

## 11. Tasks

Atomic, each <5 files. Task 3 depends on Task 1 (rules must be final before port).

### Task 1: add WIF + xprv regex rules + regex tests
- Files: `patterns/secrets.json`, `tests/ci-test.sh`.
- Add the two rules from §3a to `patterns/secrets.json`.
- Add `test_wallet_key_regex()`: asserts T3,T4,T5 BLOCK and F5,F6,F8,F9 PASS,
  driving the patterns through the same jq `test()` the hooks use. Build WIF/xprv
  vectors from the documented all-zero BIP test seed (no real secret).
- Acceptance: new test green in both full + lite; existing tests still green.

### Task 2: lock BIP-39 corpus (regression + coverage)
- Files: `tests/ci-test.sh` only.
- Extend `test_bip39_scan`: add T7 (24-word), T8 (4-per-line whitespace grid)
  -> BLOCK; add F10-corrected, F12, F13, F14 -> PASS; add an L1 numbered-list
  case asserting documented PASS so the v1 limitation is pinned (a future Phase-2
  fix flips it to BLOCK and updates this assert deliberately).
- Add R7 perf guard: 10k-word input returns in <1s.
- Acceptance: all asserts green; no change to the engine itself (AC#5).

### Task 3: port to deployed personal layer (riskier, gated on Task 1)
- Files: chezmoi `dot_claude/hooks/patterns/secrets.json`, the personal BIP-39
  wiring + `dot_claude/hooks/patterns/bip39-english.txt`.
- Merge the 2 regex rules into the (diverged) personal `secrets.json` additively.
- Wire the verbatim BIP-39 jq pass into the personal layer's UserPromptSubmit and
  Edit/Write payload path; ship the wordlist in the SAME commit (R6).
- Acceptance: run the §6/§7 corpus against the personal layer (AC#4); `git diff`
  of chezmoi source reviewed before commit; live `secret-guard.sh` blocks a
  test mnemonic write and passes the F-corpus.

## 12. Decision Log

- 2026-06-05 Scope = BIP-39 + EVM hex + WIF + xprv; Solana/testnet/Unicode-space
  excluded (R8). Target = product source-of-truth + personal port (§3c).
- 2026-06-05 Validation found 2 defects: F10 was a spec error (space-separated
  wordlist run blocks by design, R4); numbered-list is a real gap (L1/R5).
- 2026-06-05 Spec-validate (5-lens) added: Approaches considered (§2a), Failure
  modes (§10), R6-R9, and Task decomposition (§11). Marked VALIDATED.

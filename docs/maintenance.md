# Maintenance Checklist

Quarterly review process to keep guardrails current. Run through this checklist every ~3 months or when a major Claude Code release ships.

## Upstream Sources to Watch

| Source | What to look for | Link |
|---|---|---|
| Claude Code changelog | Hook API changes, settings.json schema, new tool types | https://docs.anthropic.com/en/docs/claude-code/changelog |
| Claude Code GitHub | New releases, breaking changes, security advisories | https://github.com/anthropics/claude-code |
| Trail of Bits blog | New AI agent attack research, Claude-specific findings | https://blog.trailofbits.com/ |
| Lasso Security | AI tool exploitation techniques, prompt injection research | https://www.lasso.security/blog |
| Anthropic security docs | Updated best practices, new permission model changes | https://docs.anthropic.com/en/docs/claude-code/security |
| Snyk / CVE databases | Claude Code CVEs (e.g., CVE-2025-59536) | https://security.snyk.io/ |
| GitHub Advisory DB | New advisories for `@anthropic-ai/*` packages | https://github.com/advisories |

## Quarterly Review Checklist

### 1. Claude Code compatibility
- [ ] Check current Claude Code version (`claude --version`)
- [ ] Review changelog since last review for breaking changes
- [ ] Verify `settings.json` schema hasn't changed (check `$schema` URL)
- [ ] Verify hook API contract (PreToolUse/PostToolUse input format) is unchanged
- [ ] Run full CI test suite against latest Claude Code

### 2. Deny rules
- [ ] Review deny rule globs against current credential/secret file conventions
- [ ] Check for new credential types not covered (cloud providers, CI tokens, etc.)
- [ ] Review false positive reports (if any) and adjust patterns
- [ ] Verify glob counts: lite=15, full=28 (or update docs if changed)

### 3. PreToolUse hook patterns
- [ ] Review destructive delete patterns — any new dangerous commands?
- [ ] Review direct push patterns — any new protected branch conventions?
- [ ] Review pipe-to-shell patterns — any new download-and-execute vectors?
- [ ] (Full only) Review exfiltration patterns — any new data exfil services?
- [ ] (Full only) Review permission escalation patterns — any new bypass techniques?
- [ ] Check upstream research for new attack patterns to add

### 4. scan-secrets UserPromptSubmit hook (both variants)
- [ ] Review credential regex list against current issuer formats (AWS, GitHub, Anthropic, OpenAI, Google, Slack, Stripe, 1Password)
- [ ] Check for new token prefixes or length changes (e.g. GitHub's token format has evolved; Anthropic and OpenAI both changed theirs historically)
- [ ] Add patterns for new issuers your team depends on (Linear, Vercel, Supabase, etc.)
- [ ] Review false positive reports — 64-hex rule intentionally catches SHA-256 digests; confirm this tradeoff still holds
- [ ] Test with known-good and known-bad paste samples

### 5. Prompt injection defender (full only)
- [ ] Review injection signature regexes against latest research
- [ ] Check for new injection techniques not covered
- [ ] Review false positive rate — are legitimate files triggering warnings?
- [ ] Test defender against known-good and known-bad samples

### 6. Documentation sync
- [ ] Verify README.md matches current behavior
- [ ] Verify full/SETUP.md matches current behavior
- [ ] Verify CLAUDE.md matches current architecture
- [ ] Update version references if bumped
- [ ] Update "Based on" references if new research sources added

### 7. Dependencies & distribution
- [ ] Run `npm audit` on package.json (should stay zero-dep)
- [ ] Verify `npx claude-guardrails install` works on fresh machine
- [ ] Verify `jq` version compatibility (test on latest macOS + Ubuntu LTS) — `scan-secrets.sh` depends on Oniguruma regex support in jq
- [ ] Check if npm package needs version bump

## Review Log

Record completed reviews here for audit trail.

| Date | Reviewer | Claude Code version | Changes made | Notes |
|---|---|---|---|---|
| _yyyy-mm-dd_ | _name_ | _x.y.z_ | _link to PR/commit_ | _any observations_ |

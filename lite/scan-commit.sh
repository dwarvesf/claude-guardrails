#!/usr/bin/env bash
# scan-commit.sh — Claude Code PreToolUse hook (matcher: Bash).
#
# Fires when Claude runs a Bash command. If the command is `git commit`,
# scans the staged diff for secret patterns (shared with scan-secrets.sh)
# and blocks (exit 2) on match. For all other commands, exits 0.
#
# This closes the gap left by scan-secrets.sh: the prompt-submit scanner
# only catches pasted credentials; this hook catches secrets that Claude
# writes into code and then tries to commit.
#
# Fail closed on the target repo: the hook does not guess which repo the
# commit lands in. It scans the payload cwd (always) plus every repo named by
# any `cd` or `git -C` in the command, and blocks if any of them has a staged
# secret. A regex cannot parse shell exactly, so picking one target would let a
# crafted command steer the scan away from the repo that holds the secret.
# A script file the command runs is read too (never run): its `git commit`
# makes the command a commit, and its `cd` / `git -C` targets are scanned.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="${CLAUDE_GUARDRAILS_PATTERNS:-$SCRIPT_DIR/../patterns/secrets.json}"

INPUT="$(cat)"

# Fail-open on malformed JSON.
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"

# A shell word: one or more double-quoted, single-quoted, backslash-escaped, or
# bare segments (so `-c user.name="A B"`, `"/path with space"` and
# `/path\ with\ space` are each one word).
WORD="((\"[^\"]*\"|'[^']*'|\\\\.|[^[:space:]\"'\\\\;&|)])+)"

# Only act on `git commit` (leave git commit-tree, commit-graph plumbing alone).
# The word boundary after `commit` prevents matching `git commit-tree`, and the
# required whitespace before handles chained commands (`... && git commit ...`).
# Global `-C <dir>` / `-c <k=v>` options may sit between `git` and `commit`.
COMMIT_RE="(^|[^a-zA-Z0-9_-])git([[:space:]]+-[Cc][[:space:]]+$WORD)*[[:space:]]+commit([[:space:]]|\$)"

# Claude Code passes cwd at the top level of the hook payload.
CWD="$(echo "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty')"
if [[ -n "$CWD" && -d "$CWD" ]]; then
  cd "$CWD" || exit 0
fi

# Resolve a shell word ($1) to a path against base dir $2, into RESOLVED:
# expand a leading unquoted `~`, drop quote and escape characters, prefix
# relative paths. Sets a variable instead of printing to avoid a fork per call.
resolve_dir() {
  local d="$1"
  case "$d" in
    "~") d="$HOME" ;;
    "~/"*) d="$HOME/${d#\~/}" ;;
  esac
  d="${d//\"/}"
  d="${d//\'/}"
  d="${d//\\/}"
  case "$d" in
    /*) RESOLVED="$d" ;;
    *) RESOLVED="$2/$d" ;;
  esac
}

# Newline-separated sets. CANDS: directories that may hold the commit's repo.
# BASES: directories a relative `-C` may resolve against.
NL=$'\n'
CANDS="$PWD"
BASES="$PWD"
# Add $2 to the set named $1 unless already present; return 1 if present.
add_to() {
  local current="${!1}"
  case "$NL$current$NL" in
    *"$NL$2$NL"*) return 1 ;;
  esac
  printf -v "$1" '%s%s%s' "$current" "$NL" "$2"
}

# Work cap. A timed-out hook lets the commit through, so a command that names
# more than MAX_SCAN of anything is blocked before any per-candidate git call.
# The cap also keeps the string-set dedupe and the parse loops cheap.
MAX_SCAN=32
CD_COUNT=0
CD_WORDS=0
COMMIT_COUNT=0
OPT_WORDS=0
CAND_COUNT=0
too_many() {
  {
    echo ""
    echo "==================== COMMIT BLOCKED: TOO MANY DIRECTORIES TO SCAN ===================="
    echo ""
    echo "The command names too many directories to scan for staged secrets"
    echo "within the hook's time limit (more than $MAX_SCAN $1)."
    echo ""
    echo "The commit was NOT created."
    echo ""
    echo "To resolve: run the commit from inside the repo, as a short command"
    echo "of its own (cd <repo>, then git commit)."
    echo ""
    echo "======================================================================================="
  } >&2
  exit 2
}
# Increment the counter named $1; block when it passes MAX_SCAN ($2 names it).
bump() {
  printf -v "$1" '%s' "$(( ${!1} + 1 ))"
  if [[ ${!1} -gt $MAX_SCAN ]]; then
    too_many "$2"
  fi
}
add_cand() {
  if add_to CANDS "$1"; then
    bump CAND_COUNT "candidate directories"
  fi
}

# Script files: a commit can run inside a script the command runs. LEX is a
# shell lexer in awk, linear in its input (quotes, escapes, comments, $(...),
# backquotes, separators, redirections, heredocs). mode=cmd prints
# `R kind dir word` per script run: kind S is the first non-option argument of
# bash/sh/zsh/dash/ksh (none with -c or -s), source or `.`; kind X a command
# given by path; dir is where earlier cds lead. mode=script lexes all scripts
# in one pass, printing `T dir` per cd / git -C target and `G` for a commit.
# A cd, -C or script word over cap prints LONG; over tcap refs or targets,
# MANY. Command heredoc bodies are skipped (COMMIT_RE still reads them).
# Scripts run by scripts are not followed.
SCRIPT_MAX_FILES=64
SCRIPT_MAX_BYTES=2097152
LINE_MAX=4096
read -r -d '' LEX <<'AWK' || true
function out(line) {
  if (line in seen) return
  seen[line] = 1
  if (++count > tcap) { print "MANY"; exit }
  print line
}
function compose(b, x) { return (x ~ /^[\/~]/ || b == "") ? x : b "/" x }
function long() { if (big) { print "LONG"; exit } }
function ref(kind, v) { long(); if (mode == "cmd") out("R\t" kind "\t" (cur == "" ? "." : cur) "\t" v) }
function target(p) { if (mode == "script" && length(p) <= cap) out("T\t" p) }
function sep() { word_end(i); cmd = 1; st = ""; skip = 0; wrap = 0 }
function word_end(e,   w) {
  if (!inw) return
  inw = 0
  if (length(raw) <= cap) raw = raw substr(L, ws, e - ws)
  w = raw; raw = ""; big = length(w) > cap
  gsub(/["'\\]/, "", w)
  word(w)
}
function push(t) {
  sraw[++depth] = (inw ? raw substr(L, ws, i - ws) : "") "$"
  stype[depth] = t; sst[depth] = st; scmd[depth] = cmd; sdq[depth] = dq
  inw = 0; raw = ""; dq = 0; cmd = 1; st = ""
}
function pop() {
  word_end(i)
  raw = sraw[depth]; st = sst[depth]; cmd = scmd[depth]; dq = sdq[depth]
  depth--; inw = 1; ws = i + 1
}
function word(v,   b, k, pp) {
  if (hdnext) { hdnext = 0; hdp = v; sub(/^-/, "", hdp); return }
  if (skip) { skip = 0; return }
  if (cmd) {
    b = v; if (index(v, "/")) { k = split(v, pp, "/"); b = pp[k] }
    if (v ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    if (b ~ /^(sudo|env|exec|nohup|time|timeout|command|builtin|nice|xargs|then|do|else|elif|if|while|until|!|\{|\})$/) { wrap = 1; return }
    if (wrap && v ~ /^[-0-9]/) return
    cmd = 0; wrap = 0
    if (b ~ /^(ba|z|da|k)?sh$/) { st = "sh"; dd = 0 }
    else if (v == "source" || v == ".") st = "src"
    else if (v == "cd") { st = "cd"; cdb = cur }
    else if (v == "git") { st = "git"; gb = cur; gn = 0; gC = 0; gc = 0 }
    else { st = ""; if (index(v, "/")) ref("X", v) }
    return
  }
  if (st == "sh") {
    if (!dd && v == "--") { dd = 1; return }
    if (!dd && v ~ /^[-+]/) {
      if (v ~ /^[-+][oO]$/ || v == "--rcfile" || v == "--init-file") skip = 1
      else if (v ~ /^-[a-zA-Z]*[cs]/) st = ""
      return
    }
    ref("S", v); st = ""
  } else if (st == "src") {
    ref("S", v); st = ""
  } else if (st == "cd") {
    if (v !~ /^-/) { long(); target(v); cur = compose(cdb, v); target(cur) }
  } else if (st == "git") {
    if (gC) { gC = 0; long(); target(v); gb = compose(gb, v); gt[++gn] = gb; return }
    if (gc) { gc = 0; return }
    if (v == "-C") { gC = 1; return }
    if (v == "-c") { gc = 1; return }
    if (v ~ /^-/) return
    if (v == "commit") { commit = 1; for (k = 1; k <= gn; k++) target(gt[k]) }
    st = ""
  }
}
FNR == 1 {
  cur = ""; dq = 0; sq = 0; depth = 0; inw = 0; raw = ""; hd = ""; hdp = ""
  hdnext = 0; cmd = 1; st = ""; skip = 0; wrap = 0
}
{
  i = 1; cont = 0; body = 0; total = length($0)
  if (hd != "") {
    t = $0; sub(/^\t+/, "", t)
    if (t == hd) { hd = ""; next }
    if (mode == "cmd") next
    body = 1
  }
  # Lex the line in chunks of cap characters: awk's substr costs the length
  # of its string, so per-character substr on a whole long line is quadratic.
  for (off = 1; off == 1 || off <= total; off += cap) {
  L = substr($0, off, cap); n = length(L)
  if (inw) ws = 1
  while (i <= n) {
    c = substr(L, i, 1)
    if (sq) {
      if (c == "'") { sq = 0; i++ }
      else if (match(substr(L, i, 64), /^[^']+/)) i += RLENGTH
      continue
    }
    if (dq) {
      if (c == "\"") dq = 0
      else if (c == "\\") i++
      else if (c == "$" && substr(L, i + 1, 1) == "(") { push("p"); i++ }
      else if (c == "`") { if (depth && stype[depth] == "b") pop(); else push("b") }
      else if (match(substr(L, i, 64), /^[^"\\$`]+/)) { i += RLENGTH; continue }
      i++; continue
    }
    if (c == " " || c == "\t") { word_end(i); i++; continue }
    if (!inw && c == "#") break
    if (c == "&" && substr(L, i + 1, 1) == ">") { word_end(i); skip = 1; i += 2; continue }
    if (c == ";" || c == "&" || c == "|" || c == "(") { sep(); i++; continue }
    if (c == ")") { if (depth && stype[depth] == "p") pop(); else sep(); i++; continue }
    if (c == "<" || c == ">") {
      word_end(i)
      if (c substr(L, i + 1, 1) substr(L, i + 2, 1) == "<<<") { skip = 1; i += 3; continue }
      if (c substr(L, i + 1, 1) == "<<") { hdnext = 1; i += 2; continue }
      skip = 1; i++
      if (substr(L, i, 1) ~ /[>&|]/) i++
      continue
    }
    if (c == "`") { if (depth && stype[depth] == "b") pop(); else push("b"); i++; continue }
    if (!inw) { inw = 1; ws = i; raw = "" }
    if (c == "\\") { if (off + i - 1 == total) cont = 1; i += 2; continue }
    if (c == "'") sq = 1
    else if (c == "\"") dq = 1
    else if (c == "$" && substr(L, i + 1, 1) == "(") { push("p"); i++ }
    else if (match(substr(L, i, 64), /^[^ \t;&|()<>"'\\`$#]+/)) { i += RLENGTH; continue }
    i++
  }
  if (off + n <= total && inw && length(raw) <= cap) raw = raw substr(L, ws)
  i -= n
  }
  i = n + 1
  if (body) { sq = 0; dq = 0 }
  if (sq || dq) {
    if (inw && length(raw) <= cap) raw = raw substr(L, ws) "\n"
  } else if (cont) {
    if (inw && length(raw) <= cap) raw = raw substr(L, ws, n - ws)
  } else sep()
  if (hdp != "") { hd = hdp; hdp = "" }
}
END { if (commit) print "G" }
AWK
lex() {
  LC_ALL=C awk -v mode="$1" -v cap="$LINE_MAX" -v tcap="$SCRIPT_MAX_FILES" "$LEX" "${@:2}"
}

# Block a command whose scripts cannot be read in full and in time ($1 says
# why): a partial or timed-out read would let a commit through unscanned.
block_script() {
  {
    echo ""
    echo "============ COMMAND BLOCKED: SCRIPT CANNOT BE SCANNED ============"
    echo "The commit secret scan cannot read a script this command runs: $1."
    echo "The command was NOT run. Run scripts by a literal path to a file"
    echo "that already exists (create it in an earlier command), keep them"
    echo "under $SCRIPT_MAX_FILES files and 2 MiB, or commit in a command of its own."
    echo "==================================================================="
  } >&2
  exit 2
}
check_lex() {
  case "$NL$1$NL" in
    *"${NL}LONG${NL}"*) block_script "a path or cd / -C target is over $LINE_MAX characters" ;;
    *"${NL}MANY${NL}"*) block_script "more than $SCRIPT_MAX_FILES script files or targets" ;;
  esac
}

# Resolve each script against the directory earlier cds lead to and the cwd.
# An S word must be a readable file; an X word counts when it is an
# executable text file (no NUL in its first 8 KiB).
SCRIPT_FILES=()
SCRIPTS=""
STARTS="$PWD"
REFS="$(printf '%s\n' "$CMD" | lex cmd)"
check_lex "$REFS"
while IFS=$'\t' read -r tag kind from word; do
  [[ $tag == R ]] || continue
  case "$word" in
    '$HOME/'*) word="$HOME/${word#\$HOME/}" ;;
    '${HOME}/'*) word="$HOME/${word#\$\{HOME\}/}" ;;
  esac
  start="$PWD"
  [[ $from == . ]] || { resolve_dir "$from" "$PWD"; start="$RESOLVED"; }
  found=0
  for dir in "$start" "$PWD"; do
    resolve_dir "$word" "$dir"
    file="$RESOLVED"
    [[ -f $file && -r $file ]] || continue
    if [[ $kind == X ]]; then
      [[ -x $file ]] && head -c 8192 "$file" | LC_ALL=C grep -Iq '' || continue
    fi
    found=1
    add_to SCRIPTS "$file" && SCRIPT_FILES[${#SCRIPT_FILES[@]}]="$file"
    add_to STARTS "$start"
  done
  if [[ $kind == S && $found == 0 ]]; then
    block_script "\`$word\` is missing, unreadable, or not a literal path"
  fi
done <<< "$REFS"

# Read every script in one lexer pass, after one size check.
SCRIPT_TARGETS=""
SCRIPT_COMMIT=0
if [[ ${#SCRIPT_FILES[@]} -gt 0 ]]; then
  if [[ ${#SCRIPT_FILES[@]} -gt $SCRIPT_MAX_FILES ]]; then
    block_script "more than $SCRIPT_MAX_FILES script files"
  fi
  BYTES="$(wc -c "${SCRIPT_FILES[@]}" 2>/dev/null \
    | awk -v n="${#SCRIPT_FILES[@]}" 'NR <= n { s += $1 } END { print s + 0 }')"
  if [[ $BYTES -gt $SCRIPT_MAX_BYTES ]]; then
    block_script "the scripts hold $BYTES bytes, over the 2 MiB limit"
  fi
  SCRIPT_TARGETS="$(lex script "${SCRIPT_FILES[@]}")"
  check_lex "$SCRIPT_TARGETS"
  [[ "$NL$SCRIPT_TARGETS$NL" == *"${NL}G${NL}"* ]] && SCRIPT_COMMIT=1
fi

# Only act on a commit, in the command or in a script it runs.
if ! [[ $CMD =~ $COMMIT_RE ]] && [[ $SCRIPT_COMMIT == 0 ]]; then
  exit 0
fi

# Every `cd` in the command, each argument word resolved two ways: against the
# directory the previous `cd`s led to (bash's view), and raw against the
# payload cwd (in case the compose misreads the shell). Option words such as
# `-P` or `--` become non-directory candidates and drop out below. Each loop
# consumes the matched text, so the walk is linear in the command length.
CUR="$PWD"
REST="$CMD"
CD_RE="(^|[^a-zA-Z0-9_./-])cd([[:blank:]].*)"
ARG_RE="^[[:blank:]]+$WORD"
while [[ $REST =~ $CD_RE ]]; do
  bump CD_COUNT "cd commands"
  ARGS="${BASH_REMATCH[2]}"
  LAST_WORD=""
  while [[ $ARGS =~ $ARG_RE ]]; do
    bump CD_WORDS "cd arguments"
    LAST_WORD="${BASH_REMATCH[1]}"
    ARGS="${ARGS:${#BASH_REMATCH[0]}}"
    resolve_dir "$LAST_WORD" "$PWD"
    add_cand "$RESOLVED"
    add_to BASES "$RESOLVED"
    resolve_dir "$LAST_WORD" "$CUR"
    add_cand "$RESOLVED"
    add_to BASES "$RESOLVED"
  done
  if [[ -n "$LAST_WORD" ]]; then
    resolve_dir "$LAST_WORD" "$CUR"
    CUR="$RESOLVED"
  fi
  REST="$ARGS"
done

# The scripts' cd and git -C targets, each resolved against the cwd and every
# directory a script runs from. Only directories that exist are candidates.
while IFS=$'\t' read -r tag path; do
  [[ $tag == T ]] || continue
  while IFS= read -r dir; do
    resolve_dir "$path" "$dir"
    if [[ -d $RESOLVED ]]; then
      add_cand "$RESOLVED"
    fi
  done <<< "$STARTS"
done <<< "$SCRIPT_TARGETS"

# Every `git ... commit` occurrence, not just the first, so a decoy commit
# cannot hide the real one. Each `-C` resolves against every base (chained
# within one invocation, as git does) and raw against the payload cwd.
REST="$CMD"
FIND_RE="$COMMIT_RE(.*)"
OPT_RE="^[[:space:]]+-([Cc])[[:space:]]+$WORD"
while [[ $REST =~ $FIND_RE ]]; do
  bump COMMIT_COUNT "git commit occurrences"
  NEXT="${BASH_REMATCH[$(( ${#BASH_REMATCH[@]} - 1 ))]}"
  OPTS="${BASH_REMATCH[0]#*git}"
  DIRS="$BASES"
  while [[ $OPTS =~ $OPT_RE ]]; do
    bump OPT_WORDS "git -C / -c options"
    OPTS="${OPTS:${#BASH_REMATCH[0]}}"
    if [[ "${BASH_REMATCH[1]}" == "C" ]]; then
      OPT_WORD="${BASH_REMATCH[2]}"
      NEW_DIRS=""
      while IFS= read -r base; do
        resolve_dir "$OPT_WORD" "$base"
        add_cand "$RESOLVED"
        NEW_DIRS="$NEW_DIRS$NL$RESOLVED"
      done <<< "$DIRS"
      resolve_dir "$OPT_WORD" "$PWD"
      add_cand "$RESOLVED"
      DIRS="${NEW_DIRS#"$NL"}$NL$RESOLVED"
    fi
  done
  REST="$NEXT"
done

# Keep candidates that are inside a git work tree, deduped by top level.
REPOS=""
while IFS= read -r dir; do
  [[ -n "$dir" && -d "$dir" ]] || continue
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || continue
  [[ -n "$top" ]] || continue
  add_to REPOS "$top"
done <<< "$CANDS"
REPOS="${REPOS#"$NL"}"

# If no candidate is a git repo, let git itself produce the error.
if [[ -z "$REPOS" ]]; then
  exit 0
fi

# Print the names of patterns matched by the staged diff of repo $1.
scan_repo() {
  local repo="$1" diff added
  # Scan only staged changes, not the entire file. This avoids re-flagging
  # secrets that were already committed before the hook existed, and keeps
  # the scan bounded to what's about to be recorded.
  diff="$(git -C "$repo" diff --cached --unified=0 --no-color 2>/dev/null || true)"
  if [[ -z "$diff" ]]; then
    return 0
  fi

  # Extract only the added-line content (lines starting with "+"), skipping
  # the "+++" file-header lines that otherwise leak path strings into the scan.
  #
  # One narrow exemption: Cargo.lock lists a SHA-256 `checksum = "<64 hex>"` per
  # crate, which the 64-hex rule would otherwise block on every lockfile change.
  # A line is dropped only when BOTH hold: the file's basename is exactly
  # `Cargo.lock` (taken from the `+++` header, honoured only between a
  # `diff --git` line and its first `@@` so an added content line can never spoof
  # it), AND the line matches exactly `^checksum = "[0-9a-f]{64}"$`. Everything
  # else, including every other Cargo.lock line, is scanned as before. The 64-char
  # check uses length() (12-char prefix + 64 + closing quote = 77) because mawk
  # builds without regex intervals would not honour `{64}`.
  added="$(echo "$diff" | awk '
    /^diff --git / { hdr = 1; cargo = 0; next }
    /^@@/          { hdr = 0 }
    /^\+\+\+ /     {
      if (hdr) {
        path = substr($0, 5)
        sub(/\t.*$/, "", path)
        gsub(/"/, "", path)
        n = split(path, parts, "/")
        cargo = (parts[n] == "Cargo.lock")
      }
      next
    }
    /^\+/ {
      line = substr($0, 2)
      if (cargo && length(line) == 77 && line ~ /^checksum = "[0-9a-f]+"$/) next
      print line
    }
  ')"

  if [[ -z "$added" ]]; then
    return 0
  fi

  if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "scan-commit: patterns file not found at $PATTERNS_FILE (skipping scan)" >&2
    exit 0
  fi

  jq -Rsr --slurpfile pats "$PATTERNS_FILE" '
    . as $text |
    $pats[0]
    | map(select(.r as $r | $text | test($r)))
    | map(.n) | .[]
  ' <<< "$added"
}

# Note: the BIP39 wordlist check lives only in scan-secrets.sh (the prompt
# scanner), not here. Running it on committed code produces too many false
# positives on legitimate content - documentation, comments, BIP39 test
# fixtures, and the wordlist file itself. The labeled-secret regex in
# patterns/secrets.json already catches `mnemonic: "..."` / `seed_phrase: "..."`
# assignments, which is the realistic commit-time leak path.

REPORT=""
while IFS= read -r repo; do
  HITS="$(scan_repo "$repo")"
  if [[ -z "$HITS" ]]; then
    continue
  fi
  # Show which staged files contain changes so the user knows where to look.
  FILES="$(git -C "$repo" diff --cached --name-only 2>/dev/null | head -10)"
  REPORT="$REPORT${NL}Repository: $repo${NL}  Matched pattern(s):${NL}$(echo "$HITS" | sed 's/^/    - /')${NL}  Files with staged changes:${NL}$(echo "$FILES" | sed 's/^/    /')${NL}"
done <<< "$REPOS"

if [[ -z "$REPORT" ]]; then
  exit 0
fi

{
  echo ""
  echo "==================== SECRET DETECTED — COMMIT BLOCKED ===================="
  echo ""
  echo "Staged changes matched secret pattern(s) in the repo(s) below. The hook"
  echo "scans the session cwd and every repo the command, or a script file it"
  echo "runs, names with cd or -C, so a secret staged in any of them blocks"
  echo "this commit."
  echo "$REPORT"
  echo "The commit was NOT created."
  echo ""
  echo "To resolve:"
  echo "  1. If real: rotate the credential on the upstream service NOW, then"
  echo "     remove the secret from the working tree and re-stage a clean diff."
  echo "     Use 'git restore --staged <file>' to unstage the current change."
  echo "  2. If false positive (commit SHA, hash, unrelated identifier):"
  echo "     stage smaller chunks until the matching one is isolated, or"
  echo "     rephrase the content to avoid the pattern."
  echo "  3. If the secret sits in another repo than the one you commit in,"
  echo "     unstage it there or commit from a session whose cwd is clean."
  echo ""
  echo "=========================================================================="
} >&2
exit 2

# shellcheck shell=bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# LanguageTool wrapper consolidating the LT stage shared by every
# `scripts/prose-check.sh` across agentnative-{spec,cli,site,skill}.
#
# The four repos converged on the same LT contract:
#   - Probe <base>/v2/languages with --max-time 2 to decide reachability.
#     With no URL given, <base> is the languagetool Tailscale Service under
#     the tailnet's full MagicDNS name, https://languagetool.<suffix>, with
#     <suffix> read from `tailscale status --json` when a function runs (the
#     name never lives in this repo). A Service answers https on 443 only, and
#     a short name fails its TLS handshake and times out on macOS.
#   - POST /v2/check per file with language=en-US and text@<file>.
#   - Treat matches whose category is TYPOS, GRAMMAR, or CONFUSED_WORDS
#     as blocking; everything else is advisory. The other LT categories
#     (PUNCTUATION, TYPOGRAPHY, CASING, COMPOUNDING) fire ~95% noise on
#     markdown corpora because LT misreads table whitespace, `->` arrows,
#     and code-fence quotes — keep them on the warning tier until LT
#     gains markdown awareness or a per-rule allowlist lands.
#   - Suppress a 10-rule baseline of false positives that hit on every
#     repo's prose (see LT_DENY_RULES_BASELINE below).
#   - Approximate line numbers from byte offsets via awk; LT v1 does not
#     return line/column natively.
#   - When LT cannot be reached, its URL cannot be worked out, or a file's
#     /v2/check request fails, exit 2 and print a WARNING notice on stderr: the
#     cause, what did not run, the command that diagnoses it, and how to name
#     another server. Callers decide whether exit 2 skips the stage or fails the
#     run.
#
# Per-repo denylist extensions go in LT_DENY_RULES, layering on top of
# the baseline. Example for agentnative-site, where the corpus uses
# "principle" extensively and CF CLI command names trip PLURAL_MODIFIER:
#
#   LT_DENY_RULES="${LT_DENY_RULES_BASELINE}|IN_PRINCIPAL|CONTRACT_CONTACT|TO_DO_HYPHEN|PLURAL_MODIFIER"
#   lt_check "${MD_FILES[@]}"
#
# Functions:
#   lt_check [--lt-url URL] FILE [FILE...]   Run grammar check (this is the
#                                            workhorse the prose-check.sh
#                                            scripts call).
#   lt_info       [--lt-url URL]             Server URL, reachability, version.
#   lt_languages  [--lt-url URL]             Supported languages from /v2/languages.
#   lt_rules      [--lt-url URL]             Baseline denylist with reasons +
#                                            currently active LT_DENY_RULES.
#   lt_categories                            Static catalogue of LT category
#                                            constants and which block by default.
#
# Env (all optional):
#   LANGUAGETOOL_URL        LT base URL (default https://languagetool.<MagicDNS
#                           suffix>, the suffix read from `tailscale status`)
#   LT_BLOCKING_CATEGORIES  Anchored category regex
#                           (default ^(TYPOS|GRAMMAR|CONFUSED_WORDS)$)
#   LT_DENY_RULES           Inner alternation of rule IDs to suppress
#                           (default $LT_DENY_RULES_BASELINE)
#   LT_PROBE_TIMEOUT        /v2/languages probe timeout, seconds (default 2)
#   LT_TAILSCALE_APP        Tailscale CLI used when `tailscale` is not on PATH (default
#                           /Applications/Tailscale.app/Contents/MacOS/Tailscale)
#   LT_CHECK_TIMEOUT        /v2/check timeout per file, seconds (default 30)
#   LT_JOBS                 Parallel check workers (default 4)
#
# Output:
#   stdout — one match per line, sorted by input file order:
#     blocking:  <file>:<line>:LT.<rule_id> (<category>): <message>
#     warning:   [warn] <file>:<line>:LT.<rule_id> (<category>): <message>
#   stderr — nothing on a run; on exit 2, or on 1 with unchecked files, the
#     WARNING notice described above.
#
# Exit:
#   0  ran, no blocking matches (warnings may still have printed)
#   1  ran, blocking matches present (also on stdout)
#   2  LT unreachable, no URL to try, or no file checked (blocking matches in
#      the files that were checked exit 1 instead); caller decides whether to
#      proceed
#   3  usage error (no files, unknown flag)
#
# Deps: curl, jaq, awk, xargs, mktemp; the Tailscale CLI only when no URL is given.
#
# Rule baseline — 10 rules that misfire on technical prose patterns
# every repo's corpus contains. Override the whole list by setting
# LT_DENY_RULES; extend the baseline by setting
# LT_DENY_RULES="${LT_DENY_RULES_BASELINE}|EXTRA_RULE".
#
#   MD_BASEFORM            "MUST <verb>" / "MAY <verb>" — LT does not
#                          recognize RFC 2119 keywords; treats them as
#                          modal-verb usage and demands base form.
#   MUST_HAVE_TO           Same root cause for "must" usage.
#   HAVE_PART_AGREEMENT    Misfires on "if: CLI has X" YAML-prose.
#   PREPOSITION_VERB       Misfires on workflow names ("deploy / publish").
#   THIS_NNS               Misfires on "all of these hold" technical claims.
#   NON_STANDARD_WORD      Misfires on identifier strings inside code spans.
#   POSSESSIVE_APOSTROPHE  Misfires on code-comment-style prose.
#   A_INSTALL              Misfires on "an install path" / "a full reinstall" —
#                          CLI-domain noun usage of install/reinstall that
#                          LT's noun lexicon does not cover.
#   IS_AND_ARE             Misfires on parenthetical-clause subjects, e.g.
#                          "runtimes (Claude Code, Cursor, ... and others as
#                          the ecosystem evolves)" — LT picks the wrong head
#                          noun when a parenthetical sits between subject and
#                          verb.
#   SINGULAR_NOUN_ADV_AGREEMENT
#                          Misfires on subordinate-clause subjects, e.g.
#                          "Agents consuming JSON output still receive
#                          interleaved diagnostic text" — LT parses "JSON
#                          output" as the head noun and demands a singular
#                          verb when the actual subject ("Agents") is plural.
LT_DENY_RULES_BASELINE='MD_BASEFORM|MUST_HAVE_TO|HAVE_PART_AGREEMENT|PREPOSITION_VERB|THIS_NNS|NON_STANDARD_WORD|POSSESSIVE_APOSTROPHE|A_INSTALL|IS_AND_ARE|SINGULAR_NOUN_ADV_AGREEMENT'

# _lt_tailscale_cli: print the command that runs the Tailscale CLI: tailscale
# when it is on PATH, else the macOS app's bundled binary, which the app does
# not put on PATH. Fails when neither exists.
_lt_tailscale_cli() {
  if command -v tailscale >/dev/null 2>&1; then
    printf 'tailscale'
    return 0
  fi
  local app="${LT_TAILSCALE_APP:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
  [[ -x "$app" ]] || return 1
  printf '%s' "$app"
}

# _lt_default_url OUTVAR: set OUTVAR to the languagetool Tailscale Service's
# URL. Fails when the tailnet's MagicDNS suffix cannot be read (no Tailscale
# CLI, Tailscale not running) or is not a bare DNS suffix, so a malformed
# value never reaches a URL.
_lt_default_url() {
  local cli suffix
  cli=$(_lt_tailscale_cli) || return 1
  suffix=$("$cli" status --json 2>/dev/null | jaq -r '.MagicDNSSuffix // empty' 2>/dev/null) || return 1
  case "$suffix" in
    '' | *[!A-Za-z0-9.-]* | .* | *.) return 1 ;;
  esac
  printf -v "$1" 'https://languagetool.%s' "$suffix"
}

# _lt_probe URL: succeed when URL answers /v2/languages. Leaves curl's exit
# status for _lt_probe_reason.
_lt_probe() {
  curl --max-time "${LT_PROBE_TIMEOUT:-2}" -fsS "$1/v2/languages" >/dev/null 2>&1
}

# _lt_probe_reason CURL_EXIT: why the probe failed, in words.
_lt_probe_reason() {
  case "$1" in
    6) printf "couldn't resolve host (Tailscale likely off, or the name is wrong)" ;;
    7) printf "couldn't connect (host down, port closed, or a Tailscale Service, which answers https on 443 only)" ;;
    22) printf 'answered with an HTTP error status (not a LanguageTool server?)' ;;
    28) printf 'timed out (>%ss; service slow or network impaired)' "${LT_PROBE_TIMEOUT:-2}" ;;
    35) printf 'TLS handshake failed (an https Service answers only under its full MagicDNS name)' ;;
    60) printf 'TLS certificate not trusted' ;;
    *) printf 'curl exit %s' "$1" ;;
  esac
}

# _lt_notice_not_run CALLER: the line that says no grammar check happened.
# lt_check is the only function that runs one; the query functions only ask
# the server about itself.
_lt_notice_not_run() {
  if [[ "$1" == lt_check ]]; then
    printf 'WARNING: %s: grammar check NOT RUN; only the other stages vouch for this prose\n' "$1"
  fi
}

# _lt_notice_notes CALLER DIAGNOSE_COMMAND: the NOTE lines that close every
# notice. LANGUAGETOOL_URL is the override every caller honors; the prose-check
# scripts accept no --lt-url.
_lt_notice_notes() {
  printf 'NOTE: %s: diagnose with: %s\n' "$1" "$2"
  printf 'NOTE: %s: to use another server: export LANGUAGETOOL_URL=<base url>\n' "$1"
}

# _lt_warn_unreachable CALLER URL CURL_EXIT: the stderr notice for a server
# that did not answer the probe.
_lt_warn_unreachable() {
  {
    printf 'WARNING: %s: LanguageTool unreachable at %s: %s\n' "$1" "$2" "$(_lt_probe_reason "$3")"
    _lt_notice_not_run "$1"
    _lt_notice_notes "$1" "curl -sS $2/v2/languages"
  } >&2
}

# _lt_warn_no_url CALLER: the stderr notice for a default URL that could not
# be worked out.
_lt_warn_no_url() {
  {
    printf "WARNING: %s: LanguageTool URL unknown: LANGUAGETOOL_URL is unset and the tailnet name could not be read from 'tailscale status --json' (CLI missing, or Tailscale not running)\n" "$1"
    _lt_notice_not_run "$1"
    _lt_notice_notes "$1" 'tailscale status'
  } >&2
}

# _lt_warn_unchecked CALLER URL UNCHECKED TOTAL: the stderr notice for files
# whose /v2/check request failed or came back without a matches list.
_lt_warn_unchecked() {
  {
    printf 'WARNING: %s: LanguageTool did not check %s of %s file(s): /v2/check failed or returned no matches list\n' "$1" "$3" "$4"
    _lt_notice_notes "$1" "curl -sS -d language=en-US -d text=test $2/v2/check"
  } >&2
}

# _lt_url_or_default CALLER OUTVAR EXPLICIT: set OUTVAR to EXPLICIT when it is
# non-empty, else to the default URL. Prints the notice and returns 2 when
# there is no default to fall back on.
_lt_url_or_default() {
  if [[ -n "$3" ]]; then
    printf -v "$2" '%s' "$3"
    return 0
  fi
  _lt_default_url "$2" && return 0
  _lt_warn_no_url "$1"
  return 2
}

lt_check() {
  local lt_url="${LANGUAGETOOL_URL:-}"
  local blocking_re="${LT_BLOCKING_CATEGORIES:-^(TYPOS|GRAMMAR|CONFUSED_WORDS)$}"
  local deny_re="^(${LT_DENY_RULES:-$LT_DENY_RULES_BASELINE})\$"
  local check_timeout="${LT_CHECK_TIMEOUT:-30}"
  local jobs="${LT_JOBS:-4}"
  local -a files=()

  while (($#)); do
    case "$1" in
      --lt-url)
        lt_url="$2"
        shift 2
        ;;
      --lt-url=*)
        lt_url="${1#--lt-url=}"
        shift
        ;;
      -h | --help)
        printf 'Usage: lt_check [--lt-url URL] FILE [FILE...]\n' >&2
        return 3
        ;;
      --)
        shift
        files+=("$@")
        break
        ;;
      -*)
        printf 'lt_check: unknown flag %q\n' "$1" >&2
        return 3
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done

  if ((${#files[@]} == 0)); then
    printf 'lt_check: no files supplied\n' >&2
    return 3
  fi

  _lt_url_or_default lt_check lt_url "$lt_url" || return 2

  local probe_rc=0
  _lt_probe "$lt_url" || probe_rc=$?
  if ((probe_rc != 0)); then
    _lt_warn_unreachable lt_check "$lt_url" "$probe_rc"
    return 2
  fi

  local tmp blocking_count=0
  tmp="$(mktemp -d)"

  # shellcheck disable=SC2016  # $1..$4 inside the single-quoted bash -c body are positional args, not parent-shell expansions
  printf '%s\0' "${files[@]}" \
    | xargs -0 -P "$jobs" -I{} bash -c '
            file="$1"; tmp="$2"; url="$3"; timeout="$4"
            out="$tmp/$(printf "%s" "$file" | tr "/" "_").json"
            curl -sS --max-time "$timeout" -X POST "$url/v2/check" \
                --data-urlencode "language=en-US" \
                --data-urlencode "text@$file" > "$out" 2>/dev/null || true
        ' _ {} "$tmp" "$lt_url" "$check_timeout" \
    || true

  local f json offset rule_id category message line unchecked=0
  for f in "${files[@]}"; do
    json="$tmp/$(printf '%s' "$f" | tr '/' '_').json"
    if ! jaq -e '.matches | type == "array"' "$json" >/dev/null 2>&1; then
      unchecked=$((unchecked + 1))
      continue
    fi
    while IFS=$'\t' read -r offset rule_id category message; do
      [[ -z "$offset" ]] && continue
      line=$(awk -v off="$offset" 'BEGIN{cur=0} {cur+=length($0)+1; if (cur>off) {print NR; exit}}' "$f" 2>/dev/null)
      line="${line:-?}"
      if [[ "$category" =~ $blocking_re ]] && ! [[ "$rule_id" =~ $deny_re ]]; then
        blocking_count=$((blocking_count + 1))
        printf '%s:%s:LT.%s (%s): %s\n' "$f" "$line" "$rule_id" "$category" "$message"
      else
        printf '[warn] %s:%s:LT.%s (%s): %s\n' "$f" "$line" "$rule_id" "$category" "$message"
      fi
    done < <(jaq -r '.matches[]? | [.offset, .rule.id, .rule.category.id, .message] | @tsv' "$json" 2>/dev/null || true)
  done

  rm -rf "$tmp"
  ((unchecked > 0)) && _lt_warn_unchecked lt_check "$lt_url" "$unchecked" "${#files[@]}"
  ((blocking_count > 0)) && return 1
  ((unchecked > 0)) && return 2
  return 0
}

# _lt_resolve_url OUTVAR [--lt-url URL | --lt-url=URL]: shared flag parser for
# the query functions below. Sets OUTVAR to the URL the flag gives, else
# LANGUAGETOOL_URL, else the empty string: the default is _lt_url_or_default's
# to work out, and only for a function that uses the URL. Returns 0, 3 on an
# unknown flag (named on stderr), or 4 on -h / --help.
_lt_resolve_url() {
  local _outvar="$1"
  shift
  local _url="${LANGUAGETOOL_URL:-}"
  while (($#)); do
    case "$1" in
      --lt-url)
        _url="$2"
        shift 2
        ;;
      --lt-url=*)
        _url="${1#--lt-url=}"
        shift
        ;;
      -h | --help)
        printf -v "$_outvar" '%s' "$_url"
        return 4
        ;;
      *)
        printf 'unknown flag %q\n' "$1" >&2
        return 3
        ;;
    esac
  done
  printf -v "$_outvar" '%s' "$_url"
  return 0
}

# lt_info: server URL, reachability, software version, language count.
lt_info() {
  local lt_url
  _lt_resolve_url lt_url "$@"
  local rc=$?
  if ((rc == 4)); then
    printf 'Usage: lt_info [--lt-url URL]\n' >&2
    return 0
  fi
  ((rc != 0)) && return "$rc"

  if ! _lt_url_or_default lt_info lt_url "$lt_url"; then
    printf 'URL:           (unknown)\nReachable:     no (no URL to try)\n'
    return 2
  fi

  local probe_timeout="${LT_PROBE_TIMEOUT:-2}"
  printf 'URL:           %s\n' "$lt_url"

  local probe_rc=0
  _lt_probe "$lt_url" || probe_rc=$?
  if ((probe_rc != 0)); then
    printf 'Reachable:     no (%s)\n' "$(_lt_probe_reason "$probe_rc")"
    return 2
  fi
  printf 'Reachable:     yes\n'

  local probe_json
  probe_json=$(curl -sS --max-time "$probe_timeout" -X POST "$lt_url/v2/check" \
    --data-urlencode "language=en-US" \
    --data-urlencode "text=test" 2>/dev/null)
  if [[ -n "$probe_json" ]]; then
    local sw_name sw_version sw_api sw_premium
    sw_name=$(jaq -r '.software.name // "?"' <<<"$probe_json" 2>/dev/null)
    sw_version=$(jaq -r '.software.version // "?"' <<<"$probe_json" 2>/dev/null)
    sw_api=$(jaq -r '.software.apiVersion // "?"' <<<"$probe_json" 2>/dev/null)
    sw_premium=$(jaq -r '.software.premium // false' <<<"$probe_json" 2>/dev/null)
    printf 'Software:      %s %s (apiVersion %s, premium=%s)\n' \
      "$sw_name" "$sw_version" "$sw_api" "$sw_premium"
  fi

  local lang_count
  lang_count=$(curl -sS --max-time "$probe_timeout" "$lt_url/v2/languages" 2>/dev/null \
    | jaq -r 'length' 2>/dev/null)
  [[ -n "$lang_count" ]] && printf 'Languages:     %s supported (see: lt_languages)\n' "$lang_count"
}

# lt_languages: pretty-print /v2/languages as "code\tname".
lt_languages() {
  local lt_url
  _lt_resolve_url lt_url "$@"
  local rc=$?
  if ((rc == 4)); then
    printf 'Usage: lt_languages [--lt-url URL]\n' >&2
    return 0
  fi
  ((rc != 0)) && return "$rc"

  _lt_url_or_default lt_languages lt_url "$lt_url" || return 2

  local json probe_rc=0
  json=$(curl -fsS --max-time "${LT_PROBE_TIMEOUT:-2}" "$lt_url/v2/languages" 2>/dev/null) || probe_rc=$?
  if ((probe_rc != 0)); then
    _lt_warn_unreachable lt_languages "$lt_url" "$probe_rc"
    return 2
  fi
  if [[ -z "$json" ]]; then
    printf 'lt_languages: empty response from %s\n' "$lt_url" >&2
    return 2
  fi
  jaq -r '.[] | [.longCode, .code, .name] | @tsv' <<<"$json" \
    | awk -F'\t' '{printf "  %-10s %-6s %s\n", $1, $2, $3}'
}

# lt_rules: print baseline denylist with one-line reasons and the currently
# active effective LT_DENY_RULES (which the consumer may have extended).
lt_rules() {
  local lt_url
  _lt_resolve_url lt_url "$@"
  local rc=$?
  if ((rc == 4)); then
    printf 'Usage: lt_rules [--lt-url URL]\n' >&2
    return 0
  fi
  ((rc != 0)) && return "$rc"

  cat <<'EOF'
LT blocking categories (default; override via LT_BLOCKING_CATEGORIES):
  TYPOS  GRAMMAR  CONFUSED_WORDS

Baseline rule denylist (LT_DENY_RULES_BASELINE) — rules within the blocking
categories that misfire on technical-prose patterns. Extend, don't replace:
  LT_DENY_RULES="${LT_DENY_RULES_BASELINE}|EXTRA_RULE"

  MD_BASEFORM            "MUST <verb>" / "MAY <verb>" — RFC 2119 keywords
                         read as modal verbs demanding base form.
  MUST_HAVE_TO           "must" usage, same root cause as MD_BASEFORM.
  HAVE_PART_AGREEMENT    Misfires on YAML-prose patterns ("if: CLI has X").
  PREPOSITION_VERB       Misfires on workflow names ("deploy / publish").
  THIS_NNS               Misfires on "all of these hold" technical claims.
  NON_STANDARD_WORD      Misfires on identifier strings inside code spans.
  POSSESSIVE_APOSTROPHE  Misfires on code-comment-style prose.
  A_INSTALL              CLI-domain "an install path" / "a full reinstall"
                         that LT's noun lexicon does not cover.
  IS_AND_ARE             Misfires on parenthetical-clause subjects: LT
                         picks the wrong head noun when a parenthetical
                         sits between subject and verb.
  SINGULAR_NOUN_ADV_AGREEMENT
                         Same misfire on subordinate-clause subjects: LT
                         parses the post-modifier as head and demands a
                         singular verb against a plural subject.

EOF
  printf 'Active LT_DENY_RULES regex (effective right now):\n  ^(%s)$\n\n' \
    "${LT_DENY_RULES:-$LT_DENY_RULES_BASELINE}"
  printf 'Full reasoning: less %s\n' "${BASH_SOURCE[0]:-~/dotfiles/config/shell/languagetool.sh}"
}

# lt_categories: static catalogue of LanguageTool category constants.
# Not derivable from the LT API (categories are language-pack metadata
# embedded in the JAR); list comes from the LT rule definitions and from
# observed responses across the four agentnative repos.
lt_categories() {
  cat <<'EOF'
LanguageTool category constants (returned in match.rule.category.id):

  Blocking by default:
    TYPOS               Spelling errors. High signal on prose.
    GRAMMAR             Subject-verb agreement, tense, modals. High signal.
    CONFUSED_WORDS      Homophones (their/there, its/it's). High signal.

  Advisory by default (warning tier; ~95% noise on markdown corpora):
    PUNCTUATION         Misreads table whitespace and code-fence quotes.
    TYPOGRAPHY          Curly-vs-straight quotes, em/en dash spacing.
    CASING              Sentence-initial casing in fragments and headings.
    COMPOUNDING         Open/closed/hyphenated compound suggestions.
    STYLE               Word-choice style; advisory by design upstream.
    REPETITIONS         Repeated words across sentence boundaries.
    SEMANTICS           Logical/semantic patterns.
    COLLOCATIONS        Word-combination preferences.
    MISC                Catch-all for rules not in a specific category.

Default behavior: matches whose rule.category.id matches
  ^(TYPOS|GRAMMAR|CONFUSED_WORDS)$
are blocking; everything else is advisory. Override with LT_BLOCKING_CATEGORIES.
EOF
}

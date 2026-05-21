# shellcheck shell=bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# LanguageTool wrapper consolidating the LT stage shared by every
# `scripts/prose-check.sh` across agentnative-{spec,cli,site,skill}.
#
# The four repos converged on the same LT contract:
#   - Probe http://languagetool:8081/v2/languages with --max-time 2 to
#     decide reachability. FQDN avoids macOS+Tailscale short-name DNS
#     timeouts.
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
#   - Skip gracefully when LT is unreachable (R9) so pushes don't block
#     on Tailscale being off; print a curl-exit-coded reason on stderr.
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
#   LANGUAGETOOL_URL        LT base URL (default http://languagetool:8081)
#   LT_BLOCKING_CATEGORIES  Anchored category regex
#                           (default ^(TYPOS|GRAMMAR|CONFUSED_WORDS)$)
#   LT_DENY_RULES           Inner alternation of rule IDs to suppress
#                           (default $LT_DENY_RULES_BASELINE)
#   LT_PROBE_TIMEOUT        /v2/languages probe timeout, seconds (default 2)
#   LT_CHECK_TIMEOUT        /v2/check timeout per file, seconds (default 30)
#   LT_JOBS                 Parallel check workers (default 4)
#
# Output:
#   stdout — one match per line, sorted by input file order:
#     blocking:  <file>:<line>:LT.<rule_id> (<category>): <message>
#     warning:   [warn] <file>:<line>:LT.<rule_id> (<category>): <message>
#   stderr — reachability notice with curl-exit explanation on probe fail.
#
# Exit:
#   0  ran, no blocking matches (warnings may still have printed)
#   1  ran, blocking matches present (also on stdout)
#   2  LT unreachable; caller decides whether to proceed
#   3  usage error (no files, unknown flag)
#
# Deps: curl, jaq, awk, xargs, mktemp.
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

lt_check() {
    local lt_url="${LANGUAGETOOL_URL:-http://languagetool:8081}"
    local blocking_re="${LT_BLOCKING_CATEGORIES:-^(TYPOS|GRAMMAR|CONFUSED_WORDS)$}"
    local deny_re="^(${LT_DENY_RULES:-$LT_DENY_RULES_BASELINE})\$"
    local probe_timeout="${LT_PROBE_TIMEOUT:-2}"
    local check_timeout="${LT_CHECK_TIMEOUT:-30}"
    local jobs="${LT_JOBS:-4}"
    local -a files=()

    while (( $# )); do
        case "$1" in
            --lt-url)   lt_url="$2"; shift 2 ;;
            --lt-url=*) lt_url="${1#--lt-url=}"; shift ;;
            -h|--help)
                printf 'Usage: lt_check [--lt-url URL] FILE [FILE...]\n' >&2
                return 3
                ;;
            --)         shift; files+=("$@"); break ;;
            -*)         printf 'lt_check: unknown flag %q\n' "$1" >&2; return 3 ;;
            *)          files+=("$1"); shift ;;
        esac
    done

    if (( ${#files[@]} == 0 )); then
        printf 'lt_check: no files supplied\n' >&2
        return 3
    fi

    local probe_rc=0
    curl --max-time "$probe_timeout" -fsS "$lt_url/v2/languages" >/dev/null 2>&1 || probe_rc=$?
    if (( probe_rc != 0 )); then
        local reason
        case "$probe_rc" in
            6)  reason="couldn't resolve host (Tailscale likely off, or FQDN drift)" ;;
            7)  reason="couldn't connect (host up, LT service down)" ;;
            28) reason="timed out (>${probe_timeout}s; service slow or network impaired)" ;;
            *)  reason="curl exit $probe_rc" ;;
        esac
        printf 'lt_check: LanguageTool unreachable at %s — %s\n' "$lt_url" "$reason" >&2
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

    local f json offset rule_id category message line
    for f in "${files[@]}"; do
        json="$tmp/$(printf '%s' "$f" | tr '/' '_').json"
        [[ -s "$json" ]] || continue
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
    (( blocking_count > 0 )) && return 1
    return 0
}

# _lt_resolve_url: shared --lt-url / LANGUAGETOOL_URL parser for the query
# functions below. Sets the caller-scoped var named in $1 to the resolved URL,
# consuming "--lt-url URL" / "--lt-url=URL" from the caller's positional args
# via $2…$N. Echoes any leftover positional args on stdout so the caller can
# repopulate its own arg list. Returns 0 on success, 3 on unknown flag.
_lt_resolve_url() {
    local _outvar="$1"; shift
    local _url="${LANGUAGETOOL_URL:-http://languagetool:8081}"
    while (( $# )); do
        case "$1" in
            --lt-url)   _url="$2"; shift 2 ;;
            --lt-url=*) _url="${1#--lt-url=}"; shift ;;
            -h|--help)  printf -v "$_outvar" '%s' "$_url"; return 4 ;;
            *)          printf 'unknown flag %q\n' "$1" >&2; return 3 ;;
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
    if (( rc == 4 )); then
        printf 'Usage: lt_info [--lt-url URL]\n' >&2
        return 0
    fi
    (( rc != 0 )) && return "$rc"

    local probe_timeout="${LT_PROBE_TIMEOUT:-2}"
    printf 'URL:           %s\n' "$lt_url"

    local probe_rc=0
    curl --max-time "$probe_timeout" -fsS "$lt_url/v2/languages" >/dev/null 2>&1 || probe_rc=$?
    if (( probe_rc != 0 )); then
        local reason
        case "$probe_rc" in
            6)  reason="couldn't resolve host" ;;
            7)  reason="couldn't connect" ;;
            28) reason="timed out (>${probe_timeout}s)" ;;
            *)  reason="curl exit $probe_rc" ;;
        esac
        printf 'Reachable:     no (%s)\n' "$reason"
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
    if (( rc == 4 )); then
        printf 'Usage: lt_languages [--lt-url URL]\n' >&2
        return 0
    fi
    (( rc != 0 )) && return "$rc"

    local probe_timeout="${LT_PROBE_TIMEOUT:-2}"
    local json
    json=$(curl -sS --max-time "$probe_timeout" "$lt_url/v2/languages" 2>/dev/null) || {
        printf 'lt_languages: cannot reach %s\n' "$lt_url" >&2
        return 2
    }
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
    if (( rc == 4 )); then
        printf 'Usage: lt_rules [--lt-url URL]\n' >&2
        return 0
    fi
    (( rc != 0 )) && return "$rc"

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

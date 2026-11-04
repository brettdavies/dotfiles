# shellcheck shell=bash
# What a slot's agent hears about its dependency install, for the slot-context hook.

# Usage: context_deps; prints what the slot's agent needs to know about the install in RECORD. A name an install left is
# quoted, because the install chose it, and here it is text in the agent's instructions.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with as
context_deps() {
  contract_json -r 'def more($list; $total): ($total // ($list | length)) - ($list | length) | if . > 0 then " and \(.) more" else "" end;
    (.prime // "its prime checkout") as $prime
    | (.base // "the base branch") as $base
    | (.base // "<base>") as $base_ref
    | .deps // {}
    | ((.dirty // []) | if length > 0
       then "The install left these changed, untracked, or ignored, which can block teardown or land in a commit: \(map(tojson) | join(", "))"
         else "" end) as $dirty_names
    | (if $dirty_names == "" then "" else $dirty_names + more(.dirty; .dirty_total) + "."
         + " Restore or remove what you do not mean to keep." end) as $dirty
    | ((.stopped // []) | if length > 0 then "Setup stopped what the install left running: \(map(tojson) | join(", "))" else "" end) as $stopped_names
    | (if $stopped_names == "" then "" else $stopped_names + more(.stopped; .stopped_total) + "." end) as $stopped
    | (.off_base // "") as $off_base
    | (if $off_base == "prime-lacks-base" or $off_base == "base-rewritten"
       then "Read the whole tree, since nothing vouches for \($base) itself,"
       else "Read the whole of `git diff --text refs/remotes/origin/\($base_ref)...HEAD`, or the whole tree when the head is on \($base)," end) as $reading
    | "An install runs code the tree names, any tracked file can change what it runs, such as pnpm-workspace.yaml,"
      + " binding.gyp, or .env, and --ignore-scripts stops only the scripts. \($reading) before you run it, and if"
      + " you cannot, leave it uninstalled and say so in your report. A frozen install also takes what a lockfile pins"
      + " without the supply-chain age gate." as $read
    | " If your head has since left the base branch, read what it changes first." as $moved
    | "`git -C \($prime) fetch origin \($base_ref):\($base_ref)`" as $fetch_branch
    | "`git -C \($prime) fetch origin`" as $fetch
    | ({"prime-lacks-base": "the prime holds no branch named \($base) that it has seen on origin, so nothing shows that base has been chosen on this host",
        "base-rewritten": ("origin'"'"'s \($base) no longer holds what the prime last knew of it: its history was replaced, or it"
          + " moved while this slot was made"),
        "base-lacks-head": "\($base) does not hold this head",
        "pr-base-lacks-head": "the branch this PR targets does not hold this head",
        "head-behind-base": ("this head is behind \($base), and a head set back to an older commit can bring back what"
          + " \($base) has since removed")}[$off_base]
       // "the base branch does not hold this head") as $cause
    | ({"prime-lacks-base": $fetch_branch, "base-rewritten": $fetch}[$off_base] // "") as $step
    | (if $off_base == "" and .status != "head-not-on-base" then "" else
        " This head'"'"'s git hooks, .claude settings, and CLAUDE.md are unread too, and they run or load whether or not"
        + " you install." end) as $hooks
    | (if (.status // "installed") == "installed" then "" else
      "When this slot was made, `\(.command)` "
      + ({failed: "failed; its log is \(.log).",
          "timed-out": "hit the AGENT_SLOT_DEPS_TIMEOUT limit; its log is \(.log).",
          "tool-missing": "could not run, because \(.manager) is not on this host'"'"'s PATH.",
          "not-ignored": "was not run, because this repo does not ignore node_modules.",
          "prime-not-set-up": ("was not run, because this repo'"'"'s prime is untrusted or its node_modules holds no"
            + " package, so nothing shows its install has been chosen on this host."),
          "head-not-on-base": "was not run, because \($cause)."}[.status]
         // "reported \(.status).")
      + " If it has not succeeded since, the repo'"'"'s hooks fail their tool gates, so deal with that before your first"
      + " push. "
      + ({failed: ("Read the log, fix what it names, and rerun the command from the slot root." + $moved),
          "timed-out": ("Rerun it from the slot root, where that limit does not apply." + $moved),
          "tool-missing": "Installing a package manager is a host change, so report this to whoever you report to.",
          "not-ignored": ("Installing here leaves an untracked tree that blocks teardown and can land in a commit, so add"
            + " node_modules/ to .gitignore first if your task allows that, and otherwise report it."),
          "prime-not-set-up": ($read + $hooks + " Later slots of this repo install on their own once the operator has"
            + (if $step == "" then "" else " run \($step), has" end)
            + " run this install in the prime at \($prime) and opened Claude there."),
          "head-not-on-base": ($read + $hooks
            + (if $step == ""
               then ""
               else " Later slots of this repo install on their own once the operator has run \($step)." end))}[.status] // "") end) as $status_line
    | [$status_line, $dirty, $stopped] | map(select(. != "")) | join(" ")' <<<"$RECORD"
}

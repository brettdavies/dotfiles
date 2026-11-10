# shellcheck shell=bash disable=SC2016 # jq programs; their $names are bound with --arg
# schema: the JSON Schema of the objects agent-slot prints and the closed reason table behind its errors, so an agent
# learns the contract at run time rather than from the README.

cmd_schema() {
  local reasons
  reasons=$(awk 'NF == 5 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }' <<<"$CONTRACT_REASONS" | contract_json -R -s -c '
    split("\n") | map(select(. != "") | split("\t")
      | {reason: .[0], exit_code: (.[1] | tonumber), retryable: (.[2] == "true"), max_retries: (.[3] | tonumber),
         action: .[4]})')
  contract_ok "$(contract_json -n -c --argjson reasons "$reasons" --arg schema "$CONTRACT_SCHEMA" \
    --arg actions "$CONTRACT_ACTIONS" \
    --argjson exits "[$EXIT_OK, $EXIT_GENERAL, $EXIT_USAGE, $EXIT_AUTH, $EXIT_CONFIG]" '
    "https://json-schema.org/draft/2020-12/schema" as $draft
    | {success: {"$schema": $draft, title: "agent-slot success", type: "object",
                 required: ["schema", "ok", "verb"],
                 properties: {schema: {const: $schema}, ok: {const: true}, verb: {type: "string"}},
                 description: "Each verb adds its own fields; agent-slot <verb> --help lists them."},
       error: {"$schema": $draft, title: "agent-slot error", type: "object",
               required: ["schema", "ok", "verb", "reason", "exit_code", "message", "value", "next_step", "recovery",
                          "context", "log"],
               properties: {
                 schema: {const: $schema}, ok: {const: false}, verb: {type: "string"},
                 reason: {enum: [$reasons[].reason]}, exit_code: {enum: $exits}, message: {type: "string"},
                 value: {type: ["string", "null"]},
                 next_step: {type: "object", required: ["action", "command", "docs"],
                             properties: {action: {enum: ($actions | split(" "))}, command: {type: ["string", "null"]},
                                          docs: {type: "string"}}},
                 recovery: {type: "object", required: ["side_effects", "retryable", "max_retries", "reconcile"],
                            properties: {side_effects: {enum: ["none", "partial", "unknown"]},
                                         retryable: {type: "boolean"}, max_retries: {type: "integer"},
                                         reconcile: {type: ["string", "null"]}}},
                 context: {type: "object"}, log: {type: ["string", "null"]}}},
       reasons: $reasons}')" '
    "success: {schema, ok: true, verb, and the verb'"'"'s own fields (agent-slot <verb> --help lists them)}",
    "error: {schema, ok: false, verb, reason, exit_code, message, value, next_step {action, command, docs},",
    "       recovery {side_effects, retryable, max_retries, reconcile}, context, log}",
    "reasons (exit, retryable, action):",
    (.reasons[] | "  \(.reason)\t\(.exit_code)\t\(.retryable)\t\(.action)")'
}

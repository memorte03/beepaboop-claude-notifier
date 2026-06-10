#!/usr/bin/env bash
# PreToolUse hook: BLOCKING.
# Posts to /permission and waits for the overlay's Approve/Deny click,
# then emits the matching permissionDecision JSON. If the server is down
# or the user doesn't click within the timeout, falls back to "ask" so
# Claude Code shows its native prompt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=beepaboop-common.sh
source "$SCRIPT_DIR/beepaboop-common.sh"

tool_name="$(cn_tool_name)"
diff_preview=""

# ── allow-rule short-circuit ─────────────────────────────────────────────
# If the tool would be auto-allowed by ~/.claude/settings*.json's
# `permissions.allow`, return "allow" and skip the overlay entirely.
# Without this, returning "ask" from the hook overrides matching allow rules,
# forcing the native prompt to appear for tools the user has already
# pre-approved (the "Claude is asking me too much" symptom).

rule_matches() {
    local tool="$1" rule="$2"

    # Bare tool name match (e.g. "WebFetch", "WebSearch", "mcp__foo__bar").
    [[ "$rule" == "$tool" ]] && return 0

    # Tool(pattern) form. Match the literal "tool(" prefix and ")" suffix rather
    # than interpolating $tool into a regex (MCP/other names contain regex
    # metacharacters like . + ( that would mis-match).
    if [[ "$rule" == "$tool("*")" ]]; then
        local inner="${rule#"$tool("}"
        local pattern="${inner%)}"
        case "$tool" in
            Bash)
                local cmd
                cmd="$(jq -r '.tool_input.command // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
                # Wildcard
                [[ "$pattern" == "*" || "$pattern" == ":*" ]] && return 0
                # "prefix:*" → command must start with "prefix"
                local prefix="${pattern%:\*}"
                [[ -n "$prefix" && "$cmd" == "$prefix"* ]] && return 0
                # Exact command match (no trailing :*)
                [[ "$pattern" == "$cmd" ]] && return 0
                ;;
            Write|Edit|MultiEdit|NotebookEdit|Read|Update)
                [[ "$pattern" == "*" || "$pattern" == "*:*" ]] && return 0
                local path
                path="$(jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
                [[ "$pattern" == "$path" ]] && return 0
                # trailing /* glob
                if [[ "$pattern" == */\* ]]; then
                    local base="${pattern%/\*}"
                    [[ "$path" == "$base/"* ]] && return 0
                fi
                ;;
            *)
                [[ "$pattern" == "*" || "$pattern" == "*:*" ]] && return 0
                ;;
        esac
    fi
    return 1
}

matches_rule_list() {
    local tool="$1" list="$2"   # list: "allow" | "deny"
    local settings_files=(
        "${HOME}/.claude/settings.local.json"
        "${HOME}/.claude/settings.json"
    )
    local f rule
    for f in "${settings_files[@]}"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            # Explicit `if` (not `cmd && return`) so a non-matching rule's
            # non-zero status can't trip `set -e` and abort the hook.
            if rule_matches "$tool" "$rule"; then return 0; fi
        done < <(jq -r ".permissions.${list}[]? // empty" "$f" 2>/dev/null)
    done
    return 1
}

# Deny rules take precedence: if one matches, return "ask" so Claude Code's
# own evaluation (which honors deny) runs — our "allow" must never override it.
if matches_rule_list "$tool_name" "deny"; then
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask"}}'
    exit 0
fi

if matches_rule_list "$tool_name" "allow"; then
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow"}}'
    exit 0
fi

# Compute a short unified diff for Edit/Write/MultiEdit so the overlay can
# show what Claude wants to change without you switching to the terminal.
cn_diff() {
    local old="$1" new="$2"
    local old_f new_f
    old_f="$(mktemp -t cn-old)"
    new_f="$(mktemp -t cn-new)"
    # Clean up even if the pipeline below exits early.
    trap 'rm -f "$old_f" "$new_f"' RETURN
    printf '%s' "$old" > "$old_f"
    printf '%s' "$new" > "$new_f"
    # Drop the two header lines from -u output, cap to ~14 changed lines.
    # `diff` exits 1 when files differ (the normal case) and `head` SIGPIPEs the
    # upstream; `|| true` keeps that from aborting the hook under set -e/pipefail.
    diff -u "$old_f" "$new_f" 2>/dev/null | tail -n +3 | head -n 16 || true
}

case "$tool_name" in
    Bash)
        cmd="$(jq -r '.tool_input.command // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        context="$(cn_trim "\$ $cmd")"
        title="Run shell command?"
        ;;
    Edit)
        path="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        old_string="$(jq -r '.tool_input.old_string // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        new_string="$(jq -r '.tool_input.new_string // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        diff_preview="$(cn_diff "$old_string" "$new_string")"
        context="$(cn_trim "$path")"
        title="Modify $(cn_basename "$path")?"
        ;;
    MultiEdit)
        path="$(jq -r '.tool_input.file_path // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        n_edits="$(jq -r '.tool_input.edits | length' <<<"$CN_HOOK_RAW" 2>/dev/null || echo 0)"
        # Show the first edit's diff as a representative preview.
        old_string="$(jq -r '.tool_input.edits[0].old_string // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        new_string="$(jq -r '.tool_input.edits[0].new_string // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        diff_preview="$(cn_diff "$old_string" "$new_string")"
        context="$path ($n_edits edits)"
        title="Apply $n_edits edits to $(cn_basename "$path")?"
        ;;
    Write)
        path="$(jq -r '.tool_input.file_path // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        new_content="$(jq -r '.tool_input.content // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        old_content="$(cat "$path" 2>/dev/null || true)"
        diff_preview="$(cn_diff "$old_content" "$new_content")"
        if [[ -e "$path" ]]; then
            context="overwrite $path"
            title="Overwrite $(cn_basename "$path")?"
        else
            context="create $path"
            title="Create $(cn_basename "$path")?"
        fi
        ;;
    NotebookEdit)
        path="$(jq -r '.tool_input.notebook_path // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        context="$(cn_trim "$path")"
        title="Edit notebook?"
        ;;
    WebFetch|WebSearch)
        target="$(jq -r '.tool_input.url // .tool_input.query // empty' <<<"$CN_HOOK_RAW" 2>/dev/null || true)"
        context="$(cn_trim "$target")"
        title="Run $tool_name?"
        ;;
    *)
        tinput="$(cn_tool_input)"
        context="$(cn_trim "$tinput")"
        title="Run $tool_name?"
        ;;
esac

id="$(cn_uuid)"
payload="$(cn_build_payload "$id" "permission" "$title" "$context" \
            | jq -c --arg diff "$diff_preview" \
                '. + {actions:["Approve","Deny"]} + (if ($diff | length) > 0 then {diffPreview:$diff} else {} end)')"

# Long-poll the server. Slightly longer than the in-app permission timeout
# (10s) so the server times out first and returns "ask" rather than curl
# killing the connection.
response="$(curl --silent --show-error --max-time 15 \
                 -X POST "$CN_URL/permission" \
                 -H 'Content-Type: application/json' \
                 -H "X-Beepaboop-Token: ${CN_TOKEN}" \
                 -d "$payload" 2>/dev/null || true)"

decision="$(jq -r '.decision // "ask"' <<<"$response" 2>/dev/null || echo "ask")"
reason="$(jq -r '.reason // empty' <<<"$response" 2>/dev/null || true)"

case "$decision" in
    allow|deny|ask) ;;
    *) decision="ask" ;;
esac

if [[ -n "$reason" ]]; then
    jq -nc --arg d "$decision" --arg r "$reason" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
else
    jq -nc --arg d "$decision" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d}}'
fi

exit 0

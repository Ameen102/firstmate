# shellcheck shell=bash
# fm-never-send-lib.sh - the outbound never-send list check, one owner for every
# tool that sends fleet text to a model provider.
#
# Sourced, never executed. The list is the optional $CONFIG/dispatch-never-send:
# each non-blank, non-# line is a literal matched case-insensitively against the
# text about to leave the machine, with surrounding whitespace trimmed and every
# run of whitespace, on both sides, treated as one space. The caller extracts its
# own outbound text and decides what a refusal means; docs/configuration.md "Typed
# dispatch resolution" owns the operator contract.

# fm_never_send_problem <list-path> <text-file> <text-label>
# Exit 0 when the text may be sent, which includes an absent list. Otherwise print
# the problem and exit 1: a match, or a list or text that cannot be checked. The
# problem names at most the list's line number, never its value, and grep's own
# stderr is discarded because it can echo the pattern.
fm_never_send_problem() {
  local path=$1 text=$2 label=$3 list value n=0 rc
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if ! { [ -f "$path" ] && [ -r "$path" ]; }; then
    printf '%s is not a readable regular file' "$path"
    return 1
  fi
  if ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$path" 2>/dev/null); then
    printf 'could not read %s' "$path"
    return 1
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$text" 2>/dev/null; rc=$?
    case "$rc" in
      0) printf '%s matches %s line %s' "$label" "$path" "$n"; return 1 ;;
      1) ;;
      *) printf 'could not check the request text against %s line %s' "$path" "$n"; return 1 ;;
    esac
  done <<<"$list"
}

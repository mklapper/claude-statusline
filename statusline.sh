#!/usr/bin/env bash
# Claude Code statusline — model · effort · permission mode · git · context · usage
#
# All data is local: the session JSON arrives on stdin (pushed by Claude Code, no
# API call), and permission mode is read from the transcript file (the same JSONL
# Claude Code already maintains). Nothing here contacts the network.
#
# Tune this: the raw context %% that we treat as "100%% full". Claude Code
# auto-compacts before the hard window limit, so scaling against this makes the
# displayed bar hit 100%% right when auto-compact is imminent.
COMPACT_AT=92

input=$(cat)

# --- one jq pass over the stdin payload ---------------------------------------
# Newline-delimited (not tab): tab is IFS whitespace, so empty optional fields
# would collapse and shift every column. mapfile preserves empty lines exactly.
mapfile -t F < <(printf '%s' "$input" | jq -r '
    .model.display_name // "?",
    (.effort.level // ""),
    (.context_window.used_percentage // 0),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.session_id // ""),
    (.transcript_path // "")')
MODEL=${F[0]}; EFFORT=${F[1]}; CTX_RAW=${F[2]}; FIVE_H=${F[3]}
SEVEN_D=${F[4]}; RESETS_AT=${F[5]}; SESSION_ID=${F[6]}; TRANSCRIPT=${F[7]}

# --- colors -------------------------------------------------------------------
DIM='\033[2m'; RESET='\033[0m'
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; MAGENTA='\033[35m'
BLUE='\033[34m'; BOLDRED='\033[1;31m'

pct_color() { # $1 = percentage int -> echoes a color code
  if   [ "$1" -ge 90 ]; then printf '%b' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%b' "$YELLOW"
  else printf '%b' "$GREEN"; fi
}

# --- permission mode (read last value from the transcript) --------------------
MODE_SEG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  MODE=$(tac "$TRANSCRIPT" | jq -r 'select(.permissionMode!=null) | .permissionMode' 2>/dev/null | head -1)
  case "$MODE" in
    plan)              MODE_SEG=" ${CYAN}PLAN${RESET}" ;;
    acceptEdits)       MODE_SEG=" ${YELLOW}accept-edits${RESET}" ;;
    bypassPermissions) MODE_SEG=" ${RED}BYPASS${RESET}" ;;
    default|"")        MODE_SEG="" ;;   # normal mode: keep the line quiet
    *)                 MODE_SEG=" ${MAGENTA}${MODE}${RESET}" ;;
  esac
fi

# --- git (branch + dirty state), cached 5s per session so it never lags typing
# Buckets are mutually exclusive per file, priority: conflict > deleted >
# staged > modified. Fields cached one-per-line (not tab-delimited: tab is
# IFS whitespace, so an empty OPSTATE field would collapse with its neighbor
# and shift every later field — same gotcha as the jq read above):
# DETACHED NAME AHEAD BEHIND OPSTATE CONFLICTS STAGED MODIFIED DELETED UNTRACKED STASH
GIT_SEG=""
CACHE="/tmp/claude-statusline-git-${SESSION_ID:-none}"
stale() { [ ! -f "$CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) )) -gt 5 ]; }
if stale; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    GITDIR=$(git rev-parse --git-dir 2>/dev/null)
    BR_STATUS=$(git status --porcelain=v1 --branch 2>/dev/null)
    REST=$(printf '%s\n' "$BR_STATUS" | head -1)
    REST=${REST#\#\# }

    DETACHED=0; NAME=""
    if [[ "$REST" == "HEAD (no branch)"* ]]; then
      DETACHED=1
      NAME=$(git rev-parse --short HEAD 2>/dev/null)
    else
      NAME=${REST%%...*}
    fi

    AHEAD=0; BEHIND=0
    [[ "$REST" == *"ahead "* ]] && AHEAD=$(sed -n 's/.*ahead \([0-9]*\).*/\1/p' <<<"$REST")
    [[ "$REST" == *"behind "* ]] && BEHIND=$(sed -n 's/.*behind \([0-9]*\).*/\1/p' <<<"$REST")

    C=0; S=0; MOD=0; DEL=0; U=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      X=${line:0:1}; Y=${line:1:1}
      case "$X$Y" in
        "??") U=$((U+1)) ;;
        *)
          if [ "$X" = "U" ] || [ "$Y" = "U" ] || { [ "$X" = "A" ] && [ "$Y" = "A" ]; } || { [ "$X" = "D" ] && [ "$Y" = "D" ]; }; then
            C=$((C+1))
          elif [ "$X" = "D" ] || [ "$Y" = "D" ]; then
            DEL=$((DEL+1))
          elif [ "$X" != " " ]; then
            S=$((S+1))
          elif [ "$Y" != " " ]; then
            MOD=$((MOD+1))
          fi
          ;;
      esac
    done < <(printf '%s\n' "$BR_STATUS" | tail -n +2)

    OPSTATE=""
    if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then OPSTATE="REBASE"
    elif [ -f "$GITDIR/MERGE_HEAD" ]; then OPSTATE="MERGE"
    elif [ -f "$GITDIR/CHERRY_PICK_HEAD" ]; then OPSTATE="CHERRY-PICK"
    fi

    STASH=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

    printf '%s\n' "$DETACHED" "$NAME" "$AHEAD" "$BEHIND" "$OPSTATE" "$C" "$S" "$MOD" "$DEL" "$U" "$STASH" > "$CACHE"
  else
    printf '%s\n' "0" "" "0" "0" "" "0" "0" "0" "0" "0" "0" > "$CACHE"
  fi
fi
mapfile -t GF < "$CACHE"
DETACHED=${GF[0]}; NAME=${GF[1]}; AHEAD=${GF[2]}; BEHIND=${GF[3]}; OPSTATE=${GF[4]}
C=${GF[5]}; S=${GF[6]}; MOD=${GF[7]}; DEL=${GF[8]}; U=${GF[9]}; STASH=${GF[10]}
if [ -n "$NAME" ]; then
  if   [ "$C" -gt 0 ]; then BR_COLOR="$RED"
  elif [ "$S" -gt 0 ] || [ "$MOD" -gt 0 ] || [ "$DEL" -gt 0 ] || [ "$U" -gt 0 ]; then BR_COLOR="$YELLOW"
  else BR_COLOR="$GREEN"
  fi

  if [ "$DETACHED" = "1" ]; then
    BRANCH_CHUNK="${MAGENTA}⚠ ${NAME}${RESET}"
  else
    BRANCH_CHUNK="🌿 ${BR_COLOR}${NAME}${RESET}"
  fi

  AB=""
  [ "$AHEAD" -gt 0 ] && AB="${AB} ${CYAN}↑${AHEAD}${RESET}"
  [ "$BEHIND" -gt 0 ] && AB="${AB} ${CYAN}↓${BEHIND}${RESET}"

  OP_SEG=""
  [ -n "$OPSTATE" ] && OP_SEG=" ${MAGENTA}[${OPSTATE}]${RESET}"

  DIRTY=""
  [ "$C" -gt 0 ] && DIRTY="${DIRTY} ${BOLDRED}!!${C}${RESET}"
  [ "$S" -gt 0 ] && DIRTY="${DIRTY} ${GREEN}+${S}${RESET}"
  [ "$MOD" -gt 0 ] && DIRTY="${DIRTY} ${YELLOW}~${MOD}${RESET}"
  [ "$DEL" -gt 0 ] && DIRTY="${DIRTY} ${RED}-${DEL}${RESET}"
  [ "$U" -gt 0 ] && DIRTY="${DIRTY} ${BLUE}?${U}${RESET}"

  STASH_SEG=""
  [ "$STASH" -gt 0 ] && STASH_SEG=" ${DIM}·${RESET} ${DIM}📦${STASH}${RESET}"

  GIT_SEG=" ${DIM}·${RESET} ${BRANCH_CHUNK}${AB}${OP_SEG}${DIRTY}${STASH_SEG}"
fi

# --- context bar (scaled to the auto-compact threshold) -----------------------
CTX_INT=${CTX_RAW%.*}; [ -z "$CTX_INT" ] && CTX_INT=0
SCALED=$(( CTX_INT * 100 / COMPACT_AT ))
[ "$SCALED" -gt 100 ] && SCALED=100
FILLED=$(( SCALED / 10 )); EMPTY=$(( 10 - FILLED ))
printf -v FILL "%${FILLED}s"; printf -v PAD "%${EMPTY}s"
BAR="${FILL// /█}${PAD// /░}"
CTX_COLOR=$(pct_color "$SCALED")

# --- usage + reset timer (Pro/Max only; absent otherwise) ---------------------
USAGE_SEG=""
if [ -n "$FIVE_H" ]; then
  fh=${FIVE_H%.*}
  USAGE_SEG="${USAGE_SEG} ${DIM}·${RESET} 5h $(pct_color "$fh")${fh}%%${RESET}"
fi
if [ -n "$RESETS_AT" ]; then
  REM=$(( RESETS_AT - $(date +%s) ))
  if [ "$REM" -gt 0 ]; then
    H=$(( REM / 3600 )); MIN=$(( (REM % 3600) / 60 ))
    USAGE_SEG="${USAGE_SEG} ${DIM}·${RESET} ${DIM}⟳ ${H}h${MIN}m${RESET}"
  fi
fi
if [ -n "$SEVEN_D" ]; then
  sd=${SEVEN_D%.*}
  USAGE_SEG="${USAGE_SEG} ${DIM}·${RESET} 7d $(pct_color "$sd")${sd}%%${RESET}"
fi

# --- effort tag ---------------------------------------------------------------
EFFORT_SEG=""
[ -n "$EFFORT" ] && EFFORT_SEG="${DIM}·${RESET}${MAGENTA}$(printf '%s' "$EFFORT" | tr '[:lower:]' '[:upper:]')${RESET}"

# --- render (two lines) -------------------------------------------------------
printf '%b\n' "${CYAN}${MODEL}${RESET}${EFFORT_SEG}${MODE_SEG}${GIT_SEG}"
printf "${CTX_COLOR}%s${RESET} ${SCALED}%% ctx${USAGE_SEG}\n" "$BAR"

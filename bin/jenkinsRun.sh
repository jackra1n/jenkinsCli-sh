#!/bin/bash  

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$DIR/jenkinsOp.sh"

# ensure gum CLI is available
if ! command -v gum >/dev/null 2>&1; then
  echo "❌  The 'gum' CLI tool is required for this script. Please install it first: https://github.com/charmbracelet/gum" >&2
  exit 1
fi


function renderHealthStatus() {
    local -n JOBS_ARRAY="$1"
    local BRANCH="$2"

    local TERM_WIDTH=$(tput cols 2>/dev/null || echo 100)
    local CONTENT_WIDTH=$((TERM_WIDTH - 6))  # account for border and padding
    
    # find the longest job name for consistent alignment
    local MAX_JOB_LENGTH=0
    for JOB_ENTRY in "${JOBS_ARRAY[@]}"; do
        local JOB_NAME="${JOB_ENTRY%...*}"
        local JOB_LENGTH=${#JOB_NAME}
        if [ $JOB_LENGTH -gt $MAX_JOB_LENGTH ]; then
            MAX_JOB_LENGTH=$JOB_LENGTH
        fi
    done
    
    # handle very long job names
    if [ $MAX_JOB_LENGTH -lt 20 ]; then
        MAX_JOB_LENGTH=20
    elif [ $MAX_JOB_LENGTH -gt $((CONTENT_WIDTH - 15)) ]; then
        MAX_JOB_LENGTH=$((CONTENT_WIDTH - 15))
    fi

    local CONTENT=""
    local HEADER="Jenkins Health Status - Branch: ${C_GREEN}${BRANCH}${C_OFF}"
    CONTENT+="${HEADER}\n\n"

    for JOB_ENTRY in "${JOBS_ARRAY[@]}"; do
        local JOB_NAME="${JOB_ENTRY%...*}"
        local STATUS_INDICATOR="${JOB_ENTRY#*...}"
        
        # cut off job name if too long
        if [ ${#JOB_NAME} -gt $MAX_JOB_LENGTH ]; then
            JOB_NAME="${JOB_NAME:0:$((MAX_JOB_LENGTH-3))}..."
        fi
        
        # format with consistent spacing
        printf -v FORMATTED_LINE "%-${MAX_JOB_LENGTH}s  %s" "$JOB_NAME" "$STATUS_INDICATOR"
        CONTENT+="${FORMATTED_LINE}\n"
    done
    
    # remove trailing newline
    CONTENT="${CONTENT%\\n}"

    echo -e "$CONTENT" | gum style \
        --border rounded \
        --border-foreground 4 \
        --padding "1 2" \
        --margin "1 0" \
        --width "$CONTENT_WIDTH"
}

function health(){
    BRANCH=$1
    BRANCH_ENCODED=`encodeForDownload $BRANCH`
    local JOBS=( $(getAvailableTestJobs) )
    for JB in ${JOBS[*]}; do
        printf "%s ... %s\n" "$JB" "$(getHealth ${JB} ${BRANCH_ENCODED})"
    done
}

function triggerBuilds() {
  local BRANCH="$1"
  local JOBS=( $(getAvailableTestJobs) )

  while true; do
    local COLOR_BRANCH="${C_GREEN}${BRANCH}${C_OFF}"

    if [ "$HEALTH" == "true" ]; then
      gum style --bold --foreground 3 "Getting health of ${COLOR_BRANCH}"
      FORCE_COLORS=true watch --color -d "${DIR}/jenkinsRun.sh health '${BRANCH}'"
    else
      gum style --bold --foreground 2 "Triggering builds for ${COLOR_BRANCH}"
      SEL_JOBS=${JOBS[@]}
    fi

    # reset flags each iteration
    HEALTH="false"
    FILTERED="true"

    local PRE_ACTIONS=('!leave:exit' '!health' '!getDesigner' '!getEngine')
    local POST_ACTIONS=('!new_view')
    if ! [ -z "${JOB_FILTER}" ]; then
      POST_ACTIONS+=("...more")
    fi

    local OPTIONS=( "${PRE_ACTIONS[@]}" ${SEL_JOBS[@]} "${POST_ACTIONS[@]}" )

    local LINES=$(tput lines)
    local RUN
    RUN=$(gum choose --height $((LINES-5)) "${OPTIONS[@]}")

    # User aborted selection
    if [ -z "$RUN" ]; then
      break
    fi

    local BRANCH_ENCODED=$(encodeForDownload "$BRANCH")

    case "$RUN" in
      "!leave:exit") break ;;
      "!health") HEALTH="true" ;;
      "!getDesigner")
        echo "$($DIR/newDesigner.sh "$BRANCH_ENCODED")" ;;
      "!getEngine")
        echo "$($DIR/newEngine.sh "$BRANCH_ENCODED")" ;;
      "!new_view")
        createView "$BRANCH" ;;
      "...more")
        FILTERED="false"
        export JOB_FILTER="" ;;
      *)
        local JOB_RAW=$(sed 's|\.\.\..*||' <<< "$RUN")
        triggerBuild "$JOB_RAW" "$BRANCH_ENCODED" ;;
    esac

    # decide whether to prompt again
    if [ "$HEALTH" == "true" ] || [ "$FILTERED" == "false" ]; then
      continue
    else
      break
    fi
  done
}



function noColor(){
  echo -E $1 | sed -E "s/\x1B\[(([0-9]{1,2})?(;)?([0-9]{1,2})?)?[m,K,H,f,J]//g"
}

function goodbye(){
  printf "\nHave a nice day! 👍"
  inspire
}

function inspire(){
  JSON=$(curl -sS https://thatsthespir.it/api)
  QUOTE=$(jsonField "${JSON}" "quote")
  AUTHOR=$(jsonField "${JSON}" "author")
  LINK=$(jsonField "${JSON}" "id" )
  printf "\n\n$(tput bold setaf 4)${QUOTE}${C_OFF}
$(tput setaf 5)${AUTHOR} $(tput setaf 6)https://thatsthespir.it/${LINK}${C_OFF}"
}

function branches() {
  local BRANCHES_RAW=$( getAvailableBranches )
  local GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  local BRANCHES_COLORED=$(grep -C 100 --color=always -E "${GIT_BRANCH}|master" <<< "${BRANCHES_RAW[@]}")
  if [[ -z "$BRANCHES_COLORED" ]]; then
    BRANCHES_COLORED="${BRANCHES_RAW[@]}" #all without highlight: local 'only' branch.
  fi
  echo "${BRANCHES_COLORED[@]}"
}

function chooseBranch() {
  BRANCHES_COLORED=$(branches)
  local POST_OPTIONS=()
  if ! [ -z "${BRANCH_FILTER}" ]; then
    POST_OPTIONS+=('...more')
  fi
  local OPTIONS=( '!re-scan' '!exit' ${BRANCHES_COLORED[@]} ${POST_OPTIONS[@]} )

  echo "SELECT branch of $(origin)"
  LINES=$(tput lines)
  OPTION=$(gum choose --height $(($LINES-5)) "${OPTIONS[@]}")
  case $OPTION in 
      "!re-scan")
          echo 're-scanning [beta]'
          rescanBranches
          chooseBranch
          return ;;
      "...more")
          echo 'revealing default-filtered branches'
          BRANCH_FILTER=""
          chooseBranch
          return ;;
      "!exit")
          return ;;
      *)
          BRANCH=$(noColor "${OPTION}")
          triggerBuilds ${BRANCH}
          return ;;
  esac
}

if [[ "$1" == "health" ]]; then
  health "$2"
  exit
fi

if [[ "$1" != "test" ]]; then
  trap goodbye EXIT
  chooseBranch
fi


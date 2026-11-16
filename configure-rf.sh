#!/bin/bash

# VERSION=2026.11.16.2

#set -euo pipefail

# ./configure-rf.sh [-y|--non-interactive] [--yes] [--ui auto|plain|tui]
#                   [--plan|--validate-only] [--docker-mode group|rootless|manual]
#                   [--set KEY=VALUE ...]

# Preserve the original single-file installation command. A standalone copy of
# configure-rf.sh bootstraps the latest checksummed public release, then starts
# the installed configurator. No GitHub login is required.
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$BOOTSTRAP_DIR/shared_functions.sh" ]]; then
  command -v curl >/dev/null || { echo "curl is required to install Remote Falcon." >&2; exit 1; }
  bootstrap_installer=$(mktemp)
  trap 'rm -f "$bootstrap_installer"' EXIT
  curl -fsSL --retry 3 -o "$bootstrap_installer" \
    https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/install.sh
  bash "$bootstrap_installer" --target "$BOOTSTRAP_DIR" --no-configure
  trap - EXIT
  rm -f "$bootstrap_installer"
  exec "$BOOTSTRAP_DIR/configure-rf.sh" "$@"
fi

NON_INTERACTIVE=false
ASSUME_YES=false
DOCKER_MODE="${RF_DOCKER_MODE:-group}"
DEBUG_INPUT=false # Used to debug input parsing when running in NON_INTERACTIVE mode
UI_MODE="${RF_CONFIGURE_UI:-auto}"
PLAN_ONLY=false
VALIDATE_ONLY=false
ROTATE_JWT=false
MAIN_PID="$$"
TUI_PROMPT_TITLE="Remote Falcon Configuration"

declare -A OVERRIDES=()
declare -a original_keys=()

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y)
      # Backward-compatible automation mode: no prompts and approve the plan.
      NON_INTERACTIVE=true
      ASSUME_YES=true
      shift
      ;;
    --non-interactive)
      # Use overrides/current defaults without approving changes implicitly.
      NON_INTERACTIVE=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --ui)
      if [[ -z "${2-}" ]]; then
        echo "Error: --ui requires auto, plain, or tui" >&2
        exit 2
      fi
      UI_MODE="$2"
      shift 2
      ;;
    --ui=*)
      UI_MODE="${1#--ui=}"
      shift
      ;;
    --plan|--dry-run)
      PLAN_ONLY=true
      shift
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      NON_INTERACTIVE=true
      shift
      ;;
    --rotate-jwt)
      ROTATE_JWT=true
      shift
      ;;
    --docker-mode)
      if [[ -z "${2-}" ]]; then
        echo "Error: --docker-mode requires group, rootless, or manual" >&2
        exit 2
      fi
      DOCKER_MODE="${2:-}"
      shift 2
      ;;
    --docker-mode=*)
      DOCKER_MODE="${1#--docker-mode=}"
      shift
      ;;
    --set)
      # support: --set KEY=VALUE  (argument form)
      if [[ -n "${2-}" && "${2}" == *=* ]]; then
        kv="$2"
        shift 2
      else
        echo "Error: --set requires KEY=VALUE" >&2
        exit 2
      fi
      key="${kv%%=*}"
      val="${kv#*=}"
      OVERRIDES["$key"]="$val"
      ;;
    --set=*)
      # support: --set=KEY=VALUE  (equals form)
      kv="${1#--set=}"
      shift
      key="${kv%%=*}"
      val="${kv#*=}"
      OVERRIDES["$key"]="$val"
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo
      echo "Options:"
      echo "  -y                        Legacy unattended mode (non-interactive + --yes)"
      echo "  --non-interactive         Use overrides/current defaults without prompts"
      echo "  --yes                     Approve the reviewed execution plan"
      echo "  --ui MODE                 Interface: auto (default), plain, or tui"
      echo "  --plan, --dry-run         Review changes/actions without applying them"
      echo "  --validate-only           Validate the current .env and exit"
      echo "  --rotate-jwt              Explicitly rotate the control-panel JWT signing key"
      echo "  --docker-mode MODE        Docker access: group (default), rootless, or manual"
      echo "  --set KEY=VALUE           Set configuration override for config questions(can be used multiple times)"
      echo "  -h, --help                Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 2
      ;;
  esac
done

case "$UI_MODE" in
  auto|plain|tui) ;;
  *) echo "Error: invalid --ui mode '$UI_MODE'. Use auto, plain, or tui." >&2; exit 2 ;;
esac

READ_ONLY_MODE=false
DEFER_PREREQUISITES=true
if [[ "$PLAN_ONLY" == "true" || "$VALIDATE_ONLY" == "true" ]]; then
  READ_ONLY_MODE=true
fi

if [ "${DEBUG_INPUT:-false}" = true ] ; then
  echo "--------------------------------------------"
  echo "⚙️  Arg Parse Debug (stderr):"
  echo "  NON_INTERACTIVE=$NON_INTERACTIVE" >&2
  for k in "${!OVERRIDES[@]}"; do
    echo "  OVERRIDE: $k=[redacted]" >&2
  done
  echo "--------------------------------------------" >&2
fi

# Files come from a verified public release installed into this checkout.
SERVICES=(external-api ui plugins-api viewer control-panel cloudflared nginx mongo versitygw)
ANY_SERVICE_RUNNING=false
declare -A PENDING_COMPOSE_TAGS=()
declare -A PENDING_COMPOSE_OLD_TAGS=()
TEMPLATE_REPO="Ne0n09/remote-falcon-image-builder" # Template repo for image builder workflows

# new_build_args array to track if any build args changed that would require RF container rebuild
# For GHCR builds these get synced with sync_repo_secrets.sh
# "CONTROL_PANEL_API" "VIEWER_API" not included because we only want to track if DOMAIN is changed
#### This will need to be updated down in update_env() if any new build context args are added - sync_repo_secrets will also need to be updated

# Required companion files are installed together by install.sh.
download_file() {
  local filename=$1

  if [ ! -f "$filename" ]; then
    if [[ "$filename" == ".env" && -f .env.example ]]; then
      (umask 077; cp .env.example .env)
      echo -e "✔ ${GREEN}Created .env from the local example.${NC}"
      return
    fi
    echo -e "${RED}❌ Missing $filename. Run ./install.sh to restore the verified release.${NC}" >&2
    exit 1
  fi
}

echo -e "${BLUE}⚙️ Running ${RED}RF${NC} configuration script...${NC}"

# Download and source shared functions
download_file "shared_functions.sh"
[[ "$READ_ONLY_MODE" == "false" ]] && chmod +x "shared_functions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/shared_functions.sh" ]]; then
  echo -e "${RED}❌ ERROR: shared_functions.sh does not exist in $SCRIPT_DIR.${NC}"
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared_functions.sh"

# Configuration metadata is shared by the plain prompt, TUI, review, and plan
# output so secret handling and rebuild behavior are defined in one place.
declare -A CONFIG_SECTION=()
declare -A CONFIG_LABEL=()
declare -A CONFIG_SECRET=()
declare -A CONFIG_REBUILD=()

register_config_field() {
  local key="$1" section="$2" label="$3" secret="${4:-false}" rebuild="${5:-false}"
  CONFIG_SECTION["$key"]="$section"
  CONFIG_LABEL["$key"]="$label"
  CONFIG_SECRET["$key"]="$secret"
  CONFIG_REBUILD["$key"]="$rebuild"
}

register_config_field DOMAIN required "Domain" false true
register_config_field TUNNEL_TOKEN cloudflare "Cloudflare tunnel token" true false
register_config_field CF_API_TOKEN cloudflare "Cloudflare API token" true false
register_config_field AUTO_VALIDATE_EMAIL required "Automatic email validation" false false
register_config_field SEQUENCE_LIMIT optional "Sequence limit" false false
register_config_field SWAP_CP optional "Swap control-panel and viewer URLs" false true
register_config_field VIEWER_PAGE_SUBDOMAIN optional "Viewer subdomain" false true
register_config_field PROTOMAPS_API_KEY maps "Protomaps API key" true true
register_config_field MAP_STYLE_LIGHT maps "Light map style" false true
register_config_field MAP_STYLE_DARK maps "Dark map style" false true
register_config_field PUBLIC_POSTHOG_KEY analytics "PostHog project key" true true
register_config_field POSTHOG_CLI_API_KEY analytics "PostHog CLI key" true true
register_config_field GA_TRACKING_ID analytics "Google Analytics ID" false true
register_config_field MIXPANEL_KEY analytics "Mixpanel key" true true
register_config_field GITHUB_PAT legacy "GitHub token" true false
register_config_field USER_JWT_KEY security "User JWT signing key" true false

is_secret_key() {
  local key="$1"
  [[ "${CONFIG_SECRET[$key]:-false}" == "true" ]] ||
    [[ "$key" == *TOKEN* || "$key" == *PAT* || "$key" == *PASSWORD* ||
       "$key" == *SECRET* || "$key" == *PRIVATE* || "$key" == *JWT* || "$key" == *KEY* ]]
}

cancel_configuration() {
  echo -e "${YELLOW}Configuration cancelled. No further actions will run; review the log for any already-completed steps.${NC}" >&2
  exit 130
}

TEMP_FILES=()
cleanup_configuration_temps() {
  local path
  for path in "${TEMP_FILES[@]}"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
}

trap cleanup_configuration_temps EXIT
trap cancel_configuration TERM

initialize_ui() {
  local tui_capable=false
  if [[ -t 0 && -t 1 && "${TERM:-dumb}" != "dumb" ]] &&
     command -v whiptail >/dev/null 2>&1 && command -v tput >/dev/null 2>&1 &&
     tput clear >/dev/null 2>&1 && tput cup 0 0 >/dev/null 2>&1; then
    tui_capable=true
  fi
  case "$UI_MODE" in
    auto)
      if [[ "$NON_INTERACTIVE" == "false" && "$tui_capable" == "true" ]]; then
        UI_MODE=tui
      else
        UI_MODE=plain
      fi
      ;;
    tui)
      if [[ "$tui_capable" != "true" ]]; then
        echo -e "${RED}❌ --ui tui requires whiptail and an interactive terminal with cursor support. Use --ui plain for this terminal.${NC}" >&2
        exit 2
      fi
      ;;
  esac

  if [[ "$UI_MODE" == "tui" ]]; then
    if [[ -n "${RF_TUI_COLORS:-}" ]]; then
      NEWT_COLORS="$RF_TUI_COLORS"
    elif [[ -z "${NEWT_COLORS:-}" ]]; then
      NEWT_COLORS='root=white,black
window=white,black
shadow=black,black
border=red,black
title=red,black
button=black,red
actbutton=white,red
checkbox=white,black
actcheckbox=red,black
entry=white,black
label=white,black
listbox=white,black
actlistbox=white,red
textbox=white,black
acttextbox=white,black
compactbutton=white,black
sellistbox=white,black
actsellistbox=white,red'
    fi
    export NEWT_COLORS
  fi
}

initialize_ui

show_tui_section() {
  local title="$1" message="$2" height="${3:-15}" width="${4:-78}"
  [[ "$UI_MODE" == "tui" ]] || return 0
  whiptail --title "$title" --msgbox "$message" "$height" "$width" 1>&2 || {
    kill -TERM "$MAIN_PID"
    return 130
  }
}

show_configuration_notice() {
  local title="$1" message="$2" height="${3:-13}" width="${4:-82}"
  if [[ "$UI_MODE" == "tui" ]]; then
    whiptail --title "$title" --msgbox "$message" "$height" "$width" 1>&2 || {
      kill -TERM "$MAIN_PID"
      return 130
    }
  else
    echo -e "${CYAN}ℹ️ ${message}${NC}"
  fi
}

configured_status() {
  local value="${1:-}" placeholder="${2:-}"
  if [[ -z "$value" || ( -n "$placeholder" && "$value" == "$placeholder" ) ]]; then
    printf '[not configured]'
  else
    printf '[configured]'
  fi
}

summary_value() {
  local value="${1:-}" placeholder="${2:-}"
  if [[ -z "$value" || ( -n "$placeholder" && "$value" == "$placeholder" ) ]]; then
    printf '[not configured]'
  elif (( ${#value} > 48 )); then
    printf '%s...' "${value:0:45}"
  else
    printf '%s' "$value"
  fi
}

review_env_value() {
  local key="$1" value="$2" displayed
  displayed=$(display_env_value "$key" "$value")
  [[ -n "$displayed" ]] || displayed="[empty]"
  printf '%s' "$displayed"
}

optional_settings_summary() {
  local url_layout message
  if [[ "${SWAP_CP:-false}" == "true" ]]; then
    url_layout="Viewer: https://${DOMAIN}"
  else
    url_layout="Control Panel: https://${DOMAIN}"
  fi

  printf -v message '%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s\n%-28s %s' \
    "Setting" "Current value" \
    "----------------------------" "---------------------------------------------" \
    "Sequence limit" "${SEQUENCE_LIMIT:-[not configured]}" \
    "URL layout" "$url_layout" \
    "Viewer subdomain" "${VIEWER_PAGE_SUBDOMAIN:-[not configured]}" \
    "Protomaps API key" "$(configured_status "${PROTOMAPS_API_KEY:-}")" \
    "Light map style" "$(summary_value "${MAP_STYLE_LIGHT:-}")" \
    "Dark map style" "$(summary_value "${MAP_STYLE_DARK:-}")" \
    "Social sharing metadata" "$(configured_status "${SOCIAL_META:-}")" \
    "PostHog analytics" "$(configured_status "${PUBLIC_POSTHOG_KEY:-}")" \
    "Google Analytics" "$(summary_value "${GA_TRACKING_ID:-}" '1')" \
    "Mixpanel analytics" "$(configured_status "${MIXPANEL_KEY:-}")"

  printf '%s\n\n%s' \
    "You can keep every current value in this section. Sensitive or long metadata values are summarized." \
    "$message"
}

prompt_optional_settings_update() {
  local message rc=0
  message="$(optional_settings_summary)"$'\n\nUpdate optional settings?'

  if [[ "$UI_MODE" == "tui" ]]; then
    if whiptail --title "Step 2: Optional settings" --defaultno --yesno "$message" 27 104 1>&2; then
      printf 'y'
      return 0
    else
      rc=$?
    fi
    [[ $rc -eq 1 ]] && { printf 'n'; return 0; }
    kill -TERM "$MAIN_PID"
    return 130
  fi

  printf '\n%s\n\n' "$(optional_settings_summary)" >&2
  get_input "❓ Update OPTIONAL variables? (y/n)" "n"
}

cloudflare_token_guidance() {
  local dashboard_url="https://dash.cloudflare.com/profile/api-tokens"
  local docs_url="https://ne0n09.github.io/cloudflared-remotefalcon/install/cloudflare/"
  printf '%s\n' "Automatic Cloudflare setup requires a custom API token, or you can leave this blank to configure Cloudflare manually.

See step-by-step instructions for both options:
$docs_url

Tip: Ctrl+click a URL in most terminal applications to open the link.

Steps to create a custom API token for automatic Cloudflare setup:
  1. Go to $dashboard_url
  2. Click Create Token.
  3. Click Get Started beside Create Custom Token.
  4. Name the token 'Remote Falcon Setup'.
  5. Configure the token with the settings below.

Permissions:
  Account  Cloudflare Tunnel      Edit (create and configure tunnels)
  Account  Account Settings       Read (retrieve the Account ID)
  Zone     Zone                   Edit (add domains to Cloudflare)
  Zone     DNS                    Edit (create DNS records)
  Zone     SSL and Certificates   Edit (configure SSL and create origin certificates)

Account Resources:
  Include all accounts, or select a specific account.

Zone Resources:
  All zones (recommended), or all zones from an account.

  6. Click Continue to summary.
  7. Click Create Token.
  8. Copy and paste the token below. Input is hidden."
}

manual_origin_certificate_guidance() {
  local docs_url="https://ne0n09.github.io/cloudflared-remotefalcon/install/cloudflare/#manual-configuration"
  printf '%s\n' "No origin certificate and private key were found.

Manual certificate entry will be added to the execution plan. After you review and approve the plan, Nano will open twice.

  1. Paste the Cloudflare origin certificate.
  2. Paste the matching private key.

Nothing will be opened before final approval.

Review the manual configuration instructions:
$docs_url

Tip: Ctrl+click a URL in most terminal applications to open the link."
}

# Download extra helper scripts if they do not exist and make them executable
download_file "update_containers.sh"
download_file "health_check.sh"
download_file "mongo_init.sh"
download_file "versitygw_init.sh"
download_file "setup_cloudflare.sh"
download_file "run_workflow.sh"
download_file "sync_repo_secrets.sh"
if [[ "$READ_ONLY_MODE" == "false" ]]; then
  chmod +x "shared_functions.sh" "update_containers.sh" "health_check.sh" "mongo_init.sh" "versitygw_init.sh" "setup_cloudflare.sh" "run_workflow.sh" "sync_repo_secrets.sh"
fi

# Read a secret while showing visible progress without revealing its value.
read_masked_input() {
  local prompt="$1"
  local input=""
  local character=""

  printf '%s' "$prompt" >&2
  while IFS= read -r -s -n 1 character; do
    if [[ -z "$character" ]]; then
      break
    fi
    case "$character" in
      $'\177'|$'\b')
        if [[ -n "$input" ]]; then
          input="${input%?}"
          printf '\b \b' >&2
        fi
        ;;
      *)
        input+="$character"
        printf '*' >&2
        ;;
    esac
  done
  printf '\n' >&2
  printf '%s' "$input"
}

# Function to get user input for configuration questions in the format of get_input KEY PROMPT DEFAULT
get_input() {
  local key=""
  local prompt=""
  local default=""
  local input=""

  # Detect args
  if [ $# -eq 3 ]; then
    key="$1"; prompt="$2"; default="$3"
  elif [ $# -eq 2 ]; then
    key=""; prompt="$1"; default="$2"
  else
    printf '%s\n' "get_input: invalid number of arguments" >&2
    return 1
  fi

  # Answer prompts from overrides/current values. Approval is independent from
  # non-interactive input; -y remains the compatibility shorthand for both.
  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    if [ -n "$key" ] && [ -n "${OVERRIDES[$key]+set}" ]; then
      input="${OVERRIDES[$key]}"
    else
      if [[ "$ASSUME_YES" == "true" && "$prompt" =~ \([Yy]/[Nn]\) ]]; then
        input="y"
      else
        input="$default"
      fi
    fi

    # Log automated input to console
    printf '%s\n' "⚙️: $prompt [$(display_env_value "$key" "$default")]: $(display_env_value "$key" "$input")" >&2

    printf '%s' "$input"
    return 0
  fi

  if [[ "${UI_MODE:-plain}" == "tui" ]]; then
    local title="${TUI_PROMPT_TITLE:-Remote Falcon Configuration}"
    local rc=0
    local dialog_height=12
    local dialog_width=78
    if [[ "$prompt" =~ \([Yy]/[Nn]\) ]]; then
      # get_input is normally called through command substitution. whiptail
      # draws yes/no dialogs on stdout, so route the dialog to the terminal
      # instead of letting the command substitution capture it invisibly.
      local -a yesno_args=(--title "$title")
      [[ "$default" =~ ^[Nn]$ ]] && yesno_args+=(--defaultno)
      if whiptail "${yesno_args[@]}" --yesno "$prompt" 12 78 1>&2; then
        printf 'y'
        return 0
      else
        rc=$?
        [[ $rc -eq 1 ]] && { printf 'n'; return 0; }
        kill -TERM "$MAIN_PID"
        return 130
      fi
    fi

    if is_secret_key "$key"; then
      local secret_hint="Input is hidden while you type."
      local dialog_prompt="$prompt"
      dialog_height=14
      dialog_width=84
      if [[ "$key" == "CF_API_TOKEN" ]]; then
        secret_hint="Leave blank to configure Cloudflare manually."
      elif [[ -n "$default" && "$default" != "cloudflare_token" && "$default" != "123456" ]]; then
        secret_hint="A value is already configured. Leave blank to keep it."
      fi
      if [[ "$key" == "CF_API_TOKEN" ]]; then
        title="Cloudflare API token"
        dialog_prompt="$(cloudflare_token_guidance)

$prompt"
        dialog_height=38
        dialog_width=118
      fi
      input=$(whiptail --title "$title" --passwordbox \
        "$dialog_prompt\n\n$secret_hint" "$dialog_height" "$dialog_width" 3>&1 1>&2 2>&3) || rc=$?
    else
      if [[ "$key" == "SWAP_CP" ]]; then
        dialog_height=18
        dialog_width=104
      fi
      input=$(whiptail --title "$title" --inputbox "$prompt" "$dialog_height" "$dialog_width" "$default" 3>&1 1>&2 2>&3) || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
      kill -TERM "$MAIN_PID"
      return 130
    fi
    if [[ "$key" == "CF_API_TOKEN" ]]; then
      printf '%s' "$input"
    else
      printf '%s' "${input:-$default}"
    fi
    return 0
  fi

  # Plain interactive mode.
  if { declare -F is_secret_key >/dev/null 2>&1 && is_secret_key "$key"; } ||
     [[ "$key" == *TOKEN* || "$key" == *PAT* || "$key" == *PASSWORD* ||
        "$key" == *SECRET* || "$key" == *PRIVATE* || "$key" == *JWT* || "$key" == *KEY* ]]; then
    if [[ "$key" == "CF_API_TOKEN" ]]; then
      printf '\n%s\n\n' "$(cloudflare_token_guidance)" >&2
    fi
    input=$(read_masked_input "$prompt [configured value hidden]: ")
  else
    read -rp "$prompt [$default]: " input
  fi
  if [[ "$key" == "CF_API_TOKEN" ]]; then
    printf '%s' "$input"
  else
    printf '%s' "${input:-$default}"
  fi
}

show_execution_plan() {
  local pending_arg_changes="$1"
  local review_details="${2:-}" validated_variables="${3:-}"
  local item service plan_message="" decision="" rc=0 action_number=1
  local plan_warning=""
  local -a plan_items=()

  [[ "$PENDING_DOCKER_INSTALL" == "true" ]] && plan_items+=("Install Docker Engine and the Compose plugin.")
  [[ "$PENDING_DOCKER_GROUP" == "true" ]] && plan_items+=("Add the current user to the docker group, then stop for a new login.")
  [[ "$PENDING_JQ_INSTALL" == "true" ]] && plan_items+=("Install jq.")
  [[ "$PENDING_GH_INSTALL" == "true" ]] && plan_items+=("Install GitHub CLI for the legacy private image-builder workflow.")
  [[ "$PENDING_CLOUDFLARE_SETUP" == "true" ]] && plan_items+=("Configure the Cloudflare tunnel, DNS, and origin certificates.")
  [[ "$PENDING_CERT_UPDATE" == "true" ]] && plan_items+=("Open the configured editor for the origin certificate and private key.")
  [[ ${#PENDING_COMPOSE_TAGS[@]} -gt 0 ]] && plan_items+=("Align ${#PENDING_COMPOSE_TAGS[@]} Compose image tag(s) with the running deployment.")
  plan_items+=("Back up, validate, and atomically replace .env.")
  plan_items+=("Initialize or preserve MongoDB root and application credentials.")
  if [[ "$ANY_SERVICE_RUNNING" == "false" ]]; then
    plan_items+=("Check every container version, replace any latest tags in Compose with concrete versions, pull the four coordinated backend images, build the deployment-specific UI, and start the Remote Falcon stack.")
    plan_items+=("Initialize or preserve VersityGW credentials, bucket, and public policy, then run full health checks.")
  elif [[ "$pending_arg_changes" == "true" ]]; then
    plan_items+=("Rebuild the deployment-specific UI and recreate the existing stack to apply build-argument changes.")
  else
    plan_items+=("Recreate running services only when runtime values changed.")
  fi
  [[ "$ROTATE_JWT" == "true" ]] && plan_warning="WARNING: Rotate the user JWT signing key and invalidate active control-panel sessions."

  if [[ "$UI_MODE" == "tui" ]]; then
    plan_message="Review the detected corrections, proposed values, and actions before applying changes."$'\n\n'

    if [[ ${#PENDING_COMPOSE_TAGS[@]} -gt 0 ]]; then
      plan_message+="Compose tag corrections (${#PENDING_COMPOSE_TAGS[@]}):"$'\n  '
      local correction_separator=""
      for service in "${SERVICES[@]}"; do
        if [[ -v PENDING_COMPOSE_TAGS[$service] ]]; then
          plan_message+="${correction_separator}$service: ${PENDING_COMPOSE_OLD_TAGS[$service]:-unknown} -> ${PENDING_COMPOSE_TAGS[$service]}"
          correction_separator="; "
        fi
      done
      plan_message+=$'\n\n'
    fi

    if [[ -n "$review_details" ]]; then
      plan_message+="Proposed .env changes:"$'\n'
      plan_message+="$review_details"$'\n'
    else
      plan_message+="Proposed .env changes: none"$'\n\n'
    fi

    [[ -n "$validated_variables" ]] && plan_message+="Validation: passed"$'\n\n'

    plan_message+="Execution actions:"$'\n'
    for item in "${plan_items[@]}"; do
      plan_message+="  $action_number. $item"$'\n'
      ((action_number++))
    done
    [[ -n "$plan_warning" ]] && plan_message+=$'\n'"$plan_warning"$'\n'
    plan_message+=$'\nChoose an action with the Up/Down arrow keys, then press Enter.'
    if [[ "$PLAN_ONLY" == "true" ]]; then
      whiptail --title "Review changes and execution plan" --msgbox "$plan_message" 29 100 1>&2 || {
        kill -TERM "$MAIN_PID"
        return 130
      }
      return 0
    fi
    while true; do
      rc=0
      decision=$(whiptail --title "Review changes and execution plan" --notags --menu \
        "$plan_message\n\nSelect one action before continuing:" 32 104 3 \
        "choose" "Choose an action..." \
        "apply" "Apply the reviewed execution plan" \
        "do-not-apply" "Do not apply changes" \
        3>&1 1>&2 2>&3) || rc=$?
      if [[ $rc -ne 0 ]]; then
        kill -TERM "$MAIN_PID"
        return 130
      fi
      case "$decision" in
        apply) return 0 ;;
        do-not-apply) return 1 ;;
        *)
          whiptail --title "Selection required" --msgbox \
            "Select Apply or Do not apply before continuing." 9 64 1>&2 || {
              kill -TERM "$MAIN_PID"
              return 130
            }
          ;;
      esac
    done
  fi

  echo
  echo -e "${CYAN}Execution plan${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  action_number=1
  for item in "${plan_items[@]}"; do
    printf '  %d. %s\n' "$action_number" "$item"
    ((action_number++))
  done
  [[ -n "$plan_warning" ]] && printf '\n  %s\n' "$plan_warning"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

run_as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || {
      echo -e "${RED}❌ sudo is required to install approved prerequisites.${NC}" >&2
      return 1
    }
    sudo "$@"
  fi
}

apply_pending_prerequisites() {
  if [[ "$PENDING_DOCKER_INSTALL" == "true" ]]; then
    [[ -r /etc/os-release ]] || { echo -e "${RED}❌ Cannot identify this Linux distribution.${NC}" >&2; return 1; }
    # shellcheck source=/dev/null
    source /etc/os-release
    case "$ID" in
      ubuntu|debian) ;;
      *) echo -e "${RED}❌ Automatic Docker installation supports only Ubuntu and Debian.${NC}" >&2; return 1 ;;
    esac
    echo -e "${CYAN}🐳 Installing approved Docker prerequisites for $ID...${NC}"
    run_as_root apt-get update || return 1
    run_as_root apt-get install -y ca-certificates curl || return 1
    run_as_root install -m 0755 -d /etc/apt/keyrings || return 1
    local docker_key
    docker_key=$(mktemp) || return 1
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o "$docker_key" || { rm -f "$docker_key"; return 1; }
    run_as_root install -m 0644 "$docker_key" /etc/apt/keyrings/docker.asc || { rm -f "$docker_key"; return 1; }
    rm -f "$docker_key"
    local architecture repository
    architecture=$(dpkg --print-architecture)
    repository="deb [arch=$architecture signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable"
    printf '%s\n' "$repository" | run_as_root tee /etc/apt/sources.list.d/docker.list >/dev/null || return 1
    run_as_root apt-get update || return 1
    run_as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    command -v docker >/dev/null 2>&1 || return 1
    [[ $EUID -ne 0 && "$DOCKER_MODE" == "group" ]] && PENDING_DOCKER_GROUP=true
  fi

  if [[ "$PENDING_JQ_INSTALL" == "true" ]]; then
    run_as_root apt-get update && run_as_root apt-get install -y jq || return 1
  fi

  if [[ "$PENDING_GH_INSTALL" == "true" ]]; then
    ensure_legacy_github_cli || return 1
  fi

  if [[ "$PENDING_DOCKER_GROUP" == "true" ]]; then
    echo -e "${YELLOW}⚠️ Docker group membership grants root-level privileges on this host.${NC}"
    run_as_root groupadd --force docker || return 1
    run_as_root usermod -aG docker "$USER" || return 1
    echo -e "${GREEN}✔ Added '$USER' to the docker group.${NC}"
    echo "Log out and back in, then rerun ./configure-rf.sh. No Remote Falcon configuration was changed."
    exit 2
  fi
}

apply_pending_external_configuration() {
  if [[ "$PENDING_CLOUDFLARE_SETUP" == "true" ]]; then
    echo -e "${CYAN}☁️ Applying approved Cloudflare configuration...${NC}"
    bash "$SCRIPT_DIR/setup_cloudflare.sh" -y --domain "$DOMAIN" --api-token "$CF_API_TOKEN" || {
      echo -e "${RED}❌ Cloudflare configuration failed; the new .env was not installed.${NC}" >&2
      return 1
    }
    [[ -s tunnel_token.txt ]] || {
      echo -e "${RED}❌ Cloudflare setup did not produce tunnel_token.txt.${NC}" >&2
      return 1
    }
    TUNNEL_TOKEN=$(<tunnel_token.txt)
    [[ -s "${DOMAIN}_origin_cert.pem" && -s "${DOMAIN}_origin_key.pem" ]] && ORIGIN_CERTS_CONFIGURED_BY_SETUP=true
  fi

  if [[ "$PENDING_CERT_UPDATE" == "true" && "$ORIGIN_CERTS_CONFIGURED_BY_SETUP" != "true" ]]; then
    local editor="${EDITOR:-nano}"
    local editor_name="${editor##*/}"
    local certificate_prompt="Paste the origin certificate. Save and exit the editor when finished."
    local private_key_prompt="Paste the origin private key. Save and exit the editor when finished."
    command -v "$editor" >/dev/null 2>&1 || {
      echo -e "${RED}❌ Editor '$editor' was not found. Set EDITOR to an installed command.${NC}" >&2
      return 1
    }
    if [[ "$editor_name" == "nano" ]]; then
      certificate_prompt="Paste the origin certificate. Ctrl+X, y, and ENTER to save."
      private_key_prompt="Paste the origin private key. Ctrl+X, y, and ENTER to save."
    fi
    if [[ "$UI_MODE" == "tui" ]]; then
      whiptail --title "Origin certificate" --msgbox "$certificate_prompt" 10 78
    else
      read -rp "$certificate_prompt Press ENTER to open $editor."
    fi
    "$editor" "${DOMAIN}_origin_cert.pem" || return 1
    if [[ "$UI_MODE" == "tui" ]]; then
      whiptail --title "Origin private key" --msgbox "$private_key_prompt" 10 78
    else
      read -rp "$private_key_prompt Press ENTER to open $editor."
    fi
    "$editor" "${DOMAIN}_origin_key.pem" || return 1
    [[ -s "${DOMAIN}_origin_cert.pem" && -s "${DOMAIN}_origin_key.pem" ]] || {
      echo -e "${RED}❌ Origin certificate and key must both be non-empty.${NC}" >&2
      return 1
    }
    chmod 600 "${DOMAIN}_origin_key.pem"
  fi
}

write_env_atomically() {
  local map_name="$1"
  local -n values="$map_name"
  local updates candidate key
  local -A emitted=()
  updates=$(mktemp "$WORKING_DIR/.env.updates.XXXXXX") || return 1
  candidate=$(mktemp "$WORKING_DIR/.env.candidate.XXXXXX") || { rm -f "$updates"; return 1; }
  TEMP_FILES+=("$updates" "$candidate")
  chmod 600 "$updates" "$candidate"

  for key in "${original_keys[@]}"; do
    if [[ -v values[$key] && ! -v emitted[$key] ]]; then
      printf '%s=%s\n' "$key" "${values[$key]}" >> "$updates"
      emitted["$key"]=true
    fi
  done
  while IFS= read -r key; do
    [[ -v emitted[$key] ]] && continue
    printf '%s=%s\n' "$key" "${values[$key]}" >> "$updates"
  done < <(printf '%s\n' "${!values[@]}" | LC_ALL=C sort)

  if ! awk '
    NR == FNR {
      split_at = index($0, "=")
      key = substr($0, 1, split_at - 1)
      updates[key] = substr($0, split_at + 1)
      order[++count] = key
      next
    }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      split_at = index($0, "=")
      key = substr($0, 1, split_at - 1)
      if (key in updates) {
        if (!(key in written)) print key "=" updates[key]
        written[key] = 1
        next
      }
    }
    { print }
    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        if (!(key in written)) print key "=" updates[key]
      }
    }
  ' "$updates" "$ENV_FILE" > "$candidate"; then
    rm -f "$updates" "$candidate"
    return 1
  fi

  for key in "${!values[@]}"; do
    if [[ $(grep -Ec "^${key}=" "$candidate") -ne 1 ]]; then
      echo -e "${RED}❌ Candidate .env does not contain exactly one $key entry.${NC}" >&2
      rm -f "$updates" "$candidate"
      return 1
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    local -a compose_check=(env)
    local -A unset_seen=()
    for key in "${original_keys[@]}" "${!values[@]}"; do
      if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! -v unset_seen[$key] ]]; then
        compose_check+=(-u "$key")
        unset_seen["$key"]=true
      fi
    done
    if ! "${compose_check[@]}" docker compose -f "$COMPOSE_FILE" --env-file "$candidate" config -q; then
      echo -e "${RED}❌ Docker Compose rejected the candidate .env.${NC}" >&2
      rm -f "$updates" "$candidate"
      return 1
    fi
  fi

  backup_file "$ENV_FILE" || { rm -f "$updates" "$candidate"; return 1; }
  mv -f "$candidate" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  rm -f "$updates"
}


# Function to update the the .env file with required variables to run RF and some optional variables
update_env() {
  pending_changes=false # This is to track if any .env values would change
  pending_arg_changes=false # This is to track if any BUILD args would change
  local review_details="" old_display new_display

  # Declare NEW variables to check against existing .env values to detect if anything changed
  declare -A new_env_vars=(
    ["RF_BACKEND_IMAGE_REPO"]="$RF_BACKEND_IMAGE_REPO"
    ["RF_IMAGE_TAG_MODE"]="$RF_IMAGE_TAG_MODE"
    ["REPO"]="$REPO"
    ["TUNNEL_TOKEN"]="$TUNNEL_TOKEN"
    ["DOMAIN"]="$DOMAIN"
    ["USER_JWT_KEY"]="$USER_JWT_KEY"
#    ["HOSTNAME_PARTS"]="$HOSTNAME_PARTS"
    ["AUTO_VALIDATE_EMAIL"]="$AUTO_VALIDATE_EMAIL"
    ["DOCKERFILE"]="$DOCKERFILE"
    ["NGINX_CERT"]="./${DOMAIN}_origin_cert.pem"
    ["NGINX_KEY"]="./${DOMAIN}_origin_key.pem"
    ["PROTOMAPS_API_KEY"]="$PROTOMAPS_API_KEY"
    ["MAP_STYLE_LIGHT"]="$MAP_STYLE_LIGHT"
    ["MAP_STYLE_DARK"]="$MAP_STYLE_DARK"
    ["PUBLIC_POSTHOG_KEY"]="$PUBLIC_POSTHOG_KEY"
    ["POSTHOG_CLI_API_KEY"]="$POSTHOG_CLI_API_KEY"
    ["GA_TRACKING_ID"]="$GA_TRACKING_ID"
    ["MIXPANEL_KEY"]="$MIXPANEL_KEY"
#    ["CLIENT_HEADER"]="$CLIENT_HEADER"
#    ["SENDGRID_KEY"]="$SENDGRID_KEY"
    ["GITHUB_PAT"]="$GITHUB_PAT"
    ["SOCIAL_META"]="$SOCIAL_META"
    ["SEQUENCE_LIMIT"]="$SEQUENCE_LIMIT"
    ["SWAP_CP"]="$SWAP_CP"
    ["VIEWER_PAGE_SUBDOMAIN"]="$VIEWER_PAGE_SUBDOMAIN"
    ["CONTROL_PANEL_SUBDOMAIN"]="$CONTROL_PANEL_SUBDOMAIN"
    ["CONTROL_HOST"]="$CONTROL_HOST"
    ["VIEWER_HOST"]="$VIEWER_HOST"
  )

  # If any of these are changed, an image rebuild will be required.
  declare -A new_build_args=(
    ["VERSION"]="$VERSION"
    ["HOST_ENV"]="$HOST_ENV"
    ["DOMAIN"]="$DOMAIN"
    ["PROTOMAPS_API_KEY"]="$PROTOMAPS_API_KEY"
    ["MAP_STYLE_LIGHT"]="$MAP_STYLE_LIGHT"
    ["MAP_STYLE_DARK"]="$MAP_STYLE_DARK"
    ["PUBLIC_POSTHOG_KEY"]="$PUBLIC_POSTHOG_KEY"
    ["POSTHOG_CLI_API_KEY"]="$POSTHOG_CLI_API_KEY"
    ["HOSTNAME_PARTS"]="$HOSTNAME_PARTS"
    ["SOCIAL_META"]="$SOCIAL_META"
    ["SWAP_CP"]="$SWAP_CP"
    ["VIEWER_PAGE_SUBDOMAIN"]="$VIEWER_PAGE_SUBDOMAIN"
    ["CONTROL_PANEL_SUBDOMAIN"]="$CONTROL_PANEL_SUBDOMAIN"
    ["CONTROL_HOST"]="$CONTROL_HOST"
    ["VIEWER_HOST"]="$VIEWER_HOST"
  )

# Compare new_env_vars to existing_env_vars
  for key in "${!new_env_vars[@]}"; do
    local current_val="${existing_env_vars[$key]}"
    local new_val="${new_env_vars[$key]}"

    if [[ "$new_val" != "$current_val" ]]; then
      pending_changes=true
      break
    fi
  done

  if tag_has_latest; then # With the setup_cloudflare script it will populate some initial arg values so assume build is needed if tags are set to latest
    pending_arg_changes=true
  else
    for key in "${!new_build_args[@]}"; do
      local current_val="${existing_env_vars[$key]}"
      local new_val="${new_build_args[$key]}"

      if [[ "$new_val" != "$current_val" ]]; then
        pending_arg_changes=true
        break
      fi
    done
  fi

  # A template with `latest` application tags is a fresh install and still
  # needs an image build even when the copied .env values are unchanged.
  if [ "$pending_changes" = false ] && [ "$pending_arg_changes" = false ] &&
     [ "$PENDING_CLOUDFLARE_SETUP" = false ] && [ "$PENDING_CERT_UPDATE" = false ]; then
    echo -e "${YELLOW}⚠️ No changes detected — skipping .env update prompt.${NC}"
    return 1
  else
    # Print only values that will change. Secrets are always redacted.
    if [[ "$UI_MODE" != "tui" ]]; then
      echo
      echo -e "${YELLOW}⚠️ Please review the proposed changes:${NC}"
      echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    for key in "${original_keys[@]}"; do
      if [[ -v new_env_vars[$key] && "${new_env_vars[$key]}" != "${existing_env_vars[$key]:-}" ]]; then
        old_display=$(review_env_value "$key" "${existing_env_vars[$key]:-}")
        new_display=$(review_env_value "$key" "${new_env_vars[$key]}")
        [[ "$UI_MODE" == "tui" ]] || echo -e "${BLUE}🔸 ${CONFIG_LABEL[$key]:-$key}${NC} ${CYAN}[$key/${CONFIG_SECTION[$key]:-general}]${NC}: ${YELLOW}${old_display}${NC} → ${GREEN}${new_display}${NC}"
        review_details+="  - ${CONFIG_LABEL[$key]:-$key}: $old_display -> $new_display"
        if [[ "${CONFIG_REBUILD[$key]:-false}" == "true" ]]; then
          [[ "$UI_MODE" == "tui" ]] || echo -e "   ${YELLOW}↳ requires an image rebuild${NC}"
          review_details+=" [rebuild]"
        fi
        review_details+=$'\n'
      fi
    done
    for key in "${!new_env_vars[@]}"; do
      if [[ ! -v existing_env_vars[$key] ]]; then
        new_display=$(review_env_value "$key" "${new_env_vars[$key]}")
        [[ "$UI_MODE" == "tui" ]] || echo -e "${BLUE}🔸 $key${NC}: ${GREEN}${new_display}${NC} ${CYAN}(new)${NC}"
        review_details+="  - ${CONFIG_LABEL[$key]:-$key}: [not present] -> $new_display"$'\n'
      fi
    done
    [[ "$UI_MODE" == "tui" ]] || echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ "$pending_arg_changes" = true ]; then
      echo
      if ! tag_has_latest && [[ "$UI_MODE" != "tui" ]]; then
        echo -e "${YELLOW}⚠️ The following build arguments have changed. Remote Falcon container images will need to be (re)built for the changes to take effect:${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        for key in "${original_keys[@]}"; do
          if [[ -v new_build_args[$key] ]]; then
            current_val=$(grep -E "^${key}=" "$ENV_FILE" | cut -d'=' -f2-)
            if [[ "${new_build_args[$key]}" != "$current_val" ]]; then
              echo -e "${RED}🔧 $key${NC}=${YELLOW}$(display_env_value "$key" "${new_build_args[$key]}")${NC}"
            fi
          fi
        done
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      fi
    fi
  fi

  # Cloudflare supplies the tunnel token during the approved apply phase.
  vars_to_validate=(DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE)
  [[ "$PENDING_CLOUDFLARE_SETUP" == "false" ]] && vars_to_validate=(TUNNEL_TOKEN "${vars_to_validate[@]}")
  [[ "$UI_MODE" == "tui" ]] || echo -e "${CYAN}🔍 Validating variables: ${vars_to_validate[*]}${NC}"

  # Run validation
  if ! validate_variables "${vars_to_validate[@]}"; then
    echo -e "${RED}❌ Validation failed. The .env file was not updated.${NC}"
    exit 1
  else
    [[ "$UI_MODE" == "tui" ]] || echo -e "${GREEN}✅ All environment variables validated successfully.${NC}"
  fi

  local review_status=0
  show_execution_plan "$pending_arg_changes" "$review_details" "${vars_to_validate[*]}" || review_status=$?

  if [[ "$PLAN_ONLY" == "true" ]]; then
    echo -e "${GREEN}✅ Plan complete. No files, services, or external resources were changed.${NC}"
    return 2
  fi

  local approval=""
  if [[ "$ASSUME_YES" == "true" ]]; then
    approval="y"
  elif [[ "$UI_MODE" == "tui" ]]; then
    case "$review_status" in
      0) approval="y" ;;
      1) approval="n" ;;
      *) return 3 ;;
    esac
  else
    approval=$(get_input "❓ Apply the reviewed execution plan? (y/n)" "n")
  fi
  if [[ "$approval" =~ ^[Yy]$ ]]; then
    apply_pending_prerequisites || return 3
    # Preserve the true pre-apply state before any approved external helper can
    # update configuration files of its own.
    backup_file "$ENV_FILE" || return 3
    apply_pending_external_configuration || return 3
    new_env_vars["TUNNEL_TOKEN"]="$TUNNEL_TOKEN"

    if ! validate_variables TUNNEL_TOKEN; then
      echo -e "${RED}❌ Cloudflare setup did not produce a valid tunnel token.${NC}" >&2
      return 3
    fi
    write_env_atomically new_env_vars || {
      echo -e "${RED}❌ The candidate .env failed validation; the active file was not replaced.${NC}" >&2
      return 3
    }

    echo -e "${GREEN}✔ Writing variables to .env file completed!${NC}"
    echo
    echo "Printing current .env variables:"
    parse_env "$ENV_FILE"
    print_env

    # If there's pending arg changes set image_reubild_needed to true since the changes were accepted and written to .env
    if [ "$pending_arg_changes" = true ]; then
      image_rebuild_needed=true
    fi

    return 0 # Return Success
  else
    if [[ "$UI_MODE" == "tui" ]]; then
      show_configuration_notice "Changes not applied" \
        "No configuration changes were made. You can still check for container updates or run health checks next." 12 82
    else
      echo -e "${YELLOW}⚠️ Variables were not updated! No changes were made to the .env file.${NC}"
    fi
    return 1 # Return Failure
  fi
}

# Function to validate variable input and display a mesage if invalid.
validate_variables() {
  local valid=true

  if [[ "$DEBUG_INPUT" == "true" ]]; then
    echo -e "${CYAN}DEBUG: validate_variables called with args: $*${NC}" >&2
  fi

  while (( "$#" )); do
    local var_name="$1"
    local test_value=""
    shift

    # Check if next argument is a *direct value*, not a variable name
    if (( $# )) && [[ ! "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      test_value="$1"
      shift
    else
      # If not provided, use indirect expansion
      test_value="${!var_name:-}"
    fi

    case "$var_name" in
      TUNNEL_TOKEN)
        if [[ -z "$test_value" || "$test_value" == "cloudflare_token" ]]; then
          echo -e "${RED}❌ $var_name is missing or placeholder (value: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      DOMAIN)
        if [[ -z "$test_value" || "$test_value" == "your_domain.com" ]]; then
          echo -e "${RED}❌ $var_name is invalid or placeholder (value: '${test_value:-empty}').${NC}" >&2
          valid=false
        elif [[ ! "$test_value" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
          echo -e "${RED}❌ $var_name ('$test_value') is not a valid domain format (yourdomain.com).${NC}" >&2
          valid=false
        fi
        ;;
      AUTO_VALIDATE_EMAIL)
        test_value="${test_value,,}" # Convert to lower case
        if [[ "$test_value" != "true" && "$test_value" != "false" ]]; then
          echo -e "${RED}❌ $var_name must be 'true' or 'false' (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      HOSTNAME_PARTS)
        if [[ ! "$test_value" =~ ^[23]$ ]]; then
          echo -e "${RED}❌ $var_name must be 2 or 3 (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      GITHUB_PAT)
#        if [[ -z "$test_value" ]]; then
#          echo -e "${RED}❌ GitHub Personal Access Token cannot be blank.${NC}" >&2
#          valid=false
        if [[ -n "$test_value" ]] && [[ ! "$test_value" =~ ^[0-9a-f]{40}$ ]] && [[ ! "$test_value" =~ ^gh[pousr]_[A-Za-z0-9_]{36,255}$ ]]; then
          echo -e "${RED}❌ GitHub Personal Access Token is not in the correct format (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      USER_JWT_KEY)
        if [[ -z "$test_value" || "$test_value" == "123456" || ${#test_value} -lt 32 ]]; then
          echo -e "${RED}❌ $var_name must be a non-placeholder signing key of at least 32 characters.${NC}" >&2
          valid=false
        fi
        ;;
      SEQUENCE_LIMIT)
        if [[ ! "$test_value" =~ ^[1-9][0-9]*$ ]]; then
          echo -e "${RED}❌ Please enter a valid whole number greater than 0 (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      SWAP_CP)
        test_value="${test_value,,}" # Convert to lower case
        if [[ "$test_value" != "true" && "$test_value" != "false" ]]; then
          echo -e "${RED}❌ $var_name must be 'true' or 'false' (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      VIEWER_PAGE_SUBDOMAIN)
        if [[ $SWAP_CP == "true" ]]; then
          # Validate: only lowercase letters and digits
          test_value=$(echo "$test_value" | tr -d '[:space:]')
          test_value=$(echo "$test_value" | tr '[:upper:]' '[:lower:]')
          if [[ -z "$test_value" ]]; then
            echo -e "${RED}❌ Subdomain cannot be empty (current: '${test_value:-empty}').${NC}" >&2
            valid=false
          elif [[ "$test_value" =~ [^a-z0-9] ]]; then
            echo -e "${RED}❌ Subdomain must contain only lowercase letters and numbers (no spaces, symbols, or hyphens) (current: '${test_value:-empty}').${NC}" >&2
            valid=false
          else
            break
          fi
        fi
        ;;
      DOCKERFILE)
        if [[ "$test_value" != "Dockerfile" && "$test_value" != "Dockerfile.dev" ]]; then
          echo -e "${RED}❌ $var_name must be 'Dockerfile' or 'Dockerfile.dev' (current: '${test_value:-empty}').${NC}" >&2
          valid=false
        fi
        ;;
      *)
        ;;
    esac
  done

  $valid && return 0 || return 1
}

# Function to ask for variable and perform validation until valid input is provided
ask_and_validate() {
  local var_name="$1"
  local prompt="$2"
  local current_value="$3"
  local value input_status

  while true; do
    value=$(get_input "$var_name" "$prompt" "$current_value")
    input_status=$?
    if [[ $input_status -ne 0 ]]; then
      return "$input_status"
    fi

    # Non-interactive input cannot retry, so reject invalid overrides and let
    # the final validation report the complete configuration error.
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
      declare -g "${var_name}=${value}"
      if ! validate_variables "$var_name" >/dev/null; then
        echo -e "${RED}❌ Invalid non-interactive value supplied for $var_name.${NC}" >&2
        return 1
      fi
      echo "$value"
      return 0
    fi

    # Temporarily assign value for validation
    # export "${var_name}=${value}"

    # Temporarily assign global value for validation (not exported)
    declare -g "${var_name}=${value}"

    # Interactive validation. A full-screen TUI immediately redraws the input
    # dialog, so show validation failures in their own dialog first.
    if [[ "${UI_MODE:-plain}" == "tui" ]]; then
      local validation_message=""
      if validation_message=$(RED= NC= validate_variables "$var_name" 2>&1); then
        echo "$value"
        return 0
      fi
      whiptail --title "Invalid value" --msgbox \
        "${validation_message}\n\nPlease correct the value and try again." 12 84 1>&2 || {
        kill -TERM "$MAIN_PID"
        return 130
      }
    elif validate_variables "$var_name"; then
      echo "$value"
      return 0
    fi
  done
}

# Store validated input without hiding a cancelled dialog inside command
# substitution. A cancellation stops the complete configuration walkthrough;
# other input failures retain their original status.
set_validated_input() {
  local var_name="$1" prompt="$2" current_value="$3"
  local value input_status

  value=$(ask_and_validate "$var_name" "$prompt" "$current_value")
  input_status=$?
  if [[ $input_status -eq 130 ]]; then
    cancel_configuration
  elif [[ $input_status -ne 0 ]]; then
    exit "$input_status"
  fi

  printf -v "$var_name" '%s' "$value"
}

configuration_requires_walkthrough() {
  [[ -z "${TUNNEL_TOKEN:-}" || "$TUNNEL_TOKEN" == "cloudflare_token" ||
     -z "${DOMAIN:-}" || "$DOMAIN" == "your_domain.com" ||
     -z "${USER_JWT_KEY:-}" || "$USER_JWT_KEY" == "123456" ]]
}

# Check for updates to the containers
run_updates() {
  local update_mode="${1:-}"
  local fresh_install="false"
  local defer_versitygw_init="false"

  if [[ "$ANY_SERVICE_RUNNING" == "false" ]]; then
    fresh_install="true"
    # Fresh configuration initializes VersityGW once, after the entire stack
    # (including NGINX and Cloudflared) has been started.
    defer_versitygw_init="true"
  fi

  if [[ -z "$update_mode" ]]; then
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
      update_mode="auto-apply"  # Default to auto-apply in non-interactive mode
    else
      update_mode="interactive"  # Default to interactive mode for update_containers.sh if not provided
    fi
  fi

  case "$update_mode" in
    auto-apply)
      RF_FRESH_INSTALL="$fresh_install" RF_DEFER_VERSITYGW_INIT="$defer_versitygw_init" \
        bash "$SCRIPT_DIR/update_containers.sh" "all" "auto-apply" || {
        echo -e "${RED}❌ Container update failed. Aborting configuration.${NC}" >&2
        exit 1
      }
      ;;
    *)
      # Interactive mode, default
      RF_FRESH_INSTALL="$fresh_install" RF_DEFER_VERSITYGW_INIT="$defer_versitygw_init" \
        bash "$SCRIPT_DIR/update_containers.sh" "all" || {
        echo -e "${RED}❌ Container update failed. Aborting configuration.${NC}" >&2
        exit 1
      }
      ;;
  esac
}

CONFIGURE_FAILED=false
run_configure_health_check() {
  if ! health_check health; then
    CONFIGURE_FAILED=true
  fi
}

repo_init() {
  local username="$1"   # GitHub username
  local new_repo="$2"   # Repo name (without username)

  # Convert both to lowercase
  username="${username,,}"
  new_repo="${new_repo,,}"

  echo -e "${BLUE}➕ Attempting to create private repository '$username/$new_repo' from template '$TEMPLATE_REPO'...${NC}"

  # Create repo from template
  if ! gh repo create "$username/$new_repo" --private --disable-issues --template "$TEMPLATE_REPO"; then
    echo -e "${RED}❌ Failed to create repository '$username/$new_repo'. Please check your GitHub PAT permissions and try again.${NC}"
    return 1
  fi

  # For updating the REPO value in the .env file
  REPO="${username}/${new_repo}"

  # Disable projects quietly since projects is not really needed on the new repo
  gh repo edit "$username/$new_repo" --enable-projects=false &>/dev/null || true

  echo -e "${GREEN}✅ Repository '$username/$new_repo' created and $ENV_FILE updated!${NC}"
  echo -e "${YELLOW}ℹ️ The repository was created from the public image-builder template.${NC}"
}

# Function to check extracted tags to check if they are tagged to 'latest'
tag_has_latest() {
  for service in "${SERVICES[@]}"; do

    if [[ $(get_current_compose_tag "$service") == "latest" ]]; then
      return 0  # true = has at least one 'latest'
    fi
  done

  return 1  # false = no 'latest'
}

case "$DOCKER_MODE" in
  group|rootless|manual) ;;
  *) echo -e "${RED}❌ Invalid --docker-mode '$DOCKER_MODE'. Use group, rootless, or manual.${NC}"; exit 2 ;;
esac

if [[ "$READ_ONLY_MODE" == "false" && "$DOCKER_MODE" == "rootless" ]]; then
  if ! docker info 2>/dev/null | grep -qi rootless; then
    cat >&2 <<'ROOTLESS'
Rootless Docker is not active for this user. Follow
https://docs.docker.com/engine/security/rootless/, verify that `docker info`
lists "rootless" under Security Options, then rerun this command.
The configurator will not install a rootful daemon when rootless was selected.
ROOTLESS
    exit 2
  fi
fi

if [[ "$DEFER_PREREQUISITES" == "false" && "$READ_ONLY_MODE" == "false" && $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
  echo -e "${RED}❌ Docker is unavailable and sudo is not installed. Install Docker as root, then rerun this script.${NC}"
  exit 1
fi

# Check if Docker is installed and ask to download and install it if not (For Ubuntu and Debian).
if [[ "$DEFER_PREREQUISITES" == "false" && "$READ_ONLY_MODE" == "false" ]] && ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker... you may need to enter your password for the 'sudo' command."
  # Get OS distribution
  source /etc/os-release
  case $ID in
    ubuntu)
      echo "Installing Docker for Ubuntu..."
      sudo apt-get update && sudo apt-get install ca-certificates curl -y && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
      if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
        exit 1
      else
        echo -e "${GREEN}✅ Docker installation for Ubuntu complete!${NC}"
      fi
    ;;
    debian)
      echo "Installing Docker for Debian.."
      sudo apt-get update && sudo apt-get install ca-certificates curl -y && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
      if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker install failed. Please install Docker to proceed.${NC}"
        exit 1
      else
        echo -e "${GREEN}✅ Docker installation for Debian complete!${NC}"
      fi
    ;;
    *)
      echo -e "${RED}❌ Distribution is not supported by this script! Please install Docker manually.${NC}"
      exit 1
    ;;
  esac

  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}❌ Docker must be installed. Please re-run the script to install Docker and to proceed.${NC}"
    exit 1
  fi
  echo
fi

# Configure non-root Docker access only when it is actually needed. Permanent
# docker group membership is the practical default for a dedicated VM, but it
# grants root-level control of the host. Rootless conversion is never automatic.
if [[ "$DEFER_PREREQUISITES" == "false" && "$READ_ONLY_MODE" == "false" && $EUID -ne 0 ]] && ! docker info >/dev/null 2>&1; then
  case "$DOCKER_MODE" in
    group)
      echo -e "${YELLOW}⚠️ Docker group membership grants root-level privileges on this host.${NC}"
      sudo groupadd --force docker
      sudo usermod -aG docker "$USER"
      echo -e "${GREEN}✔ Added '$USER' to the docker group.${NC}"
      echo "Run 'newgrp docker' in this SSH/login session, then rerun ./configure-rf.sh."
      exit 2
      ;;
    rootless)
      cat >&2 <<'ROOTLESS'
Rootless Docker must be configured explicitly before Remote Falcon setup.
Follow https://docs.docker.com/engine/security/rootless/, verify that
`docker info` shows Security Options: rootless, then rerun configure-rf.sh
with --docker-mode rootless. Existing rootful Docker data is not migrated.
ROOTLESS
      exit 2
      ;;
    manual)
      echo -e "${RED}❌ The current user cannot access Docker. Configure access and rerun.${NC}"
      exit 2
      ;;
  esac
fi

# Existing private image-builder installations still require GitHub CLI.
# Public-image installations must not install or require it.
ensure_legacy_github_cli() {
  command -v gh >/dev/null 2>&1 && return 0

  echo "Installing GitHub CLI for the deprecated private image-builder configuration..."
  (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y
  command -v gh >/dev/null 2>&1 || {
    echo -e "${RED}❌ GitHub CLI installation failed. Install gh or remove the legacy REPO and GITHUB_PAT settings.${NC}"
    return 1
  }
  echo -e "${GREEN}✅ GitHub CLI installation complete.${NC}"
}

# Auto install jq if not installed
if [[ "$DEFER_PREREQUISITES" == "false" && "$READ_ONLY_MODE" == "false" ]] && ! command -v jq >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠️ 'jq' is not installed. Installing jq...${NC}"
  sudo apt-get update && sudo apt-get install -y jq
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}❌ jq install failed. Please install jq to proceed.${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ jq installation complete!${NC}"
    fi
fi

PENDING_DOCKER_INSTALL=false
PENDING_DOCKER_GROUP=false
PENDING_JQ_INSTALL=false
PENDING_GH_INSTALL=false
if ! command -v docker >/dev/null 2>&1; then
  PENDING_DOCKER_INSTALL=true
elif [[ $EUID -ne 0 ]] && ! docker info >/dev/null 2>&1; then
  case "$DOCKER_MODE" in
    group) PENDING_DOCKER_GROUP=true ;;
    rootless|manual)
      echo -e "${RED}❌ The current user cannot access Docker in $DOCKER_MODE mode.${NC}" >&2
      exit 2
      ;;
  esac
fi
command -v jq >/dev/null 2>&1 || PENDING_JQ_INSTALL=true

# Ensure the 'remotefalcon' directory exists
if [[ ! -d "$WORKING_DIR" && "$READ_ONLY_MODE" == "false" ]]; then
  echo -e "${YELLOW}⚠️ Directory '$RF_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
  mkdir "$WORKING_DIR"
fi

# Ensure the 'backup' directory exists
if [[ ! -d "$BACKUP_DIR" && "$READ_ONLY_MODE" == "false" ]]; then
  echo -e "${YELLOW}⚠️ Directory '$BACKUP_DIR' does not exist. Creating it in $SCRIPT_DIR...${NC}"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
fi

# Change to the 'remotefalcon' directory and download compose.yaml and default.conf if they do not exist
cd "$WORKING_DIR" || { echo -e "${RED}❌ Failed to change directory to '$WORKING_DIR'. Exiting.${NC}"; exit 1; }
echo "✔  Working in directory: $(pwd)"
download_file "compose.yaml"
download_file "default.conf"

# Print existing .env file, if it exists, otherwise download the default .env file
if [ -f .env ]; then
  echo "✔  Found existing .env at $ENV_FILE."
  # Display versions of existing files and prompt to update if out of date
  echo "🔍 Parsing current .env variables:"
elif [[ "$READ_ONLY_MODE" == "true" && -f .env.example ]]; then
  ENV_FILE="$WORKING_DIR/.env.example"
  echo "🔍 No .env exists; reviewing the local .env.example without creating files:"
else
  download_file ".env"
  # Display versions of existing files and prompt to update if out of date
  echo "🔍 Parsing default .env variables:"
fi

# Read the .env file and export the variables, save build args to OLD_ARGS and print env file contents
[[ "$READ_ONLY_MODE" == "false" ]] && chmod 600 "$ENV_FILE"
parse_env "$ENV_FILE"
DOCKERFILE="${DOCKERFILE:-Dockerfile.dev}"
ORIGIN_CERTS_CONFIGURED_BY_SETUP=false
PENDING_CLOUDFLARE_SETUP=false
PENDING_CERT_UPDATE=false
if [[ "$UI_MODE" == "tui" ]]; then
  echo -e "${GREEN}✔ Loaded ${#original_keys[@]} configuration values; secrets remain hidden.${NC}"
else
  print_env
fi

if [[ "$VALIDATE_ONLY" == "true" ]]; then
  vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE USER_JWT_KEY)
  echo -e "${CYAN}🔍 Validating current configuration without applying changes...${NC}"
  validate_variables "${vars_to_validate[@]}" || exit 1
  duplicate_keys=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{count[$1]++} END{for (key in count) if (count[key] > 1) print key}' "$ENV_FILE")
  if [[ -n "$duplicate_keys" ]]; then
    echo -e "${RED}❌ Duplicate .env keys detected:${NC}" >&2
    printf '%s\n' "$duplicate_keys" >&2
    exit 1
  fi
  if command -v docker >/dev/null 2>&1; then
    rf_compose config -q || {
      echo -e "${RED}❌ Docker Compose rejected the current configuration.${NC}" >&2
      exit 1
    }
  else
    echo -e "${YELLOW}⚠️ Docker is unavailable; Compose rendering was not checked.${NC}"
  fi
  echo -e "${GREEN}✅ Current Remote Falcon configuration is valid.${NC}"
  exit 0
fi

if [[ -n "${REPO:-}" && "$REPO" != "username/repo" && -n "${GITHUB_PAT:-}" ]]; then
  command -v gh >/dev/null 2>&1 || PENDING_GH_INSTALL=true
fi

# Function for the GitHub configuration flow to configure GITHUB_PAT and REPO
configure_github() {
  # Get GITHUB_PAT and validate input is not default or empty
  set_validated_input GITHUB_PAT "🔑 Enter your GitHub Personal Access Token, required scopes are read:org, workflow, read:packages, repo:" "$GITHUB_PAT"

  # Only continue if PAT is set
  if [[ -n "$GITHUB_PAT" ]]; then
    # Validate the GITHUB_PAT by using the GitHub CLI to login
    validate_github_user "$GITHUB_PAT" || exit 1

    # Set a default GitHub REPO name based on the DOMAIN name if not already set
    if [[ -z "$REPO" || "$REPO" == "username/repo" ]]; then
      REPO="${DOMAIN}-image-builder"
    fi

    # Get the GitHub REPO name and then validate it exists or create it from template if it does not exist
    while true; do
      set_validated_input REPO "🐙 Enter your GitHub Repository (either 'repo' or 'username/repo'). The username will be set to '$GH_USER':" "$REPO"

      # Reject blank/default
      if [[ -z "$REPO" || "$REPO" == "username/repo" || "$REPO" == "repo" ]]; then
        echo -e "${RED}❌ Repository is blank or still set to default.${NC}"
        continue
      fi

      # Strip username if provided
      if [[ "$REPO" == */* ]]; then
        repo_name="${REPO#*/}"
      else
        repo_name="$REPO"
      fi

      # Validate repo name format
      if [[ ! "$repo_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo -e "${RED}❌ Repository name may only contain letters, numbers, underscores, periods, or dashes.${NC}"
        continue
      fi

      # Normalize to lowercase
      username="${GH_USER,,}"
      repo_name="${repo_name,,}"

      # If repo does not exist, create it from template via repo_init, else set the repo variable to the correct format for the existing repo
      if ! validate_github_repo "$repo_name"; then
        if [[ "$(get_input "❓ Would you like to create private repository '$repo_name' from template 🔗 https://github.com/$TEMPLATE_REPO ? (y/n)" "y")" =~ ^[Yy]$ ]]; then
          # Create from template if missing
          repo_init "$username" "$repo_name"
        else
          echo -e "${YELLOW}⚠️ Setting GITHUB_PAT and REPO back to defaults.${NC}"
          GITHUB_PAT=""
          REPO="username/repo"
        fi
      else
        # set the temp repo value to the correct format, if user confirms at the update .env prompt it will be written to .env
        REPO="${username}/${repo_name}"
      fi
      break
    done
  else
    # If GITHUB_PAT is blank, reset REPO to default
    REPO="username/repo"
  fi
}

configure_build_strategy() {
  if ! public_backend_images_supported; then
    show_configuration_notice "Image build strategy" \
      "This host is not AMD64 or ARM64. Public Remote Falcon backend images do not target this architecture, so this host will use local JVM builds." 12 82
    REPO="username/repo"
    GITHUB_PAT=""
    DOCKERFILE="Dockerfile.dev"
    RF_IMAGE_TAG_MODE="app"
    return
  fi

  if github_workflow_builds_configured; then
    DOCKERFILE="Dockerfile"
    show_configuration_notice "Image build strategy" \
      "Existing private image-builder configuration detected:\n\n${REPO}\n\nThe existing GitHub build workflow will continue to be used." 14 82
    return
  fi

  REPO="username/repo"
  GITHUB_PAT=""
  DOCKERFILE="Dockerfile.dev"
  RF_IMAGE_TAG_MODE="platform"
  show_configuration_notice "Image build strategy" \
    "Public AMD64/ARM64 images for 4 of the Remote Falcon containers will be pulled anonymously from:\n\nhttps://github.com/Ne0n09/cloudflared-remotefalcon\n\nOnly the Remote Falcon UI will be built locally.\n4GB or more of RAM is required for the build to complete.\nA GitHub account or token is no longer required.\n\nTip: Ctrl+click a URL in most terminal applications to open the link." 20 92
}

# Ask to configure .env values
if [[ "$PLAN_ONLY" == "true" || "$ROTATE_JWT" == "true" || ${#OVERRIDES[@]} -gt 0 ]] ||
   configuration_requires_walkthrough ||
   [[ "$(get_input "❓ Change the .env file variables? (y/n)" "n" )" =~ ^[Yy]$ ]]; then
  # Configuration walkthrough questions. Questions will pull existing or default values from the sourced .env file
  echo
  echo -e "Answer the following questions to update your compose .env variables."
  echo "Press ENTER to accept the existing values that are between the brackets [ ]."
  echo "You will be asked to confirm the changes before the file is modified."
  echo
  # ====== START variable questions ======

  # ====== START REQUIRED variables ======
  TUI_PROMPT_TITLE="Step 1: Required settings"
  show_tui_section "Step 1: Required settings" \
    "This section collects the settings Remote Falcon needs:

  - Public domain name
  - Cloudflare tunnel token
  - Auto validate email policy
  - HTTPS origin certificate

No changes will be made until approved at the end.

Review the docs here:
https://ne0n09.github.io/cloudflared-remotefalcon/latest/

Tip: Ctrl+click a URL in most terminal applications to open the link." 23 92
  # Get domain name and validate input is not default, empty, or not in valid domain format
  set_validated_input DOMAIN "🌐 Enter your domain name (e.g., yourdomain.com):" "$DOMAIN"

  configure_build_strategy

  # Get the Cloudflared tunnel token and validate input is not default, empty, or not in valid format
#  if [[ "$TUNNEL_TOKEN" == "cloudflare_token" || -z "$TUNNEL_TOKEN" ]]; then
#    echo -e "${YELLOW}⚠️ TUNNEL_TOKEN is not set or is set to the default value.${NC}"
#  fi
  set_validated_input CF_API_TOKEN "🔑 Paste your Cloudflare API token for automatic setup. Leave blank to configure Cloudflare manually:" "${CF_API_TOKEN:-}"
  if [[ -n "$CF_API_TOKEN" ]]; then
    # External configuration is deliberately deferred until after the review
    # and execution-plan approval.
    PENDING_CLOUDFLARE_SETUP=true
    show_configuration_notice "Cloudflare automatic setup" \
      "Cloudflare tunnel, DNS, and origin certificate setup will be added to the execution plan.\n\nNo Cloudflare changes occur until you review and approve that plan." 14 82
  else
    set_validated_input TUNNEL_TOKEN "🔐 Enter your Cloudflare Tunnel token:" "$TUNNEL_TOKEN"
  fi

  # Validate auto validate email input, only accept true or false
  set_validated_input AUTO_VALIDATE_EMAIL "📧 Enable auto validate email? While set to 'true' anyone can create a viewer page account on your site (true/false):" "$AUTO_VALIDATE_EMAIL"
  AUTO_VALIDATE_EMAIL="${AUTO_VALIDATE_EMAIL,,}"

  # Removed this HOSTNAME_PARTS question to avoid issues - .env can be manually edited if you have ACM and want a 3 part domain.
  #echo "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com')"
  #HOSTNAME_PARTS=$(ask_and_validate HOSTNAME_PARTS "Cloudflare free only supports two parts for wildcard domains without Advanced Certicate Manager(\$10/month):" "$HOSTNAME_PARTS" )
  #echo

  if [[ $HOSTNAME_PARTS == 3 ]]; then
    echo -e "${YELLOW}⚠️ You are using a 3 part domain. Please ensure you have Advanced Certificate Manager enabled in Cloudflare.${NC}"
  fi

  if [[ "$PENDING_CLOUDFLARE_SETUP" == "true" ]]; then
    show_configuration_notice "Origin certificate" \
      "The origin certificate and private key will be created automatically by the Cloudflare action after you approve the execution plan." 12 82
  elif [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    echo -e "${YELLOW}⚠️ Skipping origin certificate/key configuration in non-interactive mode.${NC}"
  else
    # Ask if Cloudflare origin certificates should be updated if they exist. Otherwise prompt if cert/key files are missing
    # This will create the cert/key in the current directory and append the domain name to the beginning of the file name
    if [[ -f "${DOMAIN}_origin_cert.pem" && -f "${DOMAIN}_origin_key.pem" ]]; then
      if [[ "$(get_input "❓ Update existing origin certificate and key? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        PENDING_CERT_UPDATE=true
      fi
    else
      TUI_PROMPT_TITLE="Manual origin certificate"
      if [[ "$UI_MODE" == "tui" ]]; then
        whiptail --title "$TUI_PROMPT_TITLE" --msgbox \
          "$(manual_origin_certificate_guidance)" 20 94 1>&2 || {
            kill -TERM "$MAIN_PID"
            exit 130
          }
      else
        printf '\n%s\n\n' "$(manual_origin_certificate_guidance)"
        read -rp "Press ENTER to add manual certificate entry to the execution plan."
      fi
      PENDING_CERT_UPDATE=true
      TUI_PROMPT_TITLE="Step 1: Required settings"
    fi
  fi
  # ====== END REQUIRED variables ======

  # ====== START OPTIONAL variables ======
  TUI_PROMPT_TITLE="Step 2: Optional settings"
  if [[ "$(prompt_optional_settings_update)" =~ ^[Yy]$ ]]; then
    # Ask if SEQUENCE_LIMIT variable should be updated
    set_validated_input SEQUENCE_LIMIT "🎶 Enter desired sequence limit:" "$SEQUENCE_LIMIT"

    # Validate SWAP_CP input, only accept true or false
    #echo -e "🔁 SWAP_CP = true will make your\n  Viewer Page Subdomain accessible at: ${BLUE}🔗 https://$DOMAIN${NC}\n  Control Panel accessible at: ${BLUE}🔗 https://controlpanel.$DOMAIN${NC}"
    #echo -e "🔁 SWAP_CP = false will make your\n  Control Panel accessible at: ${BLUE}🔗 https://$DOMAIN${NC}\n  Viewer Page Subdomain accessible at: ${BLUE}🔗 https://yoursubdomain.$DOMAIN${NC}"
    echo -e "🔁 SWAP_CP = true  →  Viewer: ${BLUE}🔗 https://$DOMAIN${NC}  |  Control Panel: ${BLUE}🔗 https://controlpanel.$DOMAIN${NC}"
    echo -e "🔁 SWAP_CP = false →  Control Panel: ${BLUE}🔗 https://$DOMAIN${NC} |  Viewer: ${BLUE}🔗 https://yoursubdomain.$DOMAIN${NC}"
    set_validated_input SWAP_CP "❓ Enable or disable SWAP_CP to swap the Control Panel and Viewer Page Subdomain URLs? (true/false):

Review the URL layouts and requirements:
https://ne0n09.github.io/cloudflared-remotefalcon/post-install/#swap-viewer-page-subdomain

Tip: Ctrl+click a URL in most terminal applications to open the link." "$SWAP_CP"
    SWAP_CP="${SWAP_CP,,}"

    # If SWAP_CP is set to true ask to update the Viewer Page Subdomain
    if [[ $SWAP_CP == true ]]; then
      set_validated_input VIEWER_PAGE_SUBDOMAIN "🌐 Enter your Viewer Page Subdomain:" "$VIEWER_PAGE_SUBDOMAIN"

      # Remove all whitespace (leading, trailing, and internal)
      VIEWER_PAGE_SUBDOMAIN=$(echo "$VIEWER_PAGE_SUBDOMAIN" | tr -d '[:space:]')
      # Convert to lowercase
      VIEWER_PAGE_SUBDOMAIN=$(echo "$VIEWER_PAGE_SUBDOMAIN" | tr '[:upper:]' '[:lower:]')
    fi

    PROTOMAPS_API_KEY=$(get_input PROTOMAPS_API_KEY "🗺️ Enter your Protomaps API key (optional):" "$PROTOMAPS_API_KEY")

    # Ask if SOCIAL_META variable should be updated
    if [[ "$(get_input "❓ Update social meta tag? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      echo "See the RF docs for details on the SOCIAL_META tag:"
      echo -e "${BLUE}🔗 https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?#update-docker-composeyaml${NC}"
      echo
      echo -e "🏷️ Update SOCIAL_META tag or leave as default - Enter on one line only"
      echo
      SOCIAL_META=$(get_input SOCIAL_META "" "$SOCIAL_META")
    fi

    # Ask if analytics env variables should be set for PostHog, Google Analytics, or Mixpanel
    if [[ "$(get_input "❓ Update analytics variables? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      PUBLIC_POSTHOG_KEY=$(get_input PUBLIC_POSTHOG_KEY "📊 Enter your PostHog key - https://posthog.com/:" "$PUBLIC_POSTHOG_KEY")
      GA_TRACKING_ID=$(get_input GA_TRACKING_ID "Enter your Google Analytics Measurement ID - https://analytics.google.com/:" "$GA_TRACKING_ID")
      MIXPANEL_KEY=$(get_input MIXPANEL_KEY "📊 Enter your Mixpanel key - https://mixpanel.com/:" "$MIXPANEL_KEY")
    fi
  fi

  # Ensure optional variables are set to the current values regardless if they were updated or not
  REPO=${REPO:-$REPO}
  GITHUB_PAT=${GITHUB_PAT:-$GITHUB_PAT}
  HOSTNAME_PARTS=${HOSTNAME_PARTS:-$HOSTNAME_PARTS}
  PROTOMAPS_API_KEY=${PROTOMAPS_API_KEY:-$PROTOMAPS_API_KEY}
  PUBLIC_POSTHOG_KEY=${PUBLIC_POSTHOG_KEY:-$PUBLIC_POSTHOG_KEY}
  GA_TRACKING_ID=${GA_TRACKING_ID:-$GA_TRACKING_ID}
  MIXPANEL_KEY=${MIXPANEL_KEY:-$MIXPANEL_KEY}
  SOCIAL_META=${SOCIAL_META:-$SOCIAL_META}
  SEQUENCE_LIMIT=${SEQUENCE_LIMIT:-$SEQUENCE_LIMIT}
  VIEWER_PAGE_SUBDOMAIN=${VIEWER_PAGE_SUBDOMAIN:-$VIEWER_PAGE_SUBDOMAIN}
  SWAP_CP=${SWAP_CP:-$SWAP_CP}
  # ====== END OPTIONAL variables ======

  # ====== START BUILD ARGs ======
  # Capture the current values of any BUILD args(from sourced .env) that weren't asked for above
  VERSION=${VERSION:-$VERSION}
  HOST_ENV=${HOST_ENV:-$HOST_ENV}
  DOCKERFILE=${DOCKERFILE:-Dockerfile.dev}
  PUBLIC_POSTHOG_HOST=${PUBLIC_POSTHOG_HOST:-$PUBLIC_POSTHOG_HOST}
  OTEL_OPTS=${OTEL_OPTS:-$OTEL_OPTS}
  OTEL_URI=${OTEL_URI:-$OTEL_URI}
  MONGO_URI=${MONGO_URI:-$MONGO_URI}

  # Generate the active control-panel signing key for a fresh install, but
  # preserve established keys. Rotation invalidates active login sessions.
  # VIEWER_JWT_KEY is retained only as an untouched legacy .env value because
  # current upstream UI source no longer consumes it.
  if [[ "$ROTATE_JWT" == "true" || -z "${USER_JWT_KEY:-}" || "$USER_JWT_KEY" == "123456" ]]; then
    USER_JWT_KEY=$(openssl rand -base64 32)
  fi

  # ====== END variable questions ======

  # ====== START Existing configuration ======
  # This section checks if any containers are running and ensures that compose.yaml tags match currently running versions(if in valid format)

  # Check if containers are running, meaning this is an existing configuration
  for service in "${SERVICES[@]}"; do
    if is_container_running "$service"; then
      ANY_SERVICE_RUNNING=true
      current_version=$(get_current_version "$service")
      compose_tag=$(get_current_compose_tag "$service")

      # Check if the running container's tag is in the valid format. replacee_compose_tag is defined in shared_functions.sh
      if check_tag_format "$service" "$current_version"; then
        # If the compose tag does not match the current running version, update the compose tag in compose.yaml - this is useful if compose.yaml was replaced and all are tagged to 'latest'
        if [[ "$compose_tag" != "$current_version" ]]; then
          if [[ "$UI_MODE" != "tui" ]]; then
            echo -e "${BLUE}⚠️ $service ${YELLOW}is running with version ${GREEN}$current_version${YELLOW} but the compose tag 🏷️ ${GREEN}$compose_tag${NC}${YELLOW} does not match. The correction was added to the plan.${NC}"
          fi
          PENDING_COMPOSE_OLD_TAGS["$service"]="$compose_tag"
          PENDING_COMPOSE_TAGS["$service"]="$current_version"
        fi
      fi
    fi
  done

  # ====== END Existing configuration ======

  # Review and approve the complete plan before storage initialization, image
  # builds, container recreation, or external configuration takes place.
  TUI_PROMPT_TITLE="Review changes and execution plan"
  update_env
  update_status=$?
  if [[ $update_status -eq 2 ]]; then
    exit 0
  fi
  if [[ $update_status -eq 3 ]]; then
    exit 1
  fi

  if [[ $update_status -eq 0 ]]; then
    # Ensure applications use a database-scoped account before any image build
    # or container recreation. This also safely rotates shipped credentials.
    mongo_init || exit 1

    for service in "${!PENDING_COMPOSE_TAGS[@]}"; do
      replace_compose_tag "$service" "${PENDING_COMPOSE_TAGS[$service]}" || exit 1
      echo -e "✔  ${BLUE}$service ${NC}compose tag updated to ${GREEN}${PENDING_COMPOSE_TAGS[$service]}.${NC}"
    done

    # From shared_functions.sh, make sure compose.yaml uses the DOCKERFILE .env variable for RF builds
    update_compose_dockerfile_paths
    # From shared_function.sh, make sure the compose.yaml is set for pulling images via ghcr.io/${REPO}/ in the image path or set for local build
    update_compose_image_path

    # Update handling if any container is running
    if [[ $ANY_SERVICE_RUNNING == true ]]; then
      # Only rebuild images if the build ARGs were changed
      if [[ $image_rebuild_needed = true ]]; then
        # If any service is running and $REPO is configured run run_workflow.sh to rebuild all containers with any updated ARG values from the .env file
        if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
          echo -e "${YELLOW}⚠️ Containers are running. Build ARG changes detected. Running ./run_workflow.sh to ensure Remote Falcon images are built with any updated build ARGs at their current version...${NC}"
          # Run the workflow script to rebuild all containers with any updated ARG values from the .env file, images are built based on current short_sha tag in compose.yaml
          if bash "$SCRIPT_DIR/run_workflow.sh" \
            "plugins-api=$(get_current_version "plugins-api")" \
            "control-panel=$(get_current_version "control-panel")" \
            "viewer=$(get_current_version "viewer")" \
            "ui=$(get_current_version "ui")" \
            "external-api=$(get_current_version "external-api")"; then
              echo -e "${GREEN}✅ Workflow to build all Remote Falcon images to current versions completed successfully!${NC}"
          else
              echo -e "${RED}❌ Workflow to build all Remote Falcon images to current versions did not complete successfully, aborting.${NC}"
              exit 1
          fi
        else
          echo -e "${YELLOW}⚠️ UI build arguments changed. Rebuilding the UI locally and recreating the stack to apply runtime settings...${NC}"
          check_ui_build_memory || exit 1
          rf_compose build ui
          rf_compose up -d --force-recreate
        fi
      else # No ARGs changed, just run 'docker compose up -d' to pick up any environment variable changes
          echo -e "${YELLOW}⚠️ Containers are running. No build ARG changes detected. Running 'docker compose up -d' to apply any environmental variable changes...${NC}"
          rf_compose up -d --force-recreate
      fi

      # Prompt to check updates after applying new .env values to existing containers
      if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_updates
        versitygw_init
        run_configure_health_check
      elif [[ "$(get_input "❓ Run health check script? (y/n)" "y")" =~ ^[Yy]$ ]]; then
        run_configure_health_check
      fi
    else # No containers running
      echo -e "No containers are running. Checking Remote Falcon image tags for 'latest' in compose.yaml..."
      # No containers running, only rebuild images if the build ARGs were changed
      if [[ $image_rebuild_needed = true ]]; then
        echo -e "${YELLOW}⚠️ Remote Falcon image build required...${NC}"
        if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
          echo -e "🐙 GitHub repository ${REPO} will be used for the build.${NC}"
          if tag_has_latest; then
            # No containers running, REPO configured, rebuild required, RF containers tagged to 'latest' Assume new install, run workflow to build latest images and run_updates auto-apply
            echo -e "${BLUE}✨ Remote Falcon 'latest' image tags detected in compose.yaml, assuming new install. Running ./run_workflow.sh to build new Remote Falcon images on GitHub....${NC}"
            if bash "$SCRIPT_DIR/run_workflow.sh"; then
              run_updates auto-apply
            else
              echo -e "${RED}❌ Workflow failed. Aborting.${NC}"
              exit 1
            fi
          else # No containers running, REPO configured, rebuild required, and RF containers not tagged to 'latest' so we just rebuild with existing image tags from compose.yaml
            echo -e "${BLUE}🔄 Running ./run_workflow.sh to ensure Remote Falcon images are built with any updated build ARGs at their current version...${NC}"
            if bash "$SCRIPT_DIR/run_workflow.sh" \
              "plugins-api=$(get_current_compose_tag "plugins-api")" \
              "control-panel=$(get_current_compose_tag "control-panel")" \
              "viewer=$(get_current_compose_tag "viewer")" \
              "ui=$(get_current_compose_tag "ui")" \
              "external-api=$(get_current_compose_tag "external-api")"; then
                echo -e "${GREEN}🚀 Bringing up containers...${NC}"
                rf_compose up -d --force-recreate
            else
              echo -e "${RED}❌ Workflow failed. Aborting.${NC}"
              exit 1
            fi
          fi
        else # No containers running, REPO not configured so images will be built locally
          if tag_has_latest; then
            echo -e "${BLUE}✨ Remote Falcon 'latest' image tags detected in compose.yaml, assuming new install, running update_containers.sh...${NC}"
            run_updates auto-apply
          else
            echo -e "${BLUE}🔄 Building the UI locally to apply updated build arguments...${NC}"
            check_ui_build_memory || exit 1
            rf_compose build ui
            rf_compose up -d --force-recreate
          fi
        fi
      else # No containers running, image rebuild not required(ARGs weren't changed in script)
        if tag_has_latest; then
          # Run run_updates auto-apply to tag containers
          echo -e "${GREEN}🚀 Bringing up existing containers to apply any .env changes...${NC}"
          run_updates auto-apply
        else # No containers running, no image rebuild required, and no 'latest' tags found so just bring the containers up
          # Run interactive updates since update_containers will verify if the image exists in the REPO and build indvidually if missing
          if [[ -n "$REPO" && "$REPO" != "username/repo" ]]; then
            echo -e "${GREEN}🚀 Bringing up stopped containers with update_container.sh...${NC}"
            run_updates
          else # No containers running, no image rebuild required, so just bring the containers up
            echo -e "${GREEN}🚀 Bringing up existing containers to apply any .env changes...${NC}"
            rf_compose up -d
          fi
        fi
      fi
      # Every fresh/no-running-container path must finish storage setup and
      # validate the completed stack, including paths that already use pinned
      # image tags and therefore skip update_containers.sh.
      versitygw_init
      run_configure_health_check
    fi
  else # update_env returned false - Ask to run update check anyway
    # Run validation to make sure default values aren't set
    vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE)
    if validate_variables "${vars_to_validate[@]}"; then
      if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_updates
        versitygw_init
        run_configure_health_check
      elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
        run_configure_health_check
      fi
    fi
  fi
else # User chose not to update the .env file
  echo -e "${YELLOW}⚠️ No .env variables modified.${NC}"
  # Run validation to make sure default values aren't set
  vars_to_validate=(TUNNEL_TOKEN DOMAIN AUTO_VALIDATE_EMAIL HOSTNAME_PARTS SEQUENCE_LIMIT SWAP_CP VIEWER_PAGE_SUBDOMAIN DOCKERFILE)
  if validate_variables "${vars_to_validate[@]}"; then
    if [[ "$(get_input "❓ Check for container updates? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      run_updates
      versitygw_init
      run_configure_health_check
    elif [[ "$(get_input "❓ Run health check script? (y/n)" "n")" =~ ^[Yy]$ ]]; then
      run_configure_health_check
    fi
  fi
fi

if [[ "$CONFIGURE_FAILED" == "true" ]]; then
  echo -e "${RED}❌ Configuration completed with failed health checks.${NC}" >&2
  exit 1
fi

echo -e "${YELLOW}⚠️ If running FPP 9 ensure Apache CSP is updated or sequences will not sync!${NC}"
echo -e "${BLUE}🔗 https://ne0n09.github.io/cloudflared-remotefalcon/post-install/${NC}"

echo -e "${GREEN}🎉 Done! Exiting ${RED}RF${NC}${GREEN} configuration script...${NC}"
exit 0

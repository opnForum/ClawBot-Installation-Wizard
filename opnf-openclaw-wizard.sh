#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# opnForum OpenClaw Wizard
# Guided install / troubleshoot / uninstall
# Ubuntu Server 22.04+ recommended
# ============================================================

PROJECT_DIR="${HOME}/openclaw"
CONFIG_DIR="${HOME}/.openclaw"
NGINX_DIR="${PROJECT_DIR}/nginx"
CERT_DIR="${PROJECT_DIR}/certs"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
ENV_FILE="${PROJECT_DIR}/.env"
CONFIG_FILE="${CONFIG_DIR}/openclaw.json"

DEFAULT_PORT="8888"
DEFAULT_LOCAL_MODEL="qwen2.5:7b-instruct"
DEFAULT_CLOUD_MODEL="gpt-4o-mini"

SERVER_IP=""
OPENCLAW_PORT="${DEFAULT_PORT}"
GATEWAY_TOKEN=""
MODE="cloud"                  # cloud | local | hybrid
INSTALL_DOCKER="no"          # yes | no
INSTALL_OLLAMA="no"          # yes | no
LOCAL_MODEL="${DEFAULT_LOCAL_MODEL}"
CLOUD_MODEL="${DEFAULT_CLOUD_MODEL}"
CLOUD_PROVIDER="openai"      # openai | anthropic | groq | openrouter | gemini
CLOUD_BASE_URL="https://api.openai.com/v1"
CLOUD_API_ENV_NAME="OPENAI_API_KEY"
CLOUD_API_TYPE="openai-completions"
CLOUD_CONTEXT_WINDOW=128000
CLOUD_API_KEY=""
DOCKER_PREFIX=""
DISTRO_FAMILY=""              # debian | fedora | arch
DISTRO_ID=""                  # ubuntu, fedora, arch, etc.

CLR_ORANGE='\033[38;2;255;106;26m'
CLR_LIGHT='\033[38;2;230;226;221m'
CLR_DIM='\033[38;2;110;110;120m'
CLR_BLUE='\033[38;2;80;160;255m'
CLR_GREEN='\033[38;2;70;200;120m'
CLR_YELLOW='\033[38;2;245;190;70m'
CLR_RED='\033[38;2;245;90;90m'
CLR_RESET='\033[0m'

print_banner() {
  clear 2>/dev/null || true
  echo
  echo -e "${CLR_DIM}======================================================================${CLR_RESET}"
  echo -e "${CLR_LIGHT}  ██████  ██████  ███   ██${CLR_ORANGE} ███████  ██████  ██████  ██   ██ ███   ███${CLR_RESET}"
  echo -e "${CLR_LIGHT} ██    ██ ██   ██ ████  ██${CLR_ORANGE} ██      ██    ██ ██   ██ ██   ██ ████ ████${CLR_RESET}"
  echo -e "${CLR_LIGHT} ██    ██ ██████  ██ ██ ██${CLR_ORANGE} █████   ██    ██ ██████  ██   ██ ██ ███ ██${CLR_RESET}"
  echo -e "${CLR_LIGHT} ██    ██ ██      ██  ████${CLR_ORANGE} ██      ██    ██ ██   ██ ██   ██ ██     ██${CLR_RESET}"
  echo -e "${CLR_LIGHT}  ██████  ██      ██   ███${CLR_ORANGE} ██       ██████  ██   ██  █████  ██     ██${CLR_RESET}"
  echo
  echo -e "                     ${CLR_RED}OpenClaw Deployment Wizard${CLR_RESET}"
  echo
  echo -e "${CLR_DIM}======================================================================${CLR_RESET}"
  echo
  echo -e "  This script installs OpenClaw and all prerequisites if needed"
  echo -e "  (Docker, Ollama, AI models) for running OpenClaw in a local,"
  echo -e "  hybrid cloud, or cloud setup on your Linux server."
  echo
  echo -e "  ${CLR_DIM}Guide: https://opnforum.com/use-openclaw-for-free${CLR_RESET}"
  echo
  echo -e "${CLR_DIM}----------------------------------------------------------------------${CLR_RESET}"
  echo
}

log()  { echo -e "${CLR_BLUE}[INFO]${CLR_RESET} $*"; }
ok()   { echo -e "${CLR_GREEN}[OK]${CLR_RESET} $*"; }
warn() { echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $*"; }
err()  { echo -e "${CLR_RED}[ERR]${CLR_RESET} $*" >&2; }

pause() {
  echo
  read -r -p "Press Enter to continue..."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

docker_cmd() {
  if [[ -n "${DOCKER_PREFIX}" ]]; then
    ${DOCKER_PREFIX} docker "$@"
  else
    docker "$@"
  fi
}

detect_server_ip() {
  local detected=""
  if command_exists ip; then
    detected="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") print $(i+1)}' | head -n1 || true)"
  fi
  if [[ -z "${detected}" ]] && command_exists hostname; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${detected}"
}

generate_gateway_token() {
  openssl rand -hex 32
}

docker_present() {
  command_exists docker && docker compose version >/dev/null 2>&1
}

ollama_present() {
  command_exists ollama
}

ollama_pull_or_update() {
  local model="$1"
  if ollama pull "${model}"; then
    return 0
  fi

  # Pull failed — check if it needs a newer Ollama
  warn "Failed to pull ${model}. This model may require a newer version of Ollama."
  if ask_yes_no "Update Ollama and retry?" "y"; then
    log "Updating Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    sudo systemctl restart ollama
    sleep 3
    ok "Ollama updated."
    log "Retrying pull..."
    if ollama pull "${model}"; then
      return 0
    else
      err "Still failed to pull ${model} after updating Ollama."
      err "Try manually: ollama pull ${model}"
    fi
  else
    warn "Skipping model download. You can pull it manually later."
    warn "Run: ollama pull ${model}"
  fi
}

detect_distro() {
  if [[ ! -f /etc/os-release ]]; then
    err "Could not detect operating system."
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"

  case "${ID:-}" in
    ubuntu|debian|linuxmint|pop|zorin|elementary|kali|neon)
      DISTRO_FAMILY="debian"
      ;;
    fedora|rhel|centos|rocky|almalinux|nobara)
      DISTRO_FAMILY="fedora"
      ;;
    arch|manjaro|endeavouros|garuda|artix)
      DISTRO_FAMILY="arch"
      ;;
    *)
      # Fallback: check ID_LIKE or package managers
      if [[ "${ID_LIKE:-}" == *"debian"* || "${ID_LIKE:-}" == *"ubuntu"* ]]; then
        DISTRO_FAMILY="debian"
      elif [[ "${ID_LIKE:-}" == *"fedora"* || "${ID_LIKE:-}" == *"rhel"* ]]; then
        DISTRO_FAMILY="fedora"
      elif [[ "${ID_LIKE:-}" == *"arch"* ]]; then
        DISTRO_FAMILY="arch"
      elif command_exists apt; then
        DISTRO_FAMILY="debian"
      elif command_exists dnf; then
        DISTRO_FAMILY="fedora"
      elif command_exists pacman; then
        DISTRO_FAMILY="arch"
      else
        err "Unsupported distro: ${ID:-unknown}"
        err "This installer supports Debian/Ubuntu, Fedora/RHEL, and Arch-based systems."
        exit 1
      fi
      ;;
  esac

  ok "Detected: ${PRETTY_NAME:-${ID}} (${DISTRO_FAMILY} family)"
}

init_docker_cmd() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_PREFIX=""
    return
  fi

  if sudo docker compose version >/dev/null 2>&1; then
    DOCKER_PREFIX="sudo"
    return
  fi

  err "Docker is installed but not usable in this shell yet."
  err "You may need to log out and back in, then run the installer again."
  exit 1
}

get_total_ram_gb() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  echo $(( mem_kb / 1024 / 1024 ))
}

get_nvidia_vram_gb() {
  if ! command_exists nvidia-smi; then
    echo ""
    return
  fi

  local max_mb
  max_mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -nr | head -n1 || true)"

  if [[ -z "${max_mb}" || ! "${max_mb}" =~ ^[0-9]+$ ]]; then
    echo ""
    return
  fi

  echo $(( max_mb / 1024 ))
}

check_local_ai_readiness() {
  local ram_gb
  local vram_gb
  local weak_specs="no"

  ram_gb="$(get_total_ram_gb)"
  vram_gb="$(get_nvidia_vram_gb)"

  echo
  log "Checking local AI readiness..."
  echo "Detected system RAM: ${ram_gb} GB"

  if [[ -n "${vram_gb}" ]]; then
    echo "Detected NVIDIA VRAM: ${vram_gb} GB"
  else
    echo "Detected NVIDIA VRAM: unable to verify"
  fi

  echo

  if (( ram_gb < 16 )); then
    warn "This system has less than 16 GB RAM."
    warn "Local AI may be slow, unstable, or fall back heavily to CPU."
    weak_specs="yes"
  else
    ok "System RAM looks reasonable for smaller local models."
  fi

  if [[ -n "${vram_gb}" ]]; then
    if (( vram_gb < 8 )); then
      warn "This GPU has less than 8 GB VRAM."
      warn "We suggest cloud mode for the best experience."
      weak_specs="yes"
    elif (( vram_gb < 16 )); then
      warn "This GPU is suitable for smaller local models like ${DEFAULT_LOCAL_MODEL}."
      warn "Larger models may be slow or timeout."
    else
      ok "This GPU should be suitable for smaller and some larger local models."
    fi
  else
    warn "GPU VRAM could not be verified."
    warn "If you do not have a strong NVIDIA GPU, cloud mode is usually the safer choice."
    weak_specs="yes"
  fi

  if [[ "${weak_specs}" == "yes" ]]; then
    echo
    warn "Your specs may be too low for a smooth local AI experience."
    warn "We suggest cloud mode unless you specifically want to experiment."
    echo

    if ask_yes_no "Switch to cloud mode instead?" "y"; then
      MODE="cloud"
      INSTALL_OLLAMA="no"
    fi
  fi
}

check_port_available() {
  local port="$1"
  if command_exists ss; then
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      return 1
    fi
  fi
  return 0
}

validate_cloud_key() {
  local key="$1"
  local validate_url=""

  # Build validation endpoint based on provider
  if [[ "${CLOUD_API_TYPE}" == "openai-completions" ]]; then
    validate_url="${CLOUD_BASE_URL}/models"
  else
    # Anthropic and others: skip live validation
    ok "API key accepted (no live validation for this provider)."
    return 0
  fi

  log "Validating API key against ${CLOUD_BASE_URL}..."
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${key}" \
    "${validate_url}" 2>/dev/null || echo "000")"

  if [[ "${http_code}" == "200" ]]; then
    ok "API key is valid."
    return 0
  elif [[ "${http_code}" == "401" ]]; then
    err "API key is invalid or expired."
    return 1
  else
    warn "Could not verify API key (HTTP ${http_code}). Proceeding anyway."
    return 0
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local reply=""

  while true; do
    if [[ "${default}" == "y" ]]; then
      read -r -p "${prompt} [Y/n]: " reply
      reply="${reply:-Y}"
    else
      read -r -p "${prompt} [y/N]: " reply
      reply="${reply:-N}"
    fi

    case "${reply}" in
      Y|y|yes|YES) return 0 ;;
      N|n|no|NO)   return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " value
    echo "${value:-$default}"
  else
    read -r -p "${prompt}: " value
    echo "${value}"
  fi
}

ask_secret() {
  local prompt="$1"
  local value=""
  read -r -s -p "${prompt}: " value
  echo >&2  # newline after hidden input
  if [[ -n "${value}" ]]; then
    # Show masked preview: first 4 chars + **** + last 4 chars
    local len=${#value}
    if (( len > 10 )); then
      local masked="${value:0:4}$( printf '*%.0s' {1..8} )${value: -4}"
      echo "  Key entered: ${masked}" >&2
    else
      echo "  Key entered: ********" >&2
    fi
  fi
  echo "${value}"
}

validate_port() {
  [[ "${1}" =~ ^[0-9]+$ ]] || return 1
  (( "$1" >= 1 && "$1" <= 65535 )) || return 1
  return 0
}

select_main_menu() {
  echo >&2
  echo -e "  ${CLR_DIM}┌──────────────────────────────────────────────────────┐${CLR_RESET}" >&2
  echo -e "  ${CLR_DIM}│${CLR_RESET}  1) Install / Update       5) Skills Manager         ${CLR_DIM}│${CLR_RESET}" >&2
  echo -e "  ${CLR_DIM}│${CLR_RESET}  2) Troubleshoot           6) Backup & Restore       ${CLR_DIM}│${CLR_RESET}" >&2
  echo -e "  ${CLR_DIM}│${CLR_RESET}  3) Device Pairing         7) Uninstall OpenClaw     ${CLR_DIM}│${CLR_RESET}" >&2
  echo -e "  ${CLR_DIM}│${CLR_RESET}  4) Model Manager          8) Exit                   ${CLR_DIM}│${CLR_RESET}" >&2
  echo -e "  ${CLR_DIM}└──────────────────────────────────────────────────────┘${CLR_RESET}" >&2
  echo >&2
  ask_input "  Choose an option" "1"
}

select_mode() {
  echo
  echo "Install mode:"
  echo "1) Cloud only"
  echo "2) Local AI"
  echo "3) Hybrid (local + cloud fallback)"
  echo
  local choice
  choice="$(ask_input "Choose a mode" "1")"

  case "${choice}" in
    1) MODE="cloud" ;;
    2) MODE="local" ;;
    3) MODE="hybrid" ;;
    *) MODE="cloud" ;;
  esac
}

select_local_model() {
  echo >&2
  echo "Local AI model:" >&2
  echo "1) qwen2.5:7b-instruct    (4.7 GB, recommended for 8 GB VRAM)" >&2
  echo "2) qwen2.5:14b-instruct   (9.0 GB, needs 12+ GB VRAM)" >&2
  echo "3) qwen2.5:3b-instruct    (1.9 GB, lightweight, weaker)" >&2
  echo "4) gemma4:e2b              (7.2 GB, 5.1B params, multimodal)" >&2
  echo "5) gemma4:e4b              (9.6 GB, 8B params, multimodal)" >&2
  echo "6) gemma4:26b              (18 GB, MoE, needs 24+ GB VRAM)" >&2
  echo "7) gpt-oss:20b            (12 GB, needs 16+ GB VRAM)" >&2
  echo "8) Enter a custom model name" >&2
  echo >&2
  local choice
  choice="$(ask_input "Choose a model" "1")"

  case "${choice}" in
    1) echo "qwen2.5:7b-instruct" ;;
    2) echo "qwen2.5:14b-instruct" ;;
    3) echo "qwen2.5:3b-instruct" ;;
    4) echo "gemma4:e2b" ;;
    5) echo "gemma4:e4b" ;;
    6) echo "gemma4:26b" ;;
    7) echo "gpt-oss:20b" ;;
    8) ask_input "Enter model name (e.g. llama3.1:8b)" ;;
    *) echo "qwen2.5:7b-instruct" ;;
  esac
}

select_cloud_provider() {
  echo >&2
  echo "Cloud AI provider:" >&2
  echo "1) OpenAI          (GPT-4o, GPT-4.1)" >&2
  echo "2) Anthropic       (Claude Haiku, Sonnet)" >&2
  echo "3) Groq            (fast inference, free tier)" >&2
  echo "4) OpenRouter      (access to 200+ models)" >&2
  echo "5) Google Gemini   (Gemini 2.0 Flash, Pro)" >&2
  echo >&2
  local choice
  choice="$(ask_input "Choose a provider" "1")"

  case "${choice}" in
    1)
      CLOUD_PROVIDER="openai"
      CLOUD_BASE_URL="https://api.openai.com/v1"
      CLOUD_API_ENV_NAME="OPENAI_API_KEY"
      CLOUD_API_TYPE="openai-completions"
      CLOUD_CONTEXT_WINDOW=128000
      ;;
    2)
      CLOUD_PROVIDER="anthropic"
      CLOUD_BASE_URL="https://api.anthropic.com"
      CLOUD_API_ENV_NAME="ANTHROPIC_API_KEY"
      CLOUD_API_TYPE="anthropic"
      CLOUD_CONTEXT_WINDOW=200000
      ;;
    3)
      CLOUD_PROVIDER="openai"
      CLOUD_BASE_URL="https://api.groq.com/openai/v1"
      CLOUD_API_ENV_NAME="OPENAI_API_KEY"
      CLOUD_API_TYPE="openai-completions"
      CLOUD_CONTEXT_WINDOW=128000
      ;;
    4)
      CLOUD_PROVIDER="openai"
      CLOUD_BASE_URL="https://openrouter.ai/api/v1"
      CLOUD_API_ENV_NAME="OPENAI_API_KEY"
      CLOUD_API_TYPE="openai-completions"
      CLOUD_CONTEXT_WINDOW=128000
      ;;
    5)
      CLOUD_PROVIDER="openai"
      CLOUD_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai"
      CLOUD_API_ENV_NAME="OPENAI_API_KEY"
      CLOUD_API_TYPE="openai-completions"
      CLOUD_CONTEXT_WINDOW=1048576
      ;;
    *)
      CLOUD_PROVIDER="openai"
      CLOUD_BASE_URL="https://api.openai.com/v1"
      CLOUD_API_ENV_NAME="OPENAI_API_KEY"
      CLOUD_API_TYPE="openai-completions"
      CLOUD_CONTEXT_WINDOW=128000
      ;;
  esac
}

select_cloud_model() {
  if [[ "${CLOUD_BASE_URL}" == *"openai.com"* ]]; then
    echo >&2
    echo "OpenAI model:" >&2
    echo "1) gpt-4o-mini       (cheapest, good for most tasks)" >&2
    echo "2) gpt-4o            (stronger, more expensive)" >&2
    echo "3) gpt-4.1-mini      (latest mini, balanced)" >&2
    echo "4) gpt-4.1           (latest flagship)" >&2
    echo "5) Enter a custom model name" >&2
    echo >&2
    local choice
    choice="$(ask_input "Choose a model" "1")"
    case "${choice}" in
      1) echo "gpt-4o-mini" ;; 2) echo "gpt-4o" ;;
      3) echo "gpt-4.1-mini" ;; 4) echo "gpt-4.1" ;;
      5) ask_input "Enter model name" ;; *) echo "gpt-4o-mini" ;;
    esac

  elif [[ "${CLOUD_BASE_URL}" == *"anthropic.com"* ]]; then
    echo >&2
    echo "Anthropic model:" >&2
    echo "1) claude-haiku-4-5   (fast, cheapest Claude)" >&2
    echo "2) claude-sonnet-4-6  (balanced, strong reasoning)" >&2
    echo "3) claude-opus-4-6    (most capable, expensive)" >&2
    echo "4) Enter a custom model name" >&2
    echo >&2
    local choice
    choice="$(ask_input "Choose a model" "1")"
    case "${choice}" in
      1) echo "claude-haiku-4-5" ;; 2) echo "claude-sonnet-4-6" ;;
      3) echo "claude-opus-4-6" ;;
      4) ask_input "Enter model name" ;; *) echo "claude-haiku-4-5" ;;
    esac

  elif [[ "${CLOUD_BASE_URL}" == *"groq.com"* ]]; then
    echo >&2
    echo "Groq model:" >&2
    echo "1) llama-3.3-70b-versatile   (strong, fast)" >&2
    echo "2) llama-3.1-8b-instant      (lightweight, fastest)" >&2
    echo "3) gemma2-9b-it              (good all-rounder)" >&2
    echo "4) Enter a custom model name" >&2
    echo >&2
    local choice
    choice="$(ask_input "Choose a model" "1")"
    case "${choice}" in
      1) echo "llama-3.3-70b-versatile" ;; 2) echo "llama-3.1-8b-instant" ;;
      3) echo "gemma2-9b-it" ;;
      4) ask_input "Enter model name" ;; *) echo "llama-3.3-70b-versatile" ;;
    esac

  elif [[ "${CLOUD_BASE_URL}" == *"openrouter.ai"* ]]; then
    echo >&2
    echo "OpenRouter model:" >&2
    echo "1) openai/gpt-4o-mini              (cheapest GPT)" >&2
    echo "2) anthropic/claude-sonnet-4-6      (strong reasoning)" >&2
    echo "3) google/gemini-2.0-flash          (fast, cheap)" >&2
    echo "4) meta-llama/llama-3.3-70b         (open source)" >&2
    echo "5) Enter a custom model name" >&2
    echo >&2
    local choice
    choice="$(ask_input "Choose a model" "1")"
    case "${choice}" in
      1) echo "openai/gpt-4o-mini" ;; 2) echo "anthropic/claude-sonnet-4-6" ;;
      3) echo "google/gemini-2.0-flash" ;; 4) echo "meta-llama/llama-3.3-70b" ;;
      5) ask_input "Enter model name (provider/model format)" ;; *) echo "openai/gpt-4o-mini" ;;
    esac

  elif [[ "${CLOUD_BASE_URL}" == *"googleapis.com"* ]]; then
    echo >&2
    echo "Google Gemini model:" >&2
    echo "1) gemini-2.0-flash   (fast, cheap)" >&2
    echo "2) gemini-2.0-pro     (stronger reasoning)" >&2
    echo "3) gemini-1.5-flash   (budget option)" >&2
    echo "4) Enter a custom model name" >&2
    echo >&2
    local choice
    choice="$(ask_input "Choose a model" "1")"
    case "${choice}" in
      1) echo "gemini-2.0-flash" ;; 2) echo "gemini-2.0-pro" ;;
      3) echo "gemini-1.5-flash" ;;
      4) ask_input "Enter model name" ;; *) echo "gemini-2.0-flash" ;;
    esac

  else
    ask_input "Enter model name"
  fi
}

wizard_install_questions() {
  local detected_ip
  detected_ip="$(detect_server_ip)"
  GATEWAY_TOKEN="$(generate_gateway_token)"

  echo
  if [[ -n "${detected_ip}" ]]; then
    echo "Detected server IP: ${detected_ip}"
    if ask_yes_no "Use this detected IP?" "y"; then
      SERVER_IP="${detected_ip}"
    else
      SERVER_IP="$(ask_input "Enter your server LAN IP")"
    fi
  else
    warn "Could not auto-detect server IP."
    SERVER_IP="$(ask_input "Enter your server LAN IP")"
  fi

  select_mode

  if [[ "${MODE}" == "local" || "${MODE}" == "hybrid" ]]; then
    check_local_ai_readiness
  fi

  echo
  while true; do
    OPENCLAW_PORT="$(ask_input "Enter HTTPS port" "${DEFAULT_PORT}")"
    if ! validate_port "${OPENCLAW_PORT}"; then
      warn "Please enter a valid port between 1 and 65535."
      continue
    fi
    if ! check_port_available "${OPENCLAW_PORT}"; then
      warn "Port ${OPENCLAW_PORT} is already in use. Choose a different port."
      continue
    fi
    break
  done

  echo
  if docker_present; then
    ok "Docker and Docker Compose detected."
    INSTALL_DOCKER="no"
  else
    if ask_yes_no "Docker was not detected. Install Docker for you?" "y"; then
      INSTALL_DOCKER="yes"
    else
      INSTALL_DOCKER="no"
    fi
  fi

  if [[ "${MODE}" == "local" || "${MODE}" == "hybrid" ]]; then
    echo
    if ollama_present; then
      local ollama_ver
      ollama_ver="$(ollama --version 2>/dev/null | awk '{print $NF}' || true)"
      ok "Ollama detected (${ollama_ver:-unknown version})."
      INSTALL_OLLAMA="no"
    else
      if ask_yes_no "Ollama was not detected. Install Ollama for you?" "y"; then
        INSTALL_OLLAMA="yes"
      else
        INSTALL_OLLAMA="no"
      fi
    fi
    LOCAL_MODEL="$(select_local_model)"
  else
    INSTALL_OLLAMA="no"
  fi

  if [[ "${MODE}" == "cloud" || "${MODE}" == "hybrid" ]]; then
    select_cloud_provider
    echo
    while true; do
      CLOUD_API_KEY="$(ask_secret "Enter your ${CLOUD_PROVIDER} API key")"
      if [[ -z "${CLOUD_API_KEY}" ]]; then
        warn "API key cannot be empty."
        continue
      fi
      if validate_cloud_key "${CLOUD_API_KEY}"; then
        break
      else
        if ! ask_yes_no "Try a different key?" "y"; then
          err "A valid API key is required for ${MODE} mode."
          exit 1
        fi
      fi
    done
    CLOUD_MODEL="$(select_cloud_model)"
  fi

  echo
  echo -e "${CLR_DIM}---------------- Install Summary ----------------${CLR_RESET}"
  echo "Server IP:      ${SERVER_IP}"
  echo "Port:           ${OPENCLAW_PORT}"
  echo "Mode:           ${MODE}"
  echo "Install Docker: ${INSTALL_DOCKER}"
  echo "Install Ollama: ${INSTALL_OLLAMA}"
  if [[ "${MODE}" == "local" || "${MODE}" == "hybrid" ]]; then
    echo "Local model:    ${LOCAL_MODEL}"
  fi
  if [[ "${MODE}" == "cloud" || "${MODE}" == "hybrid" ]]; then
    echo "Cloud provider: ${CLOUD_PROVIDER} (${CLOUD_BASE_URL})"
    echo "Cloud model:    ${CLOUD_MODEL}"
  fi
  echo "Gateway token:  auto-generated"
  echo -e "${CLR_DIM}-------------------------------------------------${CLR_RESET}"
  echo

  if ! ask_yes_no "Proceed with install?" "y"; then
    warn "Install cancelled."
    exit 0
  fi
}

ensure_base_tools() {
  if ! command_exists curl; then
    err "curl is required."
    exit 1
  fi
  if ! command_exists openssl; then
    err "openssl is required."
    exit 1
  fi
}

install_docker_if_needed() {
  if docker_present; then
    ok "Docker already available."
    init_docker_cmd
    return
  fi

  if [[ "${INSTALL_DOCKER}" != "yes" ]]; then
    err "Docker is required but was not found."
    err "Re-run and allow Docker install, or install Docker manually first."
    exit 1
  fi

  log "Installing Docker and Docker Compose..."

  case "${DISTRO_FAMILY}" in
    debian)
      sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
      sudo apt update
      sudo apt install -y ca-certificates curl gnupg

      # Determine the right Docker repo base (ubuntu or debian)
      local docker_repo_distro="ubuntu"
      case "${DISTRO_ID}" in
        debian|kali) docker_repo_distro="debian" ;;
        *) docker_repo_distro="ubuntu" ;;
      esac

      # Use UBUNTU_CODENAME if available (works for most Ubuntu derivatives)
      local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      if [[ -z "${codename}" ]]; then
        err "Could not determine distro codename for Docker repo."
        exit 1
      fi

      sudo install -m 0755 -d /etc/apt/keyrings
      if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${docker_repo_distro}/gpg" | \
          sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      fi
      sudo chmod a+r /etc/apt/keyrings/docker.gpg

      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_repo_distro} \
        ${codename} stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

      sudo apt update
      sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;

    fedora)
      sudo dnf remove -y docker docker-client docker-client-latest docker-common \
        docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

      # Determine the right Docker repo (fedora or centos for RHEL derivatives)
      local docker_repo_distro="fedora"
      case "${DISTRO_ID}" in
        fedora|nobara) docker_repo_distro="fedora" ;;
        *) docker_repo_distro="centos" ;;
      esac

      sudo dnf install -y dnf-plugins-core
      sudo dnf config-manager --add-repo "https://download.docker.com/linux/${docker_repo_distro}/docker-ce.repo" || true
      sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;

    arch)
      sudo pacman -Sy --noconfirm docker docker-compose docker-buildx
      ;;
  esac

  sudo systemctl enable --now docker

  if [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
    sudo usermod -aG docker "${USER}" || true
    warn "Added ${USER} to docker group."
    warn "If Docker access is flaky later, log out and back in."
    # Group change requires re-login, so force sudo for this session
    DOCKER_PREFIX="sudo"
  fi

  if [[ -z "${DOCKER_PREFIX}" ]]; then
    init_docker_cmd
  fi
  ok "Docker installed."
}

install_ollama_if_needed() {
  if [[ "${MODE}" != "local" && "${MODE}" != "hybrid" ]]; then
    log "Cloud mode selected. Skipping Ollama."
    return
  fi

  if ollama_present; then
    ok "Using existing Ollama install."
  else
    if [[ "${INSTALL_OLLAMA}" != "yes" ]]; then
      err "Ollama is required for ${MODE} mode but was not found."
      exit 1
    fi
    log "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed."
  fi

  log "Configuring Ollama to listen on all interfaces..."
  sudo mkdir -p /etc/systemd/system/ollama.service.d

  local override_file="/etc/systemd/system/ollama.service.d/override.conf"
  if [[ -f "${override_file}" ]]; then
    if grep -q 'OLLAMA_HOST=0.0.0.0' "${override_file}" 2>/dev/null; then
      ok "OLLAMA_HOST=0.0.0.0 already set in override."
    else
      # Existing override with other settings, append our line
      warn "Existing Ollama override found. Appending OLLAMA_HOST setting."
      echo 'Environment="OLLAMA_HOST=0.0.0.0"' | sudo tee -a "${override_file}" >/dev/null
    fi
  else
    cat <<'EOF' | sudo tee "${override_file}" >/dev/null
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable --now ollama
  sudo systemctl restart ollama

  if ! systemctl is-active --quiet ollama; then
    err "Ollama failed to start."
    exit 1
  fi

  log "Pulling model: ${LOCAL_MODEL}"
  ollama_pull_or_update "${LOCAL_MODEL}"
  ok "Ollama ready."
}

create_dirs() {
  mkdir -p "${CERT_DIR}" "${NGINX_DIR}" "${CONFIG_DIR}"
  ok "Project directories created."
}

generate_cert() {
  log "Generating self-signed certificate..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${CERT_DIR}/key.pem" \
    -out "${CERT_DIR}/cert.pem" \
    -subj "/CN=${SERVER_IP}" >/dev/null 2>&1
  ok "Certificate created."
}

write_nginx_config() {
  cat > "${NGINX_DIR}/default.conf" <<EOF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;

    location / {
        proxy_pass http://openclaw:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
EOF
  ok "nginx config written."
}

write_compose_file() {
  # Write sensitive values to .env file (docker compose reads this automatically)
  {
    echo "# OpenClaw environment - contains sensitive keys"
    echo "# Generated by opnForum OpenClaw Wizard"
    echo "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"
    if [[ "${MODE}" == "local" || "${MODE}" == "hybrid" ]]; then
      echo "OLLAMA_BASE_URL=http://${SERVER_IP}:11434"
      echo "OLLAMA_API_KEY=ollama-local"
    fi
    if [[ "${MODE}" == "cloud" || "${MODE}" == "hybrid" ]]; then
      echo "${CLOUD_API_ENV_NAME}=${CLOUD_API_KEY}"
    fi
    if [[ "${MODE}" == "local" ]]; then
      echo "OPENAI_API_KEY=unused-local-only"
    fi
  } > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  ok ".env file written (API keys stored here)."

  # Build environment references for compose (reads from .env)
  local extra_env=""
  if [[ "${MODE}" == "local" || "${MODE}" == "hybrid" ]]; then
    extra_env="${extra_env}
      - OLLAMA_BASE_URL
      - OLLAMA_API_KEY"
  fi
  if [[ "${MODE}" == "cloud" || "${MODE}" == "hybrid" ]]; then
    extra_env="${extra_env}
      - ${CLOUD_API_ENV_NAME}"
  fi
  if [[ "${MODE}" == "local" ]]; then
    extra_env="${extra_env}
      - OPENAI_API_KEY"
  fi

  cat > "${COMPOSE_FILE}" <<EOF
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: openclaw-proxy
    restart: always
    ports:
      - "${OPENCLAW_PORT}:443"
    volumes:
      - ./certs:/etc/nginx/certs:ro
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - openclaw

  openclaw:
    image: ghcr.io/coollabsio/openclaw:latest
    container_name: openclaw
    restart: always
    env_file: .env
    environment:
      - OPENCLAW_GATEWAY_TOKEN
      - OPENCLAW_GATEWAY_BIND=auto
      - OPENCLAW_GATEWAY_MODE=local
      - OPENCLAW_NO_RESPAWN=1
      - NODE_COMPILE_CACHE=/data/.openclaw/compile-cache${extra_env}
    volumes:
      - ${CONFIG_DIR}:/data/.openclaw
    depends_on:
      - browser

  browser:
    image: ghcr.io/coollabsio/openclaw-browser:latest
    container_name: openclaw-browser
    restart: always
    shm_size: "2g"
    environment:
      - CONNECTION_TIMEOUT=60000
EOF

  chmod 644 "${COMPOSE_FILE}"
  ok "docker-compose.yml written (no secrets in this file)."
}

write_json_config() {
  local model_json=""
  local providers_json=""

  if [[ "${MODE}" == "local" ]]; then
    model_json=$(cat <<EOF
        "primary": "ollama/${LOCAL_MODEL}"
EOF
)
    providers_json=$(cat <<EOF
      "ollama": {
        "api": "openai-completions",
        "baseUrl": "http://${SERVER_IP}:11434/v1",
        "models": [
          {
            "id": "${LOCAL_MODEL}",
            "name": "${LOCAL_MODEL}",
            "contextWindow": 8192
          }
        ]
      }
EOF
)
  elif [[ "${MODE}" == "hybrid" ]]; then
    model_json=$(cat <<EOF
        "primary": "ollama/${LOCAL_MODEL}",
        "fallbacks": ["${CLOUD_PROVIDER}/${CLOUD_MODEL}"]
EOF
)
    providers_json=$(cat <<EOF
      "ollama": {
        "api": "openai-completions",
        "baseUrl": "http://${SERVER_IP}:11434/v1",
        "models": [
          {
            "id": "${LOCAL_MODEL}",
            "name": "${LOCAL_MODEL}",
            "contextWindow": 8192
          }
        ]
      },
      "${CLOUD_PROVIDER}": {
        "api": "${CLOUD_API_TYPE}",
        "baseUrl": "${CLOUD_BASE_URL}",
        "models": [
          {
            "id": "${CLOUD_MODEL}",
            "name": "${CLOUD_MODEL}",
            "contextWindow": ${CLOUD_CONTEXT_WINDOW}
          }
        ]
      }
EOF
)
  else
    model_json=$(cat <<EOF
        "primary": "${CLOUD_PROVIDER}/${CLOUD_MODEL}"
EOF
)
    providers_json=$(cat <<EOF
      "${CLOUD_PROVIDER}": {
        "api": "${CLOUD_API_TYPE}",
        "baseUrl": "${CLOUD_BASE_URL}",
        "models": [
          {
            "id": "${CLOUD_MODEL}",
            "name": "${CLOUD_MODEL}",
            "contextWindow": ${CLOUD_CONTEXT_WINDOW}
          }
        ]
      }
EOF
)
  fi

  sudo tee "${CONFIG_FILE}" > /dev/null <<EOF
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    },
    "controlUi": {
      "allowInsecureAuth": true,
      "allowedOrigins": ["https://${SERVER_IP}:${OPENCLAW_PORT}"],
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "enabled": true
    },
    "trustedProxies": ["127.0.0.1", "::1", "0.0.0.0/0"],
    "bind": "auto"
  },
  "agents": {
    "defaults": {
      "workspace": "/data/workspace",
      "memorySearch": {
        "enabled": false
      },
      "model": {
${model_json}
      }
    }
  },
  "models": {
    "providers": {
${providers_json}
    }
  }
}
EOF
  sudo chmod 600 "${CONFIG_FILE}"
  ok "openclaw.json written."
}

launch_stack() {
  cd "${PROJECT_DIR}"
  log "Starting OpenClaw..."
  docker_cmd compose up -d

  log "Waiting for first boot (this takes about 60 seconds)..."
  sleep 60

  log "Restarting OpenClaw so config persists..."
  docker_cmd restart openclaw >/dev/null
  sleep 5

  ok "OpenClaw started."
}

update_openclaw() {
  log "Updating OpenClaw..."
  echo

  if ! docker_present; then
    err "Docker is not available."
    pause
    return
  fi

  init_docker_cmd
  cd "${PROJECT_DIR}"

  log "Pulling latest container images..."
  docker_cmd compose pull
  echo

  log "Restarting stack with new images..."
  docker_cmd compose down >/dev/null 2>&1
  docker_cmd compose up -d >/dev/null 2>&1

  log "Waiting for first boot (60 seconds)..."
  sleep 60

  docker_cmd restart openclaw >/dev/null
  sleep 5

  echo
  ok "OpenClaw updated to latest version."
  echo
  echo "Helpful commands:"
  echo "  docker logs openclaw --tail 30"
  echo "  docker ps"

  pause
}

install_flow() {
  print_banner
  ensure_base_tools

  # Detect existing installation
  if [[ -d "${PROJECT_DIR}" || -d "${CONFIG_DIR}" ]]; then
    local openclaw_running="no"
    if docker_present; then
      init_docker_cmd
      if docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -q "^openclaw$"; then
        openclaw_running="yes"
      fi
    fi

    echo
    log "Existing OpenClaw installation detected."
    if [[ "${openclaw_running}" == "yes" ]]; then
      ok "OpenClaw is currently running."
    else
      warn "OpenClaw is not running."
    fi
    echo
    echo "1) Update OpenClaw (pull latest images, keep config)"
    echo "2) Fresh install (overwrite everything)"
    echo "3) Cancel"
    echo
    local update_choice
    update_choice="$(ask_input "Choose an option" "1")"

    case "${update_choice}" in
      1)
        update_openclaw
        return
        ;;
      2)
        warn "This will overwrite your current installation."
        echo
        if ! ask_yes_no "Continue with fresh install?" "n"; then
          warn "Install cancelled."
          return
        fi
        ;;
      3)
        return
        ;;
      *)
        warn "Invalid selection."
        return
        ;;
    esac
  fi

  wizard_install_questions

  if [[ "${MODE}" == "cloud" || "${MODE}" == "hybrid" ]]; then
    if [[ -z "${CLOUD_API_KEY}" ]]; then
      err "An API key is required for ${MODE} mode."
      exit 1
    fi
  fi

  install_docker_if_needed
  install_ollama_if_needed
  create_dirs
  generate_cert
  write_nginx_config
  write_compose_file
  write_json_config
  launch_stack

  echo
  echo -e "${CLR_DIM}============================================================${CLR_RESET}"
  echo -e "${CLR_GREEN}Install complete.${CLR_RESET}"
  echo
  echo "Your OpenClaw URL:"
  echo "  https://${SERVER_IP}:${OPENCLAW_PORT}"
  echo
  echo "Token URL (copy this into your browser):"
  echo -e "  ${CLR_ORANGE}https://${SERVER_IP}:${OPENCLAW_PORT}/#token=${GATEWAY_TOKEN}${CLR_RESET}"
  echo
  echo "Gateway token:"
  echo "  ${GATEWAY_TOKEN}"
  echo
  echo "Helpful commands:"
  echo "  docker ps"
  echo "  docker logs openclaw --tail 50"
  echo "  docker exec openclaw openclaw devices list"
  echo
  echo -e "${CLR_DIM}You can retrieve this info later from: Troubleshoot (option 2)${CLR_RESET}"
  echo -e "${CLR_DIM}============================================================${CLR_RESET}"
  echo

  echo "Next step: Open your browser to the URL above, connect,"
  echo "and then come back here to approve the device."
  echo

  if ask_yes_no "Open the device pairing manager now?" "y"; then
    pairing_flow
  else
    pause
  fi
}

pairing_flow() {
  print_banner
  log "Device Pairing Manager"
  echo

  if ! docker_present; then
    err "Docker is not available."
    pause
    return
  fi

  init_docker_cmd

  if ! docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -q "^openclaw$"; then
    err "OpenClaw container is not running."
    pause
    return
  fi

  while true; do
    echo
    log "Pending device requests:"
    echo
    docker_cmd exec openclaw openclaw devices list 2>/dev/null || warn "Could not retrieve device list."

    echo
    echo "a) Approve a device"
    echo "r) Refresh list"
    echo "b) Back to main menu"
    echo
    local action
    action="$(ask_input "Choose an action" "r")"

    case "${action}" in
      a|A)
        local request_id
        request_id="$(ask_input "Enter the request ID to approve")"
        if [[ -n "${request_id}" ]]; then
          docker_cmd exec openclaw openclaw devices approve "${request_id}" 2>/dev/null && \
            ok "Device approved." || err "Failed to approve device."
        else
          warn "No request ID entered."
        fi
        ;;
      r|R)
        continue
        ;;
      b|B)
        return
        ;;
      *)
        warn "Invalid selection."
        ;;
    esac
  done
}

model_manager_flow() {
  print_banner
  log "Model Manager"
  echo

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    err "No OpenClaw config found at ${CONFIG_FILE}."
    err "Run the installer first."
    pause
    return
  fi

  if ! docker_present; then
    err "Docker is not available."
    pause
    return
  fi

  init_docker_cmd

  # Read current config values
  local current_primary
  current_primary="$(sudo grep -o '"primary": *"[^"]*"' "${CONFIG_FILE}" | head -1 | sed 's/.*"primary": *"//' | sed 's/"//' || true)"
  local current_fallback
  current_fallback="$(sudo grep -o '"fallbacks": *\["[^"]*"\]' "${CONFIG_FILE}" | head -1 | sed 's/.*\["//' | sed 's/"\]//' || true)"

  # Detect current cloud provider name from config
  local current_cloud_provider=""
  local has_ollama_provider has_cloud_provider
  has_ollama_provider="$(sudo grep -c '"ollama"' "${CONFIG_FILE}" || true)"

  # Check for known cloud providers in the config JSON
  for p in openai anthropic; do
    if sudo grep -q "\"${p}\"" "${CONFIG_FILE}" 2>/dev/null; then
      if sudo grep -A2 "\"${p}\"" "${CONFIG_FILE}" | grep -q '"api"'; then
        current_cloud_provider="${p}"
        break
      fi
    fi
  done

  # If no provider section found, check fallback model reference
  # OpenClaw strips built-in providers from the JSON but keeps the fallback reference
  if [[ -z "${current_cloud_provider}" && -n "${current_fallback}" ]]; then
    current_cloud_provider="${current_fallback%%/*}"
  fi

  # Last resort: check compose file for cloud API key env vars
  if [[ -z "${current_cloud_provider}" && -f "${COMPOSE_FILE}" ]]; then
    if sudo grep -q "OPENAI_API_KEY=" "${COMPOSE_FILE}" 2>/dev/null; then
      if ! sudo grep -q "OPENAI_API_KEY=unused-local-only" "${COMPOSE_FILE}" 2>/dev/null; then
        current_cloud_provider="openai"
      fi
    elif sudo grep -q "ANTHROPIC_API_KEY=" "${COMPOSE_FILE}" 2>/dev/null; then
      current_cloud_provider="anthropic"
    fi
  fi

  if [[ -n "${current_cloud_provider}" ]]; then
    has_cloud_provider=1
  else
    has_cloud_provider=0
  fi

  echo "  Current primary model:  ${current_primary:-unknown}"
  if [[ -n "${current_fallback}" ]]; then
    echo "  Current fallback model: ${current_fallback}"
  fi
  if [[ -n "${current_cloud_provider}" ]]; then
    echo "  Current cloud provider: ${current_cloud_provider}"
  fi
  echo

  # Read preserved values from existing config
  GATEWAY_TOKEN="$(sudo grep -o '"token": *"[^"]*"' "${CONFIG_FILE}" | head -1 | sed 's/.*"token": *"//' | sed 's/"//' || true)"
  SERVER_IP="$(sudo grep -o 'https://[^:]*:[0-9]*' "${CONFIG_FILE}" | head -1 | sed 's|https://||' | sed 's|:.*||' || true)"
  OPENCLAW_PORT="$(sudo grep -o 'https://[^:]*:[0-9]*' "${CONFIG_FILE}" | head -1 | sed 's|.*:||' || true)"

  if [[ -z "${GATEWAY_TOKEN}" || -z "${SERVER_IP}" || -z "${OPENCLAW_PORT}" ]]; then
    err "Could not read existing config values."
    err "Gateway token, server IP, or port missing from config."
    pause
    return
  fi

  echo "What would you like to change?"
  echo "1) Switch local model"
  echo "2) Switch cloud model / provider"
  echo "3) Switch both"
  echo "4) Back to main menu"
  echo
  local choice
  choice="$(ask_input "Choose an option" "4")"

  case "${choice}" in
    1)
      if (( has_ollama_provider == 0 )); then
        err "No local model configured. Your setup is cloud-only."
        err "To add a local model, reinstall in local or hybrid mode."
        pause
        return
      fi
      LOCAL_MODEL="$(select_local_model)"
      echo
      log "Pulling ${LOCAL_MODEL}..."
      ollama_pull_or_update "${LOCAL_MODEL}"
      ok "Model downloaded."

      # Update primary in config
      local old_primary_line new_primary_line
      old_primary_line="$(sudo grep '"primary":' "${CONFIG_FILE}")"
      if [[ "${current_primary}" == ollama/* ]]; then
        new_primary_line="${old_primary_line//$current_primary/ollama/${LOCAL_MODEL}}"
      else
        new_primary_line="${old_primary_line}"
      fi
      sudo sed -i "s|${old_primary_line}|${new_primary_line}|" "${CONFIG_FILE}"

      # Update ollama model id and name
      sudo sed -i "s|\"id\": \"${current_primary#ollama/}\"|\"id\": \"${LOCAL_MODEL}\"|" "${CONFIG_FILE}"
      sudo sed -i "s|\"name\": \"${current_primary#ollama/}\"|\"name\": \"${LOCAL_MODEL}\"|" "${CONFIG_FILE}"

      echo
      log "Restarting OpenClaw..."
      docker_cmd restart openclaw >/dev/null
      sleep 5
      ok "Model switched to ollama/${LOCAL_MODEL}."
      ;;
    2)
      if (( has_cloud_provider == 0 )); then
        err "No cloud model configured. Your setup is local-only."
        err "To add a cloud model, reinstall in cloud or hybrid mode."
        pause
        return
      fi

      select_cloud_provider
      CLOUD_MODEL="$(select_cloud_model)"

      # Detect if provider actually changed by comparing base URLs
      local old_base_url
      old_base_url="$(sudo grep -o '"baseUrl": *"[^"]*"' "${CONFIG_FILE}" | grep -v "11434" | head -1 | sed 's/.*"baseUrl": *"//' | sed 's/"//' || true)"
      local provider_changed="no"
      if [[ "${old_base_url}" != "${CLOUD_BASE_URL}" ]]; then
        provider_changed="yes"
      fi

      # Only ask for new API key if provider changed
      if [[ "${provider_changed}" == "yes" ]]; then
        echo
        while true; do
          CLOUD_API_KEY="$(ask_secret "Enter your ${CLOUD_PROVIDER} API key")"
          if [[ -z "${CLOUD_API_KEY}" ]]; then
            warn "API key cannot be empty."
            continue
          fi
          if validate_cloud_key "${CLOUD_API_KEY}"; then
            break
          else
            if ! ask_yes_no "Try a different key?" "y"; then
              warn "Cloud switch cancelled."
              pause
              return
            fi
          fi
        done
      fi

      echo

      # Extract local model if in hybrid mode
      if [[ "${current_primary}" == ollama/* ]]; then
        LOCAL_MODEL="${current_primary#ollama/}"
        MODE="hybrid"
      else
        MODE="cloud"
      fi

      # Rewrite full JSON config
      write_json_config

      # Update .env file and full restart only if provider changed
      if [[ "${provider_changed}" == "yes" ]]; then
        # Remove old cloud API key from .env (keep OLLAMA keys)
        sudo sed -i '/_API_KEY=/{/OLLAMA_API_KEY/!d}' "${ENV_FILE}"
        # Add new cloud API key
        echo "${CLOUD_API_ENV_NAME}=${CLOUD_API_KEY}" | sudo tee -a "${ENV_FILE}" >/dev/null
        sudo chmod 600 "${ENV_FILE}"

        echo
        log "Provider changed. Restarting full stack..."
        cd "${PROJECT_DIR}"
        docker_cmd compose down >/dev/null 2>&1
        docker_cmd compose up -d >/dev/null 2>&1
        sleep 10
        docker_cmd restart openclaw >/dev/null
        sleep 5
      else
        echo
        log "Restarting OpenClaw..."
        docker_cmd restart openclaw >/dev/null
        sleep 5
      fi
      ok "Cloud switched to ${CLOUD_PROVIDER}/${CLOUD_MODEL}."
      ;;
    3)
      if (( has_ollama_provider == 0 )); then
        err "No local model configured. Can only switch cloud model."
        pause
        return
      fi
      if (( has_cloud_provider == 0 )); then
        err "No cloud model configured. Can only switch local model."
        pause
        return
      fi

      LOCAL_MODEL="$(select_local_model)"
      select_cloud_provider
      CLOUD_MODEL="$(select_cloud_model)"

      # Detect if provider actually changed
      local old_base_url
      old_base_url="$(sudo grep -o '"baseUrl": *"[^"]*"' "${CONFIG_FILE}" | grep -v "11434" | head -1 | sed 's/.*"baseUrl": *"//' | sed 's/"//' || true)"
      local provider_changed="no"
      if [[ "${old_base_url}" != "${CLOUD_BASE_URL}" ]]; then
        provider_changed="yes"
      fi

      # Only ask for new API key if provider changed
      if [[ "${provider_changed}" == "yes" ]]; then
        echo
        while true; do
          CLOUD_API_KEY="$(ask_secret "Enter your ${CLOUD_PROVIDER} API key")"
          if [[ -z "${CLOUD_API_KEY}" ]]; then
            warn "API key cannot be empty."
            continue
          fi
          if validate_cloud_key "${CLOUD_API_KEY}"; then
            break
          else
            if ! ask_yes_no "Try a different key?" "y"; then
              warn "Switch cancelled."
              pause
              return
            fi
          fi
        done
      fi

      echo
      log "Pulling ${LOCAL_MODEL}..."
      ollama_pull_or_update "${LOCAL_MODEL}"
      ok "Model downloaded."

      # Rewrite the full JSON config with new models
      MODE="hybrid"
      write_json_config

      # Update .env file only if provider changed
      if [[ "${provider_changed}" == "yes" ]]; then
        sudo sed -i '/_API_KEY=/{/OLLAMA_API_KEY/!d}' "${ENV_FILE}"
        echo "${CLOUD_API_ENV_NAME}=${CLOUD_API_KEY}" | sudo tee -a "${ENV_FILE}" >/dev/null
        sudo chmod 600 "${ENV_FILE}"
      fi

      echo
      log "Restarting OpenClaw stack..."
      cd "${PROJECT_DIR}"
      docker_cmd compose down >/dev/null 2>&1
      docker_cmd compose up -d >/dev/null 2>&1
      sleep 10
      docker_cmd restart openclaw >/dev/null
      sleep 5
      ok "Models switched: ollama/${LOCAL_MODEL} + ${CLOUD_PROVIDER}/${CLOUD_MODEL}."
      ;;
    4)
      return
      ;;
    *)
      warn "Invalid selection."
      ;;
  esac

  pause
}

skills_flow() {
  print_banner
  log "Skills Manager"
  echo

  if ! docker_present; then
    err "Docker is not available."
    pause
    return
  fi

  init_docker_cmd

  if ! docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -q "^openclaw$"; then
    err "OpenClaw container is not running."
    pause
    return
  fi

  while true; do
    echo "1) Install from featured skills"
    echo "2) Install by ClawHub slug"
    echo "3) Update all installed skills"
    echo "4) Back to main menu"
    echo
    local choice
    choice="$(ask_input "Choose an option" "4")"

    case "${choice}" in
      1)
        echo
        echo -e "${CLR_DIM}──── Featured Skills ────${CLR_RESET}"
        echo " 1) agent-browser-clawdbot   Browser automation agent"
        echo " 2) ontology                 Knowledge graph builder"
        echo " 3) self-improving-agent     Self-optimizing agent"
        echo " 4) word-docx               Word document creation"
        echo " 5) imap-smtp-email          Email send/receive"
        echo " 6) playwright               Web scraping and testing"
        echo " 7) api-gateway              API routing and management"
        echo " 8) moltguard                Molecular safety checker"
        echo " 9) data-analysis            Data analysis toolkit"
        echo "10) polymarket-trade         Prediction market trading"
        echo " 0) Back"
        echo
        local pick
        pick="$(ask_input "Choose a skill" "0")"

        local slug=""
        case "${pick}" in
          1)  slug="matrixy/agent-browser-clawdbot" ;;
          2)  slug="oswalpalash/ontology" ;;
          3)  slug="pskoett/self-improving-agent" ;;
          4)  slug="ivangdavila/word-docx" ;;
          5)  slug="gzlicanyi/imap-smtp-email" ;;
          6)  slug="ivangdavila/playwright" ;;
          7)  slug="byungkyu/api-gateway" ;;
          8)  slug="thomaslwang/moltguard" ;;
          9)  slug="ivangdavila/data-analysis" ;;
          10) slug="joelchance/polymarket-trade" ;;
          0)  continue ;;
          *)  warn "Invalid selection." ; continue ;;
        esac

        echo
        log "Installing ${slug}..."
        if docker_cmd exec openclaw openclaw skills install "${slug}" 2>&1; then
          ok "Skill installed: ${slug}"
        else
          err "Failed to install ${slug}."
          warn "Check https://clawhub.ai/${slug} for details."
        fi
        echo
        ;;
      2)
        echo
        local slug
        slug="$(ask_input "Enter ClawHub slug (e.g. username/skill-name)")"
        if [[ -z "${slug}" ]]; then
          warn "No slug entered."
          continue
        fi
        echo
        log "Installing ${slug}..."
        if docker_cmd exec openclaw openclaw skills install "${slug}" 2>&1; then
          ok "Skill installed: ${slug}"
        else
          err "Failed to install ${slug}."
          warn "Check https://clawhub.ai/${slug} for details."
        fi
        echo
        ;;
      3)
        echo
        log "Updating all installed skills..."
        if docker_cmd exec openclaw openclaw skills update --all 2>&1; then
          ok "All skills updated."
        else
          err "Failed to update skills."
        fi
        echo
        ;;
      4)
        return
        ;;
      *)
        warn "Invalid selection."
        ;;
    esac
  done
}

troubleshoot_flow() {
  print_banner
  log "Running troubleshooting checks..."
  echo

  if docker_present; then
    init_docker_cmd
    ok "Docker is available."
  else
    err "Docker is not available."
    pause
    return
  fi

  echo
  log "Container status:"
  docker_cmd ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

  echo
  log "Checking for known issues in OpenClaw logs..."
  local logs
  logs="$(docker_cmd logs openclaw --tail 100 2>/dev/null || true)"

  if echo "${logs}" | grep -qi "Unknown model"; then
    echo
    err "DETECTED: Unknown model error"
    echo "  OpenClaw can't find your configured model."
    echo "  Fix: Make sure OLLAMA_API_KEY=ollama-local is in your docker-compose.yml"
    echo "  Then: docker compose down && docker compose up -d && sleep 60 && docker restart openclaw"
  fi

  if echo "${logs}" | grep -qi "model_not_found\|fallback.*decision.*candidate_failed"; then
    echo
    warn "DETECTED: Model fallback is activating"
    echo "  Your primary model is failing and OpenClaw is using the fallback."
    echo "  Check: Is Ollama running? (systemctl status ollama)"
    echo "  Check: Is OLLAMA_HOST=0.0.0.0 set? (sudo systemctl cat ollama)"
    echo "  Check: Can Docker reach Ollama? (docker exec openclaw curl -s http://YOUR_IP:11434/api/tags)"
  fi

  if echo "${logs}" | grep -qi "agents.defaults.model.*Invalid input"; then
    echo
    err "DETECTED: Invalid model config"
    echo "  The model section in openclaw.json has a schema error."
    echo "  Fallback must be 'fallbacks' (plural) as an array:"
    echo '  "model": { "primary": "ollama/model", "fallbacks": ["provider/model"] }'
  fi

  if echo "${logs}" | grep -qi "At least one AI provider API key"; then
    echo
    err "DETECTED: Missing API key"
    echo "  OpenClaw requires at least one API key environment variable."
    echo "  For local mode: OLLAMA_API_KEY=ollama-local"
    echo "  For cloud mode: OPENAI_API_KEY, ANTHROPIC_API_KEY, etc."
  fi

  if echo "${logs}" | grep -qi "ECONNREFUSED\|host.docker.internal"; then
    echo
    err "DETECTED: Connection refused to Ollama"
    echo "  Docker can't reach Ollama."
    echo "  Fix: Use your server's LAN IP instead of host.docker.internal"
    echo "  Fix: Make sure Ollama listens on 0.0.0.0 (sudo systemctl edit ollama)"
  fi

  if echo "${logs}" | grep -qi "does not support tools"; then
    echo
    warn "DETECTED: Model doesn't support tool calling"
    echo "  Switch to a model with tool support: Qwen 2.5, Llama 3.1+, or GPT-OSS 20B"
  fi

  if ! echo "${logs}" | grep -qiE "Unknown model|model_not_found|Invalid input|API key|ECONNREFUSED|does not support tools"; then
    echo
    ok "No known issues detected in logs."
  fi

  echo
  log "Full recent logs:"
  echo "${logs}" | tail -30

  echo
  if ollama_present; then
    log "Ollama status:"
    if systemctl is-active --quiet ollama; then
      ok "Ollama service active."
    else
      warn "Ollama service not active."
    fi
    ollama ps 2>/dev/null || true
  else
    warn "Ollama not installed."
  fi

  echo
  log "Config checks:"
  [[ -f "${COMPOSE_FILE}" ]] && ok "Found ${COMPOSE_FILE}" || warn "Missing ${COMPOSE_FILE}"
  [[ -f "${CONFIG_FILE}" ]] && ok "Found ${CONFIG_FILE}" || warn "Missing ${CONFIG_FILE}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    echo
    log "Connection info:"
    local token ip port
    token="$(sudo grep -o '"token": *"[^"]*"' "${CONFIG_FILE}" | head -1 | sed 's/.*"token": *"//' | sed 's/"//' || true)"
    ip="$(sudo grep -o 'https://[^:]*:[0-9]*' "${CONFIG_FILE}" | head -1 | sed 's|https://||' | sed 's|:.*||' || true)"
    port="$(sudo grep -o 'https://[^:]*:[0-9]*' "${CONFIG_FILE}" | head -1 | sed 's|.*:||' || true)"
    if [[ -n "${token}" ]]; then
      echo "  Token:     ${token}"
    else
      warn "Could not read gateway token from config."
      warn "Try: sudo grep token ${CONFIG_FILE}"
    fi
    if [[ -n "${ip}" && -n "${port}" ]]; then
      echo "  URL:       https://${ip}:${port}"
      echo "  Token URL: https://${ip}:${port}/#token=${token}"
    else
      warn "Could not read IP/port from config."
    fi
  fi

  pause
}

backup_restore_flow() {
  print_banner
  log "Backup & Restore"
  echo

  echo "1) Create backup"
  echo "2) Restore from backup"
  echo "3) Back to main menu"
  echo
  local choice
  choice="$(ask_input "Choose an option" "3")"

  case "${choice}" in
    1)
      local backup_dir="${HOME}"
      local timestamp
      timestamp="$(date +%Y%m%d-%H%M%S)"
      local backup_file="${backup_dir}/openclaw-backup-${timestamp}.tar.gz"

      echo
      log "Creating backup..."

      local files_to_backup=""

      if [[ -f "${COMPOSE_FILE}" ]]; then
        files_to_backup="${files_to_backup} ${COMPOSE_FILE}"
      else
        warn "No docker-compose.yml found. Skipping."
      fi

      if [[ -f "${CONFIG_FILE}" ]]; then
        # Copy config to temp with sudo since it may be root-owned
        local tmp_config="/tmp/openclaw-backup-config.json"
        sudo cp "${CONFIG_FILE}" "${tmp_config}"
        sudo chmod 644 "${tmp_config}"
        files_to_backup="${files_to_backup} ${tmp_config}"
      else
        warn "No openclaw.json found. Skipping."
      fi

      if [[ -d "${CERT_DIR}" ]]; then
        files_to_backup="${files_to_backup} ${CERT_DIR}"
      else
        warn "No certs directory found. Skipping."
      fi

      if [[ -d "${NGINX_DIR}" ]]; then
        files_to_backup="${files_to_backup} ${NGINX_DIR}"
      fi

      if [[ -z "${files_to_backup}" ]]; then
        err "Nothing to back up."
        pause
        return
      fi

      # shellcheck disable=SC2086
      tar -czf "${backup_file}" ${files_to_backup} 2>/dev/null
      rm -f /tmp/openclaw-backup-config.json 2>/dev/null

      echo
      ok "Backup created: ${backup_file}"
      echo "  Size: $(du -h "${backup_file}" | awk '{print $1}')"
      echo
      echo "  This file contains your API keys, gateway token, and SSL certs."
      echo "  Keep it safe."
      ;;
    2)
      echo
      local backup_file
      backup_file="$(ask_input "Path to backup file (e.g. ~/openclaw-backup-20260405-120000.tar.gz)")"

      # Expand tilde
      backup_file="${backup_file/#\~/$HOME}"

      if [[ ! -f "${backup_file}" ]]; then
        err "File not found: ${backup_file}"
        pause
        return
      fi

      echo
      warn "This will overwrite your current OpenClaw config, certs, and compose file."
      if ! ask_yes_no "Continue with restore?" "n"; then
        warn "Restore cancelled."
        pause
        return
      fi

      echo
      log "Restoring from ${backup_file}..."

      # Create dirs if they don't exist
      mkdir -p "${CERT_DIR}" "${NGINX_DIR}" "${CONFIG_DIR}"

      tar -xzf "${backup_file}" -C / 2>/dev/null || tar -xzf "${backup_file}" 2>/dev/null

      # If config was backed up from /tmp, move it to the right place
      if [[ -f /tmp/openclaw-backup-config.json ]]; then
        sudo cp /tmp/openclaw-backup-config.json "${CONFIG_FILE}"
        sudo chmod 600 "${CONFIG_FILE}"
        rm -f /tmp/openclaw-backup-config.json
      fi

      ok "Restore complete."
      echo
      if ask_yes_no "Restart OpenClaw to apply?" "y"; then
        if docker_present; then
          init_docker_cmd
          cd "${PROJECT_DIR}"
          docker_cmd compose down >/dev/null 2>&1
          docker_cmd compose up -d >/dev/null 2>&1
          sleep 10
          docker_cmd restart openclaw >/dev/null
          ok "OpenClaw restarted."
        else
          warn "Docker not available. Start OpenClaw manually."
        fi
      fi
      ;;
    3)
      return
      ;;
    *)
      warn "Invalid selection."
      ;;
  esac

  pause
}

uninstall_flow() {
  print_banner
  warn "This will remove OpenClaw containers, images, and config files."
  echo

  if ! ask_yes_no "Continue with uninstall?" "n"; then
    warn "Uninstall cancelled."
    return
  fi

  if docker_present; then
    init_docker_cmd
  fi

  if [[ -d "${PROJECT_DIR}" ]]; then
    cd "${HOME}" || true
    docker_cmd compose -f "${COMPOSE_FILE}" down 2>/dev/null || true
  fi

  docker_cmd rm -f openclaw openclaw-browser openclaw-proxy 2>/dev/null || true
  docker_cmd rmi ghcr.io/coollabsio/openclaw:latest 2>/dev/null || true
  docker_cmd rmi ghcr.io/coollabsio/openclaw-browser:latest 2>/dev/null || true
  docker_cmd rmi nginx:alpine 2>/dev/null || true

  sudo rm -rf "${CONFIG_DIR}" "${PROJECT_DIR}"
  ok "OpenClaw files removed."

  if [[ -f /etc/systemd/system/ollama.service.d/override.conf ]]; then
    if ask_yes_no "Remove Ollama systemd override (OLLAMA_HOST=0.0.0.0)?" "y"; then
      sudo rm -f /etc/systemd/system/ollama.service.d/override.conf
      sudo rmdir /etc/systemd/system/ollama.service.d 2>/dev/null || true
      sudo systemctl daemon-reload
      sudo systemctl restart ollama 2>/dev/null || true
      ok "Ollama override removed."
    fi
  fi

  echo
  if ollama_present; then
    if ask_yes_no "Remove Ollama entirely?" "n"; then
      log "Removing Ollama..."
      sudo systemctl stop ollama 2>/dev/null || true
      sudo systemctl disable ollama 2>/dev/null || true
      sudo rm -f /usr/local/bin/ollama
      sudo rm -rf /usr/share/ollama
      sudo rm -f /etc/systemd/system/ollama.service
      sudo rm -rf /etc/systemd/system/ollama.service.d
      sudo systemctl daemon-reload
      if id ollama >/dev/null 2>&1; then
        sudo userdel ollama 2>/dev/null || true
      fi
      if getent group ollama >/dev/null 2>&1; then
        sudo groupdel ollama 2>/dev/null || true
      fi
      sudo rm -rf /usr/local/lib/ollama
      ok "Ollama removed."
      warn "Downloaded models in ~/.ollama were left in place."
      if ask_yes_no "Remove downloaded models (~/.ollama) too?" "n"; then
        rm -rf "${HOME}/.ollama"
        ok "Models removed."
      fi
    fi
  fi

  if docker_present; then
    echo
    if ask_yes_no "Remove Docker entirely?" "n"; then
      log "Removing Docker..."
      case "${DISTRO_FAMILY}" in
        debian)
          sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
          sudo apt autoremove -y 2>/dev/null || true
          sudo rm -f /etc/apt/sources.list.d/docker.list
          sudo rm -f /etc/apt/keyrings/docker.gpg
          ;;
        fedora)
          sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
          sudo rm -f /etc/yum.repos.d/docker-ce.repo
          ;;
        arch)
          sudo pacman -Rns --noconfirm docker docker-compose docker-buildx 2>/dev/null || true
          ;;
      esac
      sudo rm -rf /var/lib/docker /var/lib/containerd
      ok "Docker removed."
    fi
  fi

  echo
  ok "Uninstall complete."
  pause
}

main() {
  detect_distro
  while true; do
    print_banner
    local choice
    choice="$(select_main_menu)"

    case "${choice}" in
      1) install_flow ;;
      2) troubleshoot_flow ;;
      3) pairing_flow ;;
      4) model_manager_flow ;;
      5) skills_flow ;;
      6) backup_restore_flow ;;
      7) uninstall_flow ;;
      8)
        echo
        exit 0
        ;;
      *)
        warn "Invalid selection."
        pause
        ;;
    esac
  done
}

main

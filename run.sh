#!/bin/bash
set -euo pipefail

############################################
# CONFIG LOADER
############################################

find_config_file() {
  if [ -n "${VISIONX_CONFIG:-}" ]; then
    echo "$VISIONX_CONFIG"
    return
  fi

  if [ -f "./config.local.env" ]; then
    echo "./config.local.env"
    return
  fi

  if [ -f "${HOME}/.visionx-roll-update.env" ]; then
    echo "${HOME}/.visionx-roll-update.env"
    return
  fi
}

load_config() {
  local config_file
  config_file="$(find_config_file || true)"

  if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
    echo "Missing config file."
    echo "Ask the dev team for the private config.local.env for this production server."
    echo "Place it next to run.sh, then lock down the file:"
    echo "  chmod 600 config.local.env"
    echo ""
    echo "Or use a server-level config:"
    echo "  cp config.local.env ~/.visionx-roll-update.env"
    echo "  chmod 600 ~/.visionx-roll-update.env"
    echo "  VISIONX_CONFIG=~/.visionx-roll-update.env ./run.sh"
    exit 1
  fi

  echo "Loading config from: $config_file"
  set -a
  # shellcheck disable=SC1090
  source "$config_file"
  set +a
}

require_env() {
  local missing=()
  local required_vars=(
    SUPABASE_HOST
    SUPABASE_PORT
    SUPABASE_DATABASE
    SUPABASE_USER
    SUPABASE_PASSWORD
    LOCAL_BASE_PATH
    SUPABASE_CHART_DIR
    RIS_IMAGE_VERSION
    RIS_V1_IMAGE_VERSION
    BLUE_HALO_IMAGE_VERSION
    OHIF_IMAGE_VERSION
    RIS_YAML_FILE
    RIS_YAML_TEMPLATE_FILE
    RIS_V1_YAML_FILE
    BLUE_HALO_YAML_FILE
    OHIF_YAML_FILE
    MIRTH_HOST
    MIRTH_PORT
    MIRTH_USERNAME
    MIRTH_PASSWORD
    KEYCLOAK_LOGIN
    CHECK_MWL_EXIST
    CHECK_PATIENT_EXIST
    PATIENT_HTTP_SENDER
    CHANGESTATUS_MWL
    CHECK_SERVICE_REQUEST_EXIST
    CHECK_STUDY_EXIST_IN_FHIR
    PATCH_END_EXAM_SUPABASE
    GET_STUDY_MODALITY
    IMAGINGSTUDY_HTTP_SENDER
    SERVICE_REQUEST_HTTP_SENDER
    PROCEDURE_HTTP_SENDER
    SEND_AUDIT_LOG
    SEND_AUDIT_TRAIL
    SUPABASE_URL
    SUPABASE_KEY
    DCM_BASE
    DCM_AET
    DCM_QIDO
    DCM_WADO
    KC_TOKEN_URL
    KC_CLIENT_ID
    KC_CLIENT_SECRET
    KC_USERNAME
    KC_PASSWORD
    DRY_RUN
    CANON
    AUTH_TYPE
    TOKEN_SCOPE
    CURL_INSECURE
    FHIR_BASE
    ACC_SYSTEM
    SPS_SYSTEM
    STUDYID_SYSTEM
    VERBOSE
    RECOUNT_PAGE_SIZE
    PATIENT_PAGE_SIZE
    URL
  )

  for var_name in "${required_vars[@]}"; do
    if [ -z "${!var_name:-}" ]; then
      missing+=("$var_name")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required config values:"
    printf '  - %s\n' "${missing[@]}"
    exit 1
  fi
}

############################################
# RUNTIME
############################################

install_node() {
  echo "Node.js not found. Attempting automatic installation via apt-get..."
  echo "There is no Node.js available; installing Node.js 20.x..."

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not available on this system. Please install Node.js manually."
    exit 1
  fi

  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo "
    else
      echo "Root privileges or sudo are required to install Node.js automatically."
      exit 1
    fi
  fi

  ${SUDO}apt-get update
  ${SUDO}apt-get install -y curl
  curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO}bash -
  ${SUDO}apt-get install -y nodejs
  echo "Node.js installation completed successfully."
}

run_update() {
  load_config
  require_env

  if ! command -v node >/dev/null 2>&1; then
    install_node
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "NPM not installed. Please install NPM first."
    exit 1
  fi

  echo "Installing dependencies..."
  npm install || { echo "npm install failed"; exit 1; }

  echo "Running script..."
  npm start
}

run_update

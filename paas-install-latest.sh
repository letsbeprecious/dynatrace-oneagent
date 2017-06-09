#!/bin/sh -e
ME=$(basename "$0")

# Required arguments.
DT_API_TOKEN="${DT_API_TOKEN}"
if [ "x${DT_API_TOKEN}" = "x" ]; then
  echo "${ME}: failed to determine Dynatrace API Token: DT_API_TOKEN is not defined"
  exit 1
fi

DT_TENANT="${DT_TENANT}"
if [ "x${DT_TENANT}" = "x" ]; then
  echo "${ME}: failed to determine Dynatrace Tenant ID: DT_TENANT is not defined"
  exit 1
fi

# Optional arguments.
DT_AGENT_BASE_URL="${DT_AGENT_BASE_URL:-https://${DT_TENANT}.live.dynatrace.com}"
DT_AGENT_BITNESS="${DT_AGENT_BITNESS:-64}"
DT_AGENT_DIR="${DT_AGENT_DIR:-./dynatrace}"
DT_AGENT_FOR="${DT_AGENT_FOR}"
DT_AGENT_PLATFORM="${DT_AGENT_PLATFORM:-unix}"

DT_AGENT_ENV_FILE="${DT_AGENT_DIR}/dynatrace-env.sh"
DT_AGENT_JAVA_ENV_FILE="${DT_AGENT_DIR}/dynatrace-java-env.sh"
DT_AGENT_NGINX_ENV_FILE="${DT_AGENT_DIR}/dynatrace-nginx-env.sh"
DT_AGENT_TMP_FILE="/tmp/dynatrace-paas-agent.zip"
DT_AGENT_URL="${DT_AGENT_URL:-${DT_AGENT_BASE_URL}/api/v1/deployment/installer/agent/${DT_AGENT_PLATFORM}/paas/latest?Api-Token=${DT_API_TOKEN}&bitness=${DT_AGENT_BITNESS}}"

if [ "x${DT_AGENT_FOR}" != "x" ]; then
  # Require precise PaaS Agent capabilities.
  DT_AGENT_URL="${DT_AGENT_URL}&include=${DT_AGENT_FOR}"
fi

append_file() {
  FILE="$1"
  CONTENT="$2"
  echo "${CONTENT}" >> "${FILE}"
}

write_file() {
  FILE="$1"
  CONTENT="$2"
  echo "${CONTENT}" > "${FILE}"
}

get_paas_agent_lib_path() {
  AGENT_LIB_DIR="${DT_AGENT_DIR}/agent/lib"
  if [ "x${DT_AGENT_BITNESS}" != "x32" ]; then
    AGENT_LIB_DIR="${AGENT_LIB_DIR}64"
  fi
  echo "${AGENT_LIB_DIR}"
}

write_java_env_file() {
  write_file "${DT_AGENT_JAVA_ENV_FILE}" ". ${DT_AGENT_ENV_FILE}"

  JAVA_AGENT_PATH="-agentpath:$(get_paas_agent_lib_path)/liboneagentloader.so"
  append_file "${DT_AGENT_JAVA_ENV_FILE}" "export JAVA_OPTS=\"\${JAVA_OPTS} ${JAVA_AGENT_PATH}\""
  append_file "${DT_AGENT_JAVA_ENV_FILE}" "export JAVA_OPTIONS=\"\${JAVA_OPTIONS} ${JAVA_AGENT_PATH}\""
}

write_nginx_env_file() {
  write_file "${DT_AGENT_NGINX_ENV_FILE}" ". ${DT_AGENT_ENV_FILE}"
  append_file "${DT_AGENT_NGINX_ENV_FILE}" "export LD_PRELOAD=\"$(get_paas_agent_lib_path)/liboneagentloader.so\""
}

download_paas_agent_zip_archive() {
  URL="$1"
  FILE="$2"

  if curl -h &>/dev/null; then
    curl "${URL}" > "${FILE}"
  elif wget -h &>/dev/null; then
    wget -O "${FILE}" "${URL}"
  fi
}

extract_literal_from_manifest_json_file() {
  JSON_KEY="$1"
  grep -e "${JSON_KEY}" "${DT_AGENT_DIR}/manifest.json" | awk -F":|," '{print $2}' | cut -d'"' -f2
}

# Create Dynatrace PaaS Agent target directory if required.
if [ ! -d "${DT_AGENT_DIR}" ]; then
  mkdir -p "${DT_AGENT_DIR}"
fi

# Download and install Dynatrace PaaS Agent into target directory.
download_paas_agent_zip_archive "${DT_AGENT_URL}" "${DT_AGENT_TMP_FILE}"
unzip -o "${DT_AGENT_TMP_FILE}" -d "${DT_AGENT_DIR}"
rm -f ${DT_AGENT_TMP_FILE}

# Extract Tenant ID and Tenant Token into a sourceable Dynatrace environment file.
write_file "${DT_AGENT_ENV_FILE}" "export DT_TENANT=${DT_TENANT}"

DT_TENANTTOKEN=$(extract_literal_from_manifest_json_file "tenantToken")
append_file "${DT_AGENT_ENV_FILE}" "export DT_TENANTTOKEN=${DT_TENANTTOKEN}"

DT_CONNECTION_POINT="${DT_AGENT_BASE_URL}/communication"
append_file "${DT_AGENT_ENV_FILE}" "export DT_CONNECTION_POINT=${DT_CONNECTION_POINT}"

# Provide useful integrations to support previously selected PaaS agent capabilities.
if echo "${DT_AGENT_FOR}" | grep -i "java"; then
  write_java_env_file
elif echo "${DT_AGENT_FOR}" | grep -i "nginx"; then
  write_nginx_env_file
elif [ "x${DT_AGENT_FOR}" = "x" ]; then
  write_java_env_file
  write_nginx_env_file
fi

# Fix permissions to allow file operations by "other" users in clusters where processes are run by random users, such as OpenShift.
mkdir "${DT_AGENT_DIR}/log"
chmod 777 "${DT_AGENT_DIR}/log"
chmod 777 "${DT_AGENT_DIR}/agent/conf/runtime"
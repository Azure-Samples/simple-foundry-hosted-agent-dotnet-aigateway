#!/usr/bin/env bash
set -euo pipefail

output=".env"
force=false

if [ "${1:-}" = "--force" ]; then
  force=true
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

if [ -e "$output" ] && [ "$force" != true ]; then
  echo "$output already exists. Use --force to replace it." >&2
  exit 1
fi

azd_value() {
  azd env get-value "$1" 2>/dev/null || true
}

require_azd_value() {
  local name="$1"
  local value
  value="$(azd_value "$name")"
  if [ -z "$value" ]; then
    echo "$name is missing. Run azd provision first." >&2
    exit 1
  fi
  printf '%s' "$value"
}

quote_env() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

endpoint="$(require_azd_value AZURE_AI_GATEWAY_ENDPOINT)"
key="$(require_azd_value AZURE_AI_GATEWAY_API_KEY)"
model="$(require_azd_value AZURE_AI_GATEWAY_MODEL)"
mini_model="$(require_azd_value AZURE_AI_GATEWAY_MINI_MODEL)"
toolbox_endpoint="$(require_azd_value TOOLBOX_ENDPOINT)"
toolbox_name="$(require_azd_value TOOLBOX_NAME)"
repository="$(azd_value GITHUB_REPOSITORY)"
repository="${repository:-microsoft/agent-framework}"

umask 077
temp_file="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -f "$temp_file"' EXIT

{
  printf 'AZURE_AI_GATEWAY_ENDPOINT=%s\n' "$(quote_env "$endpoint")"
  printf 'AZURE_AI_GATEWAY_API_KEY=%s\n' "$(quote_env "$key")"
  printf 'AZURE_AI_GATEWAY_MODEL=%s\n' "$(quote_env "$model")"
  printf 'AZURE_AI_GATEWAY_MINI_MODEL=%s\n' "$(quote_env "$mini_model")"
  printf '\n'
  printf 'TOOLBOX_ENDPOINT=%s\n' "$(quote_env "$toolbox_endpoint")"
  printf 'TOOLBOX_NAME=%s\n' "$(quote_env "$toolbox_name")"
  printf '\n'
  printf 'GITHUB_REPOSITORY=%s\n' "$(quote_env "$repository")"
} > "$temp_file"

if [ "$force" = true ]; then
  mv -f "$temp_file" "$output"
else
  ln "$temp_file" "$output"
  rm -f "$temp_file"
fi
trap - EXIT
chmod 600 "$output"
echo "Created .env for agent development: $(pwd -P)/$output"

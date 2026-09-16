#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lifecycle_script="$repo_root/infra/scripts/manage-ai-gateway-lifecycle.sh"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

stub_bin="$temp_root/bin"
state_dir="$temp_root/state"
mkdir -p "$stub_bin" "$state_dir"

cat > "$stub_bin/azd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "env" ] && [ "${2:-}" = "get-value" ]; then
  case "${3:-}" in
    AZURE_ENV_NAME) printf 'testenv' ;;
    AZURE_SUBSCRIPTION_ID) printf '00000000-0000-0000-0000-000000000001' ;;
    AI_GATEWAY_RESOURCE_GROUP) printf 'rg-testenv-abc12345-gateway' ;;
    AI_GATEWAY_NAME) printf 'aigw-abc12345' ;;
    AI_GATEWAY_LOCATION) printf 'eastus2' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
STUB

cat > "$stub_bin/az" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${STUB_STATE_DIR:?}"
resource_id="/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-testenv-abc12345-gateway/providers/Microsoft.ApiManagement/service/aigw-abc12345"
state="$(cat "$state_dir/live" 2>/dev/null || true)"
owner="$(cat "$state_dir/owner" 2>/dev/null || printf 'testenv')"

if [ "${1:-}" = "account" ] && [ "${2:-}" = "show" ]; then
  printf '00000000-0000-0000-0000-000000000001'
  exit 0
fi

if [ "${1:-}" = "resource" ] && [ "${2:-}" = "list" ]; then
  printf 'aigw-abc12345\trg-testenv-abc12345-gateway\teastus2\n'
  exit 0
fi

if [ "${1:-}" != "rest" ]; then
  exit 1
fi

method=""
uri=""
query=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --uri) uri="$2"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ "$uri" == *"/deletedservices/"* ]]; then
  if [ "$method" = "get" ]; then
    if [ ! -f "$state_dir/deleted" ]; then
      echo "ERROR: (ResourceNotFound) 404" >&2
      exit 1
    fi
    if [ "$query" = "properties.serviceId" ]; then
      printf '%s' "$resource_id"
    fi
    exit 0
  fi
  if [ "$method" = "delete" ]; then
    rm -f "$state_dir/deleted"
    printf 'purge\n' >> "$state_dir/actions"
    exit 0
  fi
fi

if [ "$method" = "get" ]; then
  if [ -z "$state" ]; then
    echo "ERROR: (ResourceNotFound) 404" >&2
    exit 1
  fi
  if [ "$state" = "Forbidden" ]; then
    echo "ERROR: (AuthorizationFailed) 403 over scope /providers/Microsoft.ApiManagement/service/aigw-404" >&2
    exit 1
  fi
  if [ "$output" = "json" ]; then
    printf '{"sku":{"name":"AIGateway"},"tags":{"azd-env-name":"%s"},"properties":{"provisioningState":"%s"}}' "$owner" "$state"
  fi
  exit 0
fi

if [ "$method" = "delete" ]; then
  rm -f "$state_dir/live"
  touch "$state_dir/deleted"
  printf 'delete\n' >> "$state_dir/actions"
  exit 0
fi

exit 1
STUB

chmod +x "$stub_bin/azd" "$stub_bin/az"

run_lifecycle() {
  PATH="$stub_bin:$PATH" \
  STUB_STATE_DIR="$state_dir" \
  APIM_LIFECYCLE_POLL_SECONDS=0 \
  APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS=0 \
  APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS=10 \
    bash "$lifecycle_script" "$1"
}

printf 'Succeeded' > "$state_dir/live"
healthy_output="$(run_lifecycle prepare)"
grep -Fq "Preserving healthy" <<< "$healthy_output"
[ ! -f "$state_dir/actions" ]

printf 'Failed' > "$state_dir/live"
failed_output="$(run_lifecycle prepare)"
grep -Fq "identity settle window completed" <<< "$failed_output"
grep -Fq "delete" "$state_dir/actions"
grep -Fq "purge" "$state_dir/actions"

rm -f "$state_dir/actions"
printf 'Succeeded' > "$state_dir/live"
cleanup_output="$(run_lifecycle cleanup)"
grep -Fq "identity settle window completed" <<< "$cleanup_output"
grep -Fq "delete" "$state_dir/actions"

printf 'Failed' > "$state_dir/live"
printf 'another-env' > "$state_dir/owner"
if run_lifecycle prepare >"$temp_root/foreign.out" 2>&1; then
  echo "Expected foreign ownership to fail." >&2
  exit 1
fi
grep -Fq "refusing resource tagged" "$temp_root/foreign.out"

printf 'Forbidden' > "$state_dir/live"
printf 'testenv' > "$state_dir/owner"
if run_lifecycle prepare >"$temp_root/forbidden.out" 2>&1; then
  echo "Expected authorization failure to fail closed." >&2
  exit 1
fi
grep -Fq "Azure REST GET failed" "$temp_root/forbidden.out"

echo "AI Gateway lifecycle script tests passed."

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lifecycle_script="$repo_root/infra/scripts/manage-ai-gateway-lifecycle.sh"
powershell_script="$repo_root/infra/scripts/manage-ai-gateway-lifecycle.ps1"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" ||
    fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_file_value() {
  local file="$1"
  local expected="$2"
  local actual=""
  [ -f "$file" ] && actual="$(cat "$file")"
  [ "$actual" = "$expected" ] ||
    fail "expected $file to contain '$expected', found '$actual'"
}

stub_bin="$temp_root/bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/azd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "env" ] && [ "${2:-}" = "get-value" ]; then
  case "${3:-}" in
    AZURE_ENV_NAME) printf '%s' "${STUB_ENVIRONMENT_NAME:-tues}" ;;
    AZURE_SUBSCRIPTION_ID) printf '%s' "${STUB_SUBSCRIPTION_ID:-00000000-0000-0000-0000-000000000001}" ;;
    AI_GATEWAY_RESOURCE_GROUP)
      [ "${STUB_NO_GATEWAY_VALUES:-0}" = "0" ] || exit 1
      printf '%s' "${STUB_RESOURCE_GROUP:-rg-tues-abc12345-gateway}"
      ;;
    AI_GATEWAY_NAME)
      [ "${STUB_NO_GATEWAY_VALUES:-0}" = "0" ] || exit 1
      printf '%s' "${STUB_GATEWAY_NAME:-aigw-abc12345}"
      ;;
    AI_GATEWAY_LOCATION) printf '%s' "${STUB_GATEWAY_LOCATION:-eastus2}" ;;
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
subscription_id="${STUB_SUBSCRIPTION_ID:-00000000-0000-0000-0000-000000000001}"
environment_name="${STUB_ENVIRONMENT_NAME:-tues}"
resource_group="${STUB_RESOURCE_GROUP:-rg-tues-abc12345-gateway}"
gateway_name="${STUB_GATEWAY_NAME:-aigw-abc12345}"
location="${STUB_GATEWAY_LOCATION:-eastus2}"

read_state() {
  local file="$state_dir/$1"
  local default="$2"
  if [ -f "$file" ]; then
    cat "$file"
  else
    printf '%s' "$default"
  fi
}

increment() {
  local file="$state_dir/$1"
  local value
  value="$(read_state "$1" 0)"
  printf '%s' $((value + 1)) > "$file"
}

if [ "${1:-}" = "account" ] && [ "${2:-}" = "show" ]; then
  printf '%s\n' "$subscription_id"
  exit 0
fi

if [ "${1:-}" = "resource" ] && [ "${2:-}" = "list" ]; then
  if [ "$(read_state live 0)" = "1" ] && [ "${STUB_DISCOVERY_ENABLED:-0}" = "1" ]; then
    printf '%s\t%s\t%s\n' "$gateway_name" "$resource_group" "$location"
  fi
  exit 0
fi

if [ "${1:-}" = "deployment" ] && [ "${2:-}" = "sub" ] && [ "${3:-}" = "list" ]; then
  if [ -n "${STUB_FAILED_DEPLOYMENT:-}" ]; then
    printf '%s\n' "$STUB_FAILED_DEPLOYMENT"
  fi
  exit 0
fi

if [ "${1:-}" = "deployment" ] && [ "${2:-}" = "operation" ] && [ "${3:-}" = "sub" ]; then
  if [ -n "${STUB_FAILED_DEPLOYMENT:-}" ]; then
    if [ "${STUB_NESTED_FAILURE:-0}" = "1" ]; then
      printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Resources/deployments/ai-gateway-test\n' \
        "$subscription_id" "$resource_group"
    else
      printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.ApiManagement/aigateways/%s\n' \
        "$subscription_id" "$resource_group" "$gateway_name"
    fi
  fi
  exit 0
fi

if [ "${1:-}" = "deployment" ] && [ "${2:-}" = "operation" ] && [ "${3:-}" = "group" ]; then
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.ApiManagement/aigateways/%s\n' \
    "$subscription_id" "$resource_group" "$gateway_name"
  exit 0
fi

if [ "${1:-}" = "group" ] && [ "${2:-}" = "show" ]; then
  printf '%s\n' "${STUB_GROUP_OWNER:-$environment_name}"
  exit 0
fi

if [ "${1:-}" != "rest" ]; then
  echo "unsupported az command: $*" >&2
  exit 2
fi

method=""
uri=""
query=""
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --uri) uri="$2"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    -o) shift 2 ;;
    *) shift ;;
  esac
done

case "$uri" in
  *"/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}?"*)
    if [ "$method" = "get" ]; then
      if [ "$(read_state live 0)" != "1" ]; then
        echo "Status Code: 404 ResourceNotFound" >&2
        exit 1
      fi
      if [ -n "$query" ]; then
        printf '%s|%s|%s|%s|%s\n' \
          "$(read_state provisioning_state Succeeded)" \
          "$(read_state sku Premium)" \
          "$(read_state owner "$environment_name")" \
          "$location" \
          "$(read_state target_state null)"
        if [ "$(read_state target_state null)" = "Deleting" ] &&
          [ "${STUB_TRANSIENT_DELETE:-0}" = "1" ]; then
          printf '0' > "$state_dir/live"
        fi
      fi
      exit 0
    fi
    if [ "$method" = "delete" ]; then
      if [ "${STUB_TRANSIENT_DELETE:-0}" = "1" ]; then
        printf 'Succeeded' > "$state_dir/provisioning_state"
        printf 'Deleting' > "$state_dir/target_state"
      else
        printf '0' > "$state_dir/live"
      fi
      increment delete_count
      exit 0
    fi
    ;;
esac

echo "unsupported az rest call: $method $uri" >&2
exit 2
STUB

chmod +x "$stub_bin/az" "$stub_bin/azd"

new_case() {
  local name="$1"
  case_dir="$temp_root/$name"
  mkdir -p "$case_dir"
  printf '0' > "$case_dir/live"
  printf 'Premium' > "$case_dir/sku"
  printf 'tues' > "$case_dir/owner"
  printf 'Succeeded' > "$case_dir/provisioning_state"
  output_file="$case_dir/output"
  error_file="$case_dir/error"
  marker_file="$case_dir/apim-lifecycle.state"
}

run_lifecycle() {
  env \
    PATH="$stub_bin:$PATH" \
    STUB_STATE_DIR="$case_dir" \
    AZURE_ENV_NAME=tues \
    AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001 \
    AI_GATEWAY_RESOURCE_GROUP=rg-tues-abc12345-gateway \
    AI_GATEWAY_NAME=aigw-abc12345 \
    AI_GATEWAY_LOCATION=eastus2 \
    APIM_LIFECYCLE_STATE_FILE="$marker_file" \
    APIM_LIFECYCLE_POLL_INITIAL_SECONDS=0 \
    APIM_LIFECYCLE_POLL_MAX_SECONDS=0 \
    APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS="${TEST_SETTLE_SECONDS:-0}" \
    APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-2}" \
    "$lifecycle_script" "$1" >"$output_file" 2>"$error_file"
}

run_lifecycle_without_gateway_values() {
  env \
    PATH="$stub_bin:$PATH" \
    STUB_STATE_DIR="$case_dir" \
    STUB_NO_GATEWAY_VALUES=1 \
    STUB_DISCOVERY_ENABLED="${STUB_DISCOVERY_ENABLED:-0}" \
    STUB_FAILED_DEPLOYMENT="${STUB_FAILED_DEPLOYMENT:-}" \
    STUB_NESTED_FAILURE="${STUB_NESTED_FAILURE:-0}" \
    STUB_GROUP_OWNER="${STUB_GROUP_OWNER:-tues}" \
    AZURE_ENV_NAME=tues \
    AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001 \
    AI_GATEWAY_LOCATION=eastus2 \
    APIM_LIFECYCLE_STATE_FILE="$marker_file" \
    APIM_LIFECYCLE_POLL_INITIAL_SECONDS=0 \
    APIM_LIFECYCLE_POLL_MAX_SECONDS=0 \
    APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS=0 \
    APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS=2 \
    "$lifecycle_script" "$1" >"$output_file" 2>"$error_file"
}

new_case fresh-environment
run_lifecycle_without_gateway_values prepare
[ ! -f "$marker_file" ] || fail "fresh environment created a lifecycle marker"
assert_contains "$output_file" "no lifecycle cleanup is needed"

new_case healthy-preserved
printf '1' > "$case_dir/live"
run_lifecycle prepare
assert_file_value "$case_dir/live" 1
[ ! -f "$case_dir/delete_count" ] || fail "healthy gateway was deleted"
assert_contains "$output_file" "Preserving healthy environment-owned AI Gateway"

new_case failed-owned-discovered
printf '1' > "$case_dir/live"
printf 'Failed' > "$case_dir/provisioning_state"
STUB_DISCOVERY_ENABLED=1
export STUB_DISCOVERY_ENABLED
run_lifecycle_without_gateway_values prepare
unset STUB_DISCOVERY_ENABLED
assert_file_value "$case_dir/live" 0
assert_file_value "$case_dir/delete_count" 1
assert_contains "$output_file" "Recovering terminal-Failed"

new_case failed-owned
printf '1' > "$case_dir/live"
printf 'Failed' > "$case_dir/provisioning_state"
run_lifecycle prepare
assert_file_value "$case_dir/live" 0
assert_file_value "$case_dir/delete_count" 1
assert_contains "$marker_file" "state=settled"
assert_contains "$output_file" "Recovering terminal-Failed"

new_case failed-owned-deleting-transition
printf '1' > "$case_dir/live"
printf 'Failed' > "$case_dir/provisioning_state"
STUB_TRANSIENT_DELETE=1
export STUB_TRANSIENT_DELETE
run_lifecycle prepare
unset STUB_TRANSIENT_DELETE
assert_file_value "$case_dir/live" 0
assert_file_value "$case_dir/delete_count" 1
assert_contains "$output_file" "Waiting for AI Gateway aigw-abc12345 to finish deleting"
assert_contains "$marker_file" "state=settled"

new_case already-deleting
printf '1' > "$case_dir/live"
printf 'Succeeded' > "$case_dir/provisioning_state"
printf 'Deleting' > "$case_dir/target_state"
STUB_TRANSIENT_DELETE=1
export STUB_TRANSIENT_DELETE
run_lifecycle prepare
unset STUB_TRANSIENT_DELETE
[ ! -f "$case_dir/delete_count" ] || fail "already-deleting gateway received another DELETE"
assert_file_value "$case_dir/live" 0
assert_contains "$output_file" "Waiting for environment-owned AI Gateway"
assert_contains "$marker_file" "state=settled"

new_case postdown-already-deleting
printf '1' > "$case_dir/live"
printf 'Succeeded' > "$case_dir/provisioning_state"
printf 'Deleting' > "$case_dir/target_state"
STUB_TRANSIENT_DELETE=1
export STUB_TRANSIENT_DELETE
run_lifecycle cleanup
unset STUB_TRANSIENT_DELETE
[ ! -f "$case_dir/delete_count" ] || fail "postdown sent another DELETE to an already-deleting gateway"
assert_file_value "$case_dir/live" 0
assert_contains "$output_file" "Waiting for environment-owned AI Gateway"
assert_contains "$marker_file" "state=settled"

new_case mismatched-ownership
printf '1' > "$case_dir/live"
printf 'Failed' > "$case_dir/provisioning_state"
printf 'another-environment' > "$case_dir/owner"
if run_lifecycle prepare; then
  fail "mismatched ownership was accepted"
fi
[ ! -f "$case_dir/delete_count" ] || fail "mismatched gateway was deleted"
assert_contains "$error_file" "expected azd-env-name=tues"

new_case postdown-delete
printf '1' > "$case_dir/live"
run_lifecycle cleanup
assert_file_value "$case_dir/live" 0
assert_file_value "$case_dir/delete_count" 1
assert_contains "$marker_file" "state=settled"

new_case recent-identity-failure
STUB_FAILED_DEPLOYMENT=tues-failed-deployment
export STUB_FAILED_DEPLOYMENT
run_lifecycle_without_gateway_values prepare
unset STUB_FAILED_DEPLOYMENT
assert_contains "$marker_file" "failure_id=tues-failed-deployment:"
assert_contains "$marker_file" "state=settled"

new_case unowned-recent-failure
STUB_FAILED_DEPLOYMENT=tues-unowned-failed-deployment
STUB_GROUP_OWNER=another-environment
export STUB_FAILED_DEPLOYMENT STUB_GROUP_OWNER
if run_lifecycle_without_gateway_values prepare; then
  fail "mismatched failed-deployment ownership was accepted"
fi
unset STUB_FAILED_DEPLOYMENT STUB_GROUP_OWNER
[ ! -f "$marker_file" ] || fail "unowned failure created a lifecycle marker"
assert_contains "$error_file" "resource group is tagged for azd environment another-environment"

new_case nested-recent-identity-failure
STUB_FAILED_DEPLOYMENT=tues-nested-failed-deployment
STUB_NESTED_FAILURE=1
export STUB_FAILED_DEPLOYMENT STUB_NESTED_FAILURE
run_lifecycle_without_gateway_values prepare
unset STUB_FAILED_DEPLOYMENT STUB_NESTED_FAILURE
assert_contains "$marker_file" "failure_id=tues-nested-failed-deployment:"
assert_contains "$marker_file" "Microsoft.Resources/deployments/ai-gateway-test"
assert_contains "$marker_file" "state=settled"

new_case empty-postdown
run_lifecycle_without_gateway_values cleanup
[ ! -f "$marker_file" ] || fail "empty postdown created a lifecycle marker"
assert_contains "$output_file" "no lifecycle cleanup is needed"

new_case settle-exhausted
cat > "$marker_file" <<'MARKER'
version=1
environment_name=tues
subscription_id=00000000-0000-0000-0000-000000000001
resource_group=rg-tues-abc12345-gateway
gateway_name=aigw-abc12345
location=eastus2
state=ready
action_epoch=0
failure_id=
MARKER
TEST_SETTLE_SECONDS=30 TEST_TIMEOUT_SECONDS=0
export TEST_SETTLE_SECONDS TEST_TIMEOUT_SECONDS
if run_lifecycle prepare; then
  fail "identity settle exhaustion reported success"
fi
unset TEST_SETTLE_SECONDS TEST_TIMEOUT_SECONDS
assert_contains "$error_file" "cleanup did not remain quiet"
assert_contains "$error_file" "rerun 'azd provision'"
assert_contains "$error_file" "run 'azd down'"
assert_contains "$marker_file" "state=pending"

for token in \
  "2025-09-01-preview" \
  "Microsoft.ApiManagement/aigateways" \
  "Premium" \
  "azd-env-name" \
  "FailedIdentityOperation" \
  "ActivationFailed" \
  "If-Match=*" \
  "APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS" \
  "APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS"; do
  assert_contains "$lifecycle_script" "$token"
  assert_contains "$powershell_script" "$token"
done
for legacy_contract in \
  "Microsoft.ApiManagement/service" \
  "deletedservices" \
  "AIGateway"; do
  assert_not_contains "$lifecycle_script" "$legacy_contract"
  assert_not_contains "$powershell_script" "$legacy_contract"
done

assert_contains "$repo_root/azure.yaml" "postdown:"
assert_contains "$repo_root/azure.yaml" "manage-ai-gateway-lifecycle.sh cleanup"
assert_contains "$repo_root/azure.yaml" "manage-ai-gateway-lifecycle.ps1 cleanup"
assert_contains "$repo_root/infra/scripts/configure-ai-gateway.sh" "manage-ai-gateway-lifecycle.sh\" prepare"
assert_contains "$repo_root/infra/scripts/configure-ai-gateway.ps1" "manage-ai-gateway-lifecycle.ps1\") prepare"
for postprovision_script in \
  "$repo_root/infra/scripts/configure-ai-gateway.sh" \
  "$repo_root/infra/scripts/configure-ai-gateway.ps1"; do
  assert_contains "$postprovision_script" "Microsoft.ApiManagement/aigateways"
  assert_contains "$postprovision_script" "Microsoft.ApiManagement/service"
  assert_contains "$postprovision_script" "frontend.defaultHostname"
  assert_contains "$postprovision_script" "/default/models/openai/v1/chat/completions"
  assert_contains "$postprovision_script" "contentSafety"
  assert_contains "$postprovision_script" "hateSeverity"
  assert_contains "$postprovision_script" "selfHarmSeverity"
  assert_contains "$postprovision_script" "sexualSeverity"
  assert_contains "$postprovision_script" "violenceSeverity"
  assert_contains "$postprovision_script" "Medium"
done

assert_contains "$repo_root/infra/scripts/configure-ai-gateway.sh" '"policies": [{'
assert_contains "$repo_root/infra/scripts/configure-ai-gateway.ps1" 'policies = @('

echo "APIM lifecycle tests passed."

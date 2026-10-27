#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

stub_bin="$work_root/bin"
state_dir="$work_root/state"
mkdir -p "$stub_bin" "$state_dir"

cat > "$stub_bin/azd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "env" ] && [ "${2:-}" = "get-value" ]; then
  case "${3:-}" in
    AZURE_ENV_NAME) printf 'testenv' ;;
    AZURE_SUBSCRIPTION_ID) printf '00000000-0000-0000-0000-000000000001' ;;
    AI_GATEWAY_RESOURCE_GROUP)
      [ ! -f "$STUB_STATE_DIR/discovery" ] || exit 1
      printf 'rg-testenv-abc12345-gateway' ;;
    AI_GATEWAY_NAME)
      [ ! -f "$STUB_STATE_DIR/discovery" ] || exit 1
      printf 'aigw-abc12345' ;;
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
resource_id="/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-testenv-abc12345-gateway/providers/Microsoft.ApiManagement/aigateways/aigw-abc12345"
printf '%s\n' "$*" >> "$state_dir/requests"
state="$(cat "$state_dir/live" 2>/dev/null || true)"
owner="$(cat "$state_dir/owner" 2>/dev/null || printf 'testenv')"
sku="$(cat "$state_dir/sku" 2>/dev/null || printf 'Consumption')"

if [ "${1:-}" = "account" ] && [ "${2:-}" = "show" ]; then
  printf '00000000-0000-0000-0000-000000000001'
  exit 0
fi

if [ "${1:-}" = "resource" ] && [ "${2:-}" = "list" ]; then
  [[ "$*" == *"--resource-type Microsoft.ApiManagement/aigateways"* ]]
  [[ "$*" == *"tags."*"azd-env-name"*"=='testenv'"*"sku.name=='Consumption'"* ]]
  if [ -f "$state_dir/discovery-error" ]; then
    echo "ERROR: (AuthorizationFailed) discovery denied" >&2
    exit 1
  fi
  count="$(cat "$state_dir/discovery")"
  if [[ "$*" == *"-o json"* ]]; then
    python3 -c 'import json,sys; print(json.dumps([{"name":"aigw-abc12345","resourceGroup":"rg-testenv-abc12345-gateway"}]*int(sys.argv[1])))' "$count"
  else
    for ((i=0; i<count; i++)); do
      printf 'aigw-abc12345\trg-testenv-abc12345-gateway\n'
    done
  fi
  exit 0
fi

if [ "${1:-}" = "deployment" ]; then
  if [ -f "$state_dir/deployment-error" ]; then
    echo "ERROR: (AuthorizationFailed) deployment inspection denied" >&2
    exit 1
  fi
  if [ "${2:-}" = sub ] && [ "${3:-}" = list ]; then
    [[ "$*" == *"reverse(sort_by([?properties.provisioningState=='Failed'], &properties.timestamp))[:10]"* ]]
  elif [ -f "$state_dir/operation-error" ]; then
    echo "ERROR: (AuthorizationFailed) deployment operation inspection denied" >&2
    exit 1
  fi
  python3 - "$state_dir" "$@" <<'PY'
import json
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
subscription = "00000000-0000-0000-0000-000000000001"
default_group = "rg-testenv-abc12345-gateway"
def read(name, default):
    path = state / name
    return path.read_text() if path.exists() else default
def operation(group, kind, name, status="Failed", code="DeploymentFailed"):
    target_id = f"/subscriptions/{subscription}/resourceGroups/{group}/providers/{kind}/{name}"
    if kind.lower() != "microsoft.resources/deployments":
        target_id = read("operation-id", target_id)
    return {"properties": {"provisioningState": status,
        "targetResource": {"resourceType": kind, "id": target_id},
        "statusMessage": {"error": {"code": code}}}}
if args[1:3] == ["sub", "list"]:
    result = [{"name": "root", "properties": {"provisioningState": read("deployment-state", "Failed")}}] if (state / "failed-discovery").exists() else []
    if result and (state / "duplicate").exists():
        result.append({"name": "previous-root", "properties": {"provisioningState": "Failed"}})
elif args[1:4] == ["operation", "sub", "list"]:
    result = [operation(read("operation-group", default_group), "Microsoft.Resources/deployments", "gateway-root")]
    if (state / "ambiguous").exists():
        result.append(operation("rg-testenv-ffff1111-gateway", "Microsoft.Resources/deployments", "gateway-root"))
elif args[1:4] == ["operation", "group", "list"]:
    group = args[args.index("--resource-group") + 1]
    name = args[args.index("--name") + 1]
    if (state / "nested").exists() and name == "gateway-root":
        result = [operation(group, "Microsoft.Resources/deployments", "gateway-inner")]
    elif (state / "too-deep").exists():
        result = [operation(group, "Microsoft.Resources/deployments", name + "-inner")]
    else:
        token = group.split("-")[-2]
        result = [operation(group, read("operation-type", "Microsoft.ApiManagement/aigateways"),
            read("operation-name", "aigw-" + token), read("operation-state", "Failed"),
            read("operation-code", "FailedIdentityOperation"))]
else:
    sys.exit(1)
print(json.dumps(result))
PY
  exit $?
fi

if [ "${1:-}" = group ] && [ "${2:-}" = show ]; then
  if [ -f "$state_dir/group-error" ]; then
    echo "ERROR: (AuthorizationFailed) resource group inspection denied" >&2
    exit 1
  fi
  printf '{"tags":{"azd-env-name":"%s"}}' "$(cat "$state_dir/group-owner" 2>/dev/null || printf 'testenv')"
  exit 0
fi

[ "${1:-}" = "rest" ] || exit 1
method=""
uri=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --uri) uri="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Fail unexpected resource paths, especially retired APIM soft-delete APIs.
[ "$uri" = "https://management.azure.com${resource_id}?api-version=2025-09-01-preview" ] || exit 1

if [ "$method" = "get" ]; then
  if [ -f "$state_dir/poll-error" ] && [ ! -f "$state_dir/live" ]; then
    echo "ERROR: (AuthorizationFailed) polling denied" >&2
    exit 1
  fi
  if [ -z "$state" ]; then
    echo "ERROR: (ResourceNotFound) 404" >&2
    exit 1
  fi
  case "$state" in
    Forbidden)
      echo "ERROR: (AuthorizationFailed) 403 over scope ${resource_id}-404" >&2
      exit 1 ;;
    Unavailable)
      echo "ERROR: (ServiceUnavailable) retry request 404 later" >&2
      exit 1 ;;
    Malformed) printf '{"sku":'; exit 0 ;;
    Deleting) rm -f "$state_dir/live" ;;
  esac
  printf '{"sku":{"name":"%s"},"tags":{"azd-env-name":"%s"},"properties":{"provisioningState":"%s"}}' "$sku" "$owner" "$state"
  exit 0
fi

if [ "$method" = "delete" ]; then
  if [ -f "$state_dir/delete-error" ]; then
    echo "ERROR: (AuthorizationFailed) delete denied" >&2
    exit 1
  fi
  rm -f "$state_dir/live"
  printf 'delete\n' >> "$state_dir/actions"
  exit 0
fi
exit 1
STUB

chmod +x "$stub_bin/azd" "$stub_bin/az"

run_lifecycle() {
  PATH="$stub_bin:$PATH" \
  STUB_STATE_DIR="$state_dir" \
  AZURE_ENV_NAME=testenv \
  AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001 \
  AI_GATEWAY_NAME="${test_gateway_name:-}" AI_GATEWAY_RESOURCE_GROUP="${test_resource_group:-}" \
  APIM_LIFECYCLE_POLL_SECONDS="${test_poll_seconds:-0}" \
  APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS="${test_settle_seconds:-0}" \
  APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS="${test_timeout_seconds:-10}" \
    "${runner[@]}" "$1"
}

reset_state() {
  rm -f "$state_dir/"*
  test_poll_seconds=0
  test_settle_seconds=0
  test_timeout_seconds=10
  test_gateway_name=""
  test_resource_group=""
}

setup_failed_discovery() {
  reset_state
  printf '0' > "$state_dir/discovery"
  printf 'Failed' > "$state_dir/live"
  touch "$state_dir/failed-discovery"
}

expect_failure() {
  if run_lifecycle "$1" >"$work_root/failure.out" 2>&1; then
    echo "Expected $2 to fail ($platform)." >&2
    exit 1
  fi
  grep -Fiq "$2" "$work_root/failure.out"
  [ ! -f "$state_dir/actions" ]
}

for platform in bash pwsh; do
  if [ "$platform" = "pwsh" ]; then
    if ! command -v pwsh >/dev/null; then
      echo "Skipping PowerShell lifecycle tests: pwsh is not installed."
      continue
    fi
    runner=(pwsh -NoLogo -NoProfile -File "$repo_root/infra/scripts/manage-ai-gateway-lifecycle.ps1")
  else
    runner=(bash "$repo_root/infra/scripts/manage-ai-gateway-lifecycle.sh")
  fi

  reset_state
  printf 'Succeeded' > "$state_dir/live"
  output="$(run_lifecycle prepare)"
  grep -Fq "Preserving healthy" <<< "$output"
  [ ! -f "$state_dir/actions" ]

  for mode in prepare cleanup; do
    reset_state
    if [ "$mode" = prepare ]; then
      printf 'Failed' > "$state_dir/live"
    else
      printf 'Succeeded' > "$state_dir/live"
    fi
    output="$(run_lifecycle "$mode")"
    grep -Fq "identity settle window completed" <<< "$output"
    [ "$(cat "$state_dir/actions")" = delete ]
    ! grep -Fiq deletedservices "$state_dir/requests"
    grep -Fq 'If-Match=*' "$state_dir/requests"
  done

  reset_state
  printf 'Deleting' > "$state_dir/live"
  output="$(run_lifecycle prepare)"
  grep -Fq "identity settle window completed" <<< "$output"
  [ ! -f "$state_dir/actions" ]

  reset_state
  output="$(run_lifecycle cleanup)"
  grep -Fq "identity settle window completed" <<< "$output"
  [ ! -f "$state_dir/actions" ]
  ! grep -Fiq deletedservices "$state_dir/requests"

  reset_state
  printf 'Failed' > "$state_dir/live"
  printf 'another-env' > "$state_dir/owner"
  expect_failure prepare "refusing resource tagged"
  printf '' > "$state_dir/owner"
  expect_failure cleanup "refusing resource tagged"
  printf 'testenv' > "$state_dir/owner"
  for sku in AIGateway Developer; do
    printf '%s' "$sku" > "$state_dir/sku"
    expect_failure cleanup "refusing resource with SKU"
  done

  reset_state
  printf 'Updating' > "$state_dir/live"
  expect_failure prepare "nonterminal state"

  reset_state
  printf 'Succeeded' > "$state_dir/live"
  printf 'Failed' > "$state_dir/deployment-state"
  output="$(run_lifecycle prepare)"
  grep -Fq "Preserving healthy" <<< "$output"
  [ ! -f "$state_dir/actions" ]
  ! grep -Fq 'deployment ' "$state_dir/requests"

  for state in Forbidden Unavailable; do
    printf '%s' "$state" > "$state_dir/live"
    expect_failure prepare "Azure REST GET failed"
  done
  printf 'Malformed' > "$state_dir/live"
  if run_lifecycle cleanup >"$work_root/failure.out" 2>&1; then
    echo "Expected malformed JSON to fail closed ($platform)." >&2
    exit 1
  fi
  [ ! -f "$state_dir/actions" ]

  reset_state
  printf 'Failed' > "$state_dir/live"
  touch "$state_dir/delete-error"
  expect_failure prepare "delete denied"

  reset_state
  touch "$state_dir/poll-error"
  expect_failure cleanup "Azure REST GET failed"

  reset_state
  printf 'Failed' > "$state_dir/live"
  touch "$state_dir/poll-error"
  if run_lifecycle prepare >"$work_root/failure.out" 2>&1; then
    echo "Expected authorization failure during deletion polling to fail ($platform)." >&2
    exit 1
  fi
  grep -Fq "Azure REST GET failed" "$work_root/failure.out"
  [ "$(cat "$state_dir/actions")" = delete ]

  for count in 0 1 2; do
    reset_state
    printf '%s' "$count" > "$state_dir/discovery"
    printf 'Succeeded' > "$state_dir/live"
    if [ "$count" = 2 ]; then
      expect_failure prepare "multiple AI Gateways"
    else
      output="$(run_lifecycle prepare)"
      if [ "$count" = 0 ]; then
        grep -Fq "No environment-owned" <<< "$output"
        ! grep -Fq 'rest ' "$state_dir/requests"
        grep -Fq 'deployment sub list' "$state_dir/requests"
      else
        grep -Fq "Preserving healthy" <<< "$output"
      fi
      [ ! -f "$state_dir/actions" ]
    fi
  done

  reset_state
  printf '1' > "$state_dir/discovery"
  touch "$state_dir/discovery-error"
  expect_failure prepare "discovery denied"

  for code in FailedIdentityOperation ActivationFailed; do
    setup_failed_discovery
    printf '%s' "$code" > "$state_dir/operation-code"
    touch "$state_dir/nested"
    output="$(run_lifecycle prepare)"
    grep -Fq "identity settle window completed" <<< "$output"
    [ "$(cat "$state_dir/actions")" = delete ]
    grep -Fq -- '--name gateway-inner' "$state_dir/requests"
    grep -Fq 'group show' "$state_dir/requests"
    ! grep -Fiq deletedservices "$state_dir/requests"
  done

  setup_failed_discovery
  printf 'mIcRoSoFt.ApImAnAgEmEnT/aIgAtEwAyS' > "$state_dir/operation-type"
  output="$(run_lifecycle prepare)"
  grep -Fq "identity settle window completed" <<< "$output"
  [ "$(cat "$state_dir/actions")" = delete ]

  setup_failed_discovery
  touch "$state_dir/duplicate"
  output="$(run_lifecycle prepare)"
  grep -Fq "identity settle window completed" <<< "$output"
  [ "$(cat "$state_dir/actions")" = delete ]
  [ "$(grep -c 'deployment operation group list' "$state_dir/requests")" -eq 1 ]

  for hint in name group; do
    setup_failed_discovery
    if [ "$hint" = name ]; then
      test_gateway_name=aigw-foreign1
    else
      test_resource_group=rg-testenv-foreign1-gateway
    fi
    output="$(run_lifecycle prepare)"
    grep -Fq "No environment-owned" <<< "$output"
    [ ! -f "$state_dir/actions" ]
    ! grep -Fq 'rest ' "$state_dir/requests"
  done

  for type in Microsoft.ApiManagement/service Microsoft.ApiManagement/aigateways/workspaces; do
    setup_failed_discovery
    printf '%s' "$type" > "$state_dir/operation-type"
    output="$(run_lifecycle prepare)"
    grep -Fq "No environment-owned" <<< "$output"
    [ ! -f "$state_dir/actions" ]
    ! grep -Fq 'rest ' "$state_dir/requests"
  done

  for fixture in operation-code operation-state operation-name operation-group operation-id deployment-state; do
    setup_failed_discovery
    case "$fixture" in
      operation-code) value=UnrelatedFailure ;;
      operation-state) value=Succeeded ;;
      operation-name) value=aigw-other123 ;;
      operation-group) value=rg-anotherenv-abc12345-gateway ;;
      operation-id) value=/subscriptions/other/resourceGroups/rg-testenv-abc12345-gateway/providers/Microsoft.ApiManagement/aigateways/aigw-abc12345 ;;
      deployment-state) value=Running ;;
    esac
    printf '%s' "$value" > "$state_dir/$fixture"
    output="$(run_lifecycle prepare)"
    grep -Fq "No environment-owned" <<< "$output"
    [ ! -f "$state_dir/actions" ]
    ! grep -Fq 'rest ' "$state_dir/requests"
  done

  setup_failed_discovery
  touch "$state_dir/ambiguous"
  expect_failure prepare "multiple AI Gateways"

  for owner in another-env ''; do
    setup_failed_discovery
    printf '%s' "$owner" > "$state_dir/group-owner"
    expect_failure prepare "refusing failed deployment resource group"
    ! grep -Fq 'rest ' "$state_dir/requests"
  done

  setup_failed_discovery
  printf 'another-env' > "$state_dir/owner"
  expect_failure prepare "refusing resource tagged"
  printf 'testenv' > "$state_dir/owner"
  printf 'Developer' > "$state_dir/sku"
  expect_failure prepare "refusing resource with SKU"

  for fixture in deployment-error operation-error group-error; do
    setup_failed_discovery
    touch "$state_dir/$fixture"
    expect_failure prepare "inspection denied"
  done

  setup_failed_discovery
  touch "$state_dir/too-deep"
  expect_failure prepare "safe traversal limit"

  setup_failed_discovery
  printf 'Succeeded' > "$state_dir/live"
  output="$(run_lifecycle prepare)"
  grep -Fq "Preserving healthy" <<< "$output"
  [ ! -f "$state_dir/actions" ]

  setup_failed_discovery
  printf 'Updating' > "$state_dir/live"
  expect_failure prepare "nonterminal state"

  reset_state
  test_settle_seconds=1
  test_poll_seconds=1
  output="$(run_lifecycle cleanup)"
  grep -Fq "Waiting for managed-identity cleanup" <<< "$output"
  grep -Fq "1s identity settle window completed" <<< "$output"
  [ "$(grep -c 'rest --method get' "$state_dir/requests")" -ge 3 ]

  reset_state
  test_timeout_seconds=0
  expect_failure cleanup "cleanup did not settle"

  echo "AI Gateway lifecycle tests passed ($platform)."
done

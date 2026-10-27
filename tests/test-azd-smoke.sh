#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tests/test-azd-smoke.sh [--deploy | --up]

Use the selected azd environment to invoke the deployed .NET hosted agent.
By default, only invoke the agent; --deploy runs `azd deploy` first and
--up runs `azd up --no-prompt` first.
EOF
}

preparation=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --deploy | --up)
      if [ -n "$preparation" ]; then
        echo "Choose only one of --deploy or --up." >&2
        exit 2
      fi
      preparation="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v azd >/dev/null 2>&1 || ! command -v az >/dev/null 2>&1; then
  echo "Install and sign in with both azd and az before running this smoke test." >&2
  exit 1
fi

if ! az account show --output none >/dev/null 2>&1; then
  echo "Sign in with Azure CLI before running this smoke test." >&2
  exit 1
fi

if ! azd env get-values >/dev/null 2>&1; then
  echo "Select an azd environment before running this smoke test." >&2
  exit 1
fi

case "$preparation" in
  --deploy) azd deploy ;;
  --up) azd up --no-prompt ;;
esac

repository="$(azd env get-value GITHUB_REPOSITORY 2>/dev/null || true)"
repository="${repository:-microsoft/agent-framework}"
prompt="Create a concise daily repo digest for $repository."
if ! output="$(azd ai agent invoke "$prompt" 2>&1)"; then
  printf '%s\n' "$output" >&2
  echo "Hosted-agent invocation failed." >&2
  exit 1
fi

printf '%s\n' "$output"
if printf '%s' "$output" | grep -Eiq \
  'agent initialization|ToolExecutionException|Failed to enter context manager|hosted responses failure|MCP subscription recovery requires|Unhandled exception|RequestFailedException'; then
  echo "Hosted-agent invocation reported an initialization or tool-execution failure." >&2
  exit 1
fi

for section in 'summary' 'pull requests|PRs' 'issues' 'workflow failures' 'next actions'; do
  if ! printf '%s' "$output" | grep -Eiq "$section"; then
    echo "Invocation output is missing the '$section' section; expected a repo digest." >&2
    exit 1
  fi
done

echo "Hosted-agent azd smoke test passed."

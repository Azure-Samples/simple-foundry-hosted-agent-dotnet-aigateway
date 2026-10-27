# Deployment hooks

The Bash and PowerShell implementations support the same azd provisioning flow.

## Lifecycle

`manage-ai-gateway-lifecycle.sh` and `.ps1` support `prepare` and `cleanup`:

- Use exact gateway outputs when available; otherwise discover a unique environment-tagged `Microsoft.ApiManagement/aigateways` resource with `Consumption` SKU.
- Validate environment ownership and SKU before deleting.
- Preserve healthy gateways during preprovision; remove terminal failed gateways or wait for an in-progress deletion.
- If outputs are incomplete and live discovery finds nothing, inspect the 10 most recent failed subscription deployments and failed nested resource-group deployment operations, with depth 3 and 30 nested-deployment limits.
- Recover only an exact standalone gateway target with `FailedIdentityOperation` or `ActivationFailed`, matching the subscription, supplied naming hints or environment naming/token, and resource-group ownership tag. Reject ambiguous candidates and unsafe traversal.
- Recheck live ownership and SKU before any deletion; nonterminal live states still fail closed.
- Wait for deletion and managed identity cleanup within bounded time limits.
- Treat only confirmed 404 responses as absence and fail closed on other Azure errors.

Cleanup does not purge legacy APIM `deletedservices` records. A recovered gateway that is already absent still receives the identity settle wait. Failed-operation discovery does not authorize deleting a healthy or nonterminal live gateway.

## Configuration

`configure-ai-gateway.sh` and `.ps1` prepare legacy script-owned role assignments for Bicep adoption and, after provisioning:

1. Verify the standalone gateway and its managed-identity Foundry provider.
2. Obtain the active GitHub CLI credential, optionally selected with `GITHUB_MCP_GH_USER`.
3. Run advisory repository access checks and configure the GitHub ToolServer.
4. Read the runtime key and probe the model route using `Api-Key`.
5. Create or update the Foundry remote-tool connection and ensure the Toolbox exists.
6. Save the existing runtime configuration to the azd environment without printing secrets.

The ToolServer uses `failureMode: failClosed`, `X-MCP-Readonly: true`, and the allowlist `list_pull_requests,list_issues,actions_list`. The agent independently enforces the configured repository.

Use a dedicated read-only GitHub credential. See [credential guidance](../../docs/implementation-notes.md#tighten-the-github-credential-to-least-privilege) and [implementation notes](../../docs/implementation-notes.md#provisioning-hooks).

## Run explicitly

Prefer `azd up`, which sequences the hooks. For an already selected and configured azd environment, run from the repository root:

```bash
bash infra/scripts/configure-ai-gateway.sh --prepare-bicep # Before provisioning
bash infra/scripts/configure-ai-gateway.sh                # After provisioning
```

The preparation command includes lifecycle `prepare`. Lifecycle `cleanup` is destructive and belongs to the teardown flow. These scripts require authenticated Azure CLI and azd, current deployment outputs, and, for postprovision configuration, authenticated GitHub CLI. A standalone module deployment returns ARM outputs but does not run these scripts or populate their azd inputs.

Use `bash tests/test-azd-smoke.sh` to invoke an existing hosted agent. Opt-in `--deploy` and `--up` first deploy the agent or provision the full sample respectively. These require live Azure authentication and a selected azd environment; a successful digest is not proof of actual model failover.

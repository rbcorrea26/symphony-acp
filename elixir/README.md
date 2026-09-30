# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- `executor.kind` selects the executor implementation used by the agent runner. Default: `codex`
  (`SymphonyElixir.Executor.Codex`), a pure delegation to the Codex app-server client, which keeps
  using the `codex.*` block unchanged. `acp` selects `SymphonyElixir.Executor.Acp`, an Agent Client
  Protocol executor that launches `acp.command` as a subprocess and talks JSON-RPC over stdio.
  An unsupported value fails dispatch preflight with `{:unsupported_executor_kind, kind}`.
  Workflows without an `executor` block need no change and keep running Codex.
- ACP also needs a command, and only when it is selected: `executor.kind: acp` without a non-blank
  `acp.command` fails dispatch preflight with `{:error, :missing_acp_command}` (`codex.*` is never
  read in that case, and `acp.*` is ignored while `executor.kind` stays `codex`).
- `acp.auto_approve_requests` (default `false`) controls `session/request_permission`. The default is
  fail closed: the permission request is answered with the lowest-scope rejection available
  (`reject_once`, else `reject_always`, else `cancelled`) and the turn ends blocked, reporting
  `:approval_required`. Setting it to `true` (explicit configuration) answers `allow_once`, else
  `allow_always`, and lets the turn continue; if the agent offers no approval option, the turn is
  still cancelled and blocked. It is a per-call decision, not a global policy, and it is **not**
  equivalent to `codex.approval_policy: never`.
- What the ACP path does **not** do (declared limits, see `../docs/fork/adr/0004-acp-client-implementation.md`):
  - it announces **no client capability**: no `fs`, no `terminal`, no `elicitation` and no
    `additionalDirectories`, so the agent can neither read/write files through Symphony nor run
    commands through it, and a request for one of those methods gets an explicit JSON-RPC error
    and fails the turn;
  - there is **no ACP sandbox**: `codex.thread_sandbox`, `codex.turn_sandbox_policy` and
    `codex.approval_policy` are not sent to the agent (the protocol has no such fields).
    Filesystem containment for a headless, auto-approved agent is **not** a protocol
    feature: the platform ships it outside the protocol, by pointing `acp.command` at a
    contained launcher (`$HOME/automation/bin/cline-sandboxed --acp`, filesystem
    allowlist built with bubblewrap — see
    [agentic-dev-environment ADR-0008](https://github.com/rbcorrea26/agentic-dev-environment/blob/main/docs/architecture/adr/0008-contencao-do-agente-acp.md)).
    This executor stays generic: it launches whatever `acp.command` says. The shared
    network of that launcher is **not** network isolation;
  - `auth_required` (JSON-RPC error `-32000`) blocks the run with `{:acp_auth_required, methods}`
    and expects human authentication of the agent; Symphony stores no credential;
  - tool calls are reported as notifications but never executed or blocked by Symphony, and there
    are no tracker tools (`linear_graphql`, `github_api`, ...) in this path;
  - `stop_session/1` closes the process and the transport. That is **not** `session/cancel` or
    `session/close`: no cancellation notification is sent and the agent gets no chance to stop
    gracefully;
  - `usage_update` is passed through as a notification; Symphony does not turn it into token
    counters (absence of usage data is not reported as zero usage).
- ACP response timeouts reuse the Codex keys while there is a single executor in real use:
  `codex.read_timeout_ms` bounds `initialize`/`session/new` responses and
  `codex.turn_timeout_ms` bounds silence between messages while `session/prompt` is pending
  (each received frame restarts it; a prompt is never capped by a response timeout).
- Streams stay separated, as the protocol requires: **`stdout` is the only channel Symphony parses**
  (ACP/JSON-RPC frames) and `stderr` is the agent's diagnostic channel. Symphony never merges them
  (`:stderr_to_stdout` is not used, locally or over `ssh`), so an agent log line — even one shaped
  like a valid JSON-RPC response — can never answer a request, fabricate a `sessionId`/`stopReason`
  or become a notification/malformed frame. Agent `stderr` is inherited by the node, so it shows up
  in Symphony's own diagnostic sink (console/journald) instead of being truncated or classified by
  the client; the client only logs/truncates non-JSON lines that arrive on `stdout`
  (`../docs/fork/adr/0004-acp-client-implementation.md` §4.10).
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

Selecting the ACP executor instead (any ACP-speaking agent command; no Cline or model
is implied by Symphony):

```yaml
executor:
  kind: acp
acp:
  command: "/path/to/acp-agent --stdio"
  auto_approve_requests: false
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `delivery` (fork extension) turns the end of the agent run into a published candidate:
  the consumer's gates run in the workspace, then a per-issue branch and a **draft** pull
  request are created, the CI check runs of that branch are observed, and the handoff
  (`ready-for-human`) is written back to the issue. Without the block the upstream behavior
  is unchanged (`delivery.enabled` defaults to `false`).

```yaml
delivery:
  enabled: true
  gates: "scripts/agent/preflight.sh --gates"   # the project defines "passed"
  base_branch: main
  branch_prefix: "pipeline/"
  handoff_label: "pipeline:ready-for-human"
  remove_entry_labels: true        # entry label off => the issue leaves the active state
  commit_name: "agentic pipeline"
  commit_email: "pipeline@users.noreply.github.com"
  ci_timeout_ms: 1800000
  ci_poll_interval_ms: 15000
  request_review: true             # one-shot request, only after a stable candidate
  evidence:                        # named evidences the issue's acceptance contract may require
    agent-tests: "tests/agent/run-tests.sh"
    wordpress-tests: "tests/wordpress/run-tests.sh"
```

- A non-zero exit from `delivery.gates` fails the run: nothing is published.
- **Three independent layers decide before a candidate is promoted**: the issue's
  **acceptance contract** ("was the issue satisfied?"), the repository gates ("is the
  repository still valid?") and the CI ("did the published candidate pass?"). Green gates do
  not replace acceptance. The contract is declarative data in the **issue body**:

```yaml
pipeline_contract:
  version: 1
  scope_mode: strict               # strict | advisory
  expected_paths:                  # glob patterns; each one must be delivered
    - docs/changes/2026-09-30-pipeline-e2e-smoke.md
    - tests/agent/run-tests.sh
  allowed_extra_paths: []          # glob patterns authorized beyond the expected set
  required_evidence:               # names the candidate must prove
    - agent-tests
    - repository-gates
  remote_access: false             # absent = false (explicit prohibition)
  deploy: false
```

- `strict`: an expected path that was not delivered, a changed path nobody authorized, a
  detected prohibition or a required evidence that did not pass **fails the acceptance**, so
  nothing is published. `advisory` reports the divergence (log and handoff comment) and the
  delivery continues; the architectural review decides.
- The parser only extracts the fenced `pipeline_contract:` block and validates version,
  types and field names: content of the issue is **never executed** (`eval`/`source`/shell
  are prohibited by design). An unenforceable contract (unknown version or field, invalid
  pattern, broken YAML, two contracts) fails the run instead of being ignored; an issue
  without a contract is simply not subject to this layer.
- Evidence is named: `required_evidence` demands names, `delivery.evidence` supplies the
  command (mapped evidence commands use `delivery.gates_timeout_ms`). The reserved name
  `repository-gates` is satisfied by the gates stage itself. A demanded name without a
  provider is a finding, never a silent pass.
- Prohibitions are detected by scanning the **added lines** of the candidate (tracked diff
  plus untracked files, bounded and reported as truncated when the cap is reached) with the
  fixed rules documented in `../docs/fork/adr/0006-acceptance-contract.md`. A match is a
  finding for the human, not a proof of intent; `remote_access: true`/`deploy: true` in the
  contract turns the corresponding scan off.
- With no candidate change set (a `--resume-only` cycle over an already published candidate,
  or nothing to publish) the layer reports `not_applicable` instead of failing: that
  candidate was accepted by the cycle that created it.
- The verdict is **structured data**, not a boolean: `status` (`:pass`, `:fail`,
  `:advisory`, `:not_configured` for an issue without a contract, `:not_applicable` when there
  is no candidate change set), `contract_version`, `mode`, `findings`, `evidence`,
  `change_set` and `limits`. Each finding carries a deterministic `code`
  (`invalid_contract`, `expected_path_missing`, `unexpected_path_changed`,
  `required_evidence_missing`, `required_evidence_failed`, `forbidden_deploy_detected`,
  `forbidden_remote_access_detected`), a `category`, a human `message` and an optional `path`.
  There is no score and no ranking: the contract `mode` decides whether a finding blocks.
- `limits` says what the layer did **not** verify — the forbidden-operation check is a pattern
  scan of the added lines, so "no finding" is not a proof that the agent did not reach a remote
  host or deploy, and the contents/quality of what was delivered belong to the gates, the
  review and the architect. A pass is never reported as a proof of absence.
- The verdict is in the result of `Delivery.run/3`, in the log
  (`Delivery acceptance passed|diverged|failed`) and in the handoff comment as a
  `<!-- acceptance:result:<sha> -->` marker plus JSON, which is the stable interface for the
  review state machine and the architect runner (next increments). A rejected candidate is not
  published and not commented: the evidence of the block lives in the run log.
  `../docs/fork/acceptance-contract.md` documents the schema, the semantics per diff case, the
  codes and every declared limit.
- The candidate is the head SHA of the delivery branch that passed the local gates **and**
  whose check runs all concluded successfully **and** that was still the branch head when
  the observation finished. A push that lands during the observation invalidates it and
  the observation restarts on the new SHA; no CI at all, a failing check or a timeout
  blocks the promotion.
- State comes from GitHub (open pull request, ref, check runs, labels, comments), so a
  retry reconciles the existing candidate: no second branch, no second pull request, no
  second handoff comment, no repeated push. A reconciled candidate does not request a new
  review either (the review is one-shot).
- The entry labels (`tracker.required_labels`) are removed at the handoff, which is what
  stops the next poll from dispatching an issue that was already delivered; the handoff
  comment carries the candidate SHA, the acceptance verdict, the gates command, the CI result
  and the review state.
- The credential is never written to `argv`, to the workspace or to a log: the push uses a
  throwaway `GIT_ASKPASS` helper (it holds no secret and is removed even on failure) and
  the REST calls reuse the tracker authentication.
- `delivery.enabled` fails dispatch preflight when the tracker is not GitHub, when the
  worker is remote (`worker.ssh_hosts`) or when `delivery.gates` is missing.
  `delivery-and-promotion.md` in `../docs/fork/` documents the limits and the measured
  end-to-end evidence.

- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

The suite is offline. The ACP tests (`test/symphony_elixir/acp_test.exs`) spawn a
deterministic fake ACP agent — a separate process that speaks the Agent Client
Protocol over stdio — so they need `bash` and `jq` on `PATH` (both are already
required by this repository: `jq` is used by the PR-description workflow). The fake
never touches the network, a model or a credential.

The fake writes its protocol frames to `stdout` and its diagnostics to `stderr`
(including, when the plan asks for it, a full JSON-RPC response for the request that
is pending at that moment). Its `stderr` is inherited by the test node, so those lines
appear in the test output while never reaching the parser — which is exactly what the
separation tests assert.

The ACP path also has an opt-in integration test against a **real** ACP agent — the
Cline CLI of the platform's isolated runtime. It is never part of `make all` and never
runs in CI, because it needs an authenticated agent and a model:

```bash
cd elixir
make cline-acp-e2e     # real Cline turn, provider resolved by the isolated runtime
make cline-deepseek-e2e # the same turn, requiring the DeepSeek provider (phase 5)
```

`make cline-deepseek-e2e` adds the model layer of phase 5: besides the real turn, it
reads the session record the agent writes in its own isolated state and requires
`provider == "deepseek"` and the expected model, so a run that fell back to another
provider (or that had no provider credential) fails instead of passing as verified. It
has been executed successfully against the platform's isolated runtime (real turn,
`provider == "deepseek"`, `model == "deepseek-v4-flash"`, 1 test / 0 failures); the paid
run is never part of `make all` or CI, and one successful run is enough. Its
provider/model mechanism and the extra environment variables
(`SYMPHONY_RUN_CLINE_DEEPSEEK_E2E`, `SYMPHONY_CLINE_DEEPSEEK_MODEL`,
`SYMPHONY_CLINE_STATE_DIR`) are documented in
[docs/fork/cline-acp-integration.md](../docs/fork/cline-acp-integration.md) §8.

It launches the agent through `acp.command` using the production path
(`AgentRunner -> Executor.Acp -> ACP.Client -> stdio/JSON-RPC`), runs a real turn in a
disposable git project created under the system temp directory, and passes only when the
agent changes that project and the deterministic check passes (`bash answer.sh` printing
exactly `42`, with `answer.sh` reported as the changed file); it also asserts the agent
process is gone after teardown. Optional environment variables:

- `SYMPHONY_CLINE_ACP_COMMAND` overrides `acp.command`. The default is the platform
  wrapper `$HOME/automation/bin/cline --acp` — the pipeline's isolated runtime
  (binary/Node), never the user's personal installation. The platform's canonical
  command is now the **contained** launcher
  (`$HOME/automation/bin/cline-sandboxed --acp`); both are drop-in for this test;
- `SYMPHONY_RUN_CLINE_ACP_E2E=1` is the gate the target sets (without it the file is
  skipped).

Symphony stores no agent credential: the agent must be authenticated out of band, and
without authentication the run blocks with `{:acp_auth_required, methods}` and the test
fails with that human step in the message — it never fabricates a pass. Measured with
Cline `3.0.65`, the credential/state is resolved by the agent from its own config
directory (`~/.cline`), so the pipeline's `--data-dir` does not isolate the
credential/state in this flow; the test therefore reuses whatever authentication the
runtime already has, as an execution dependency. The file configures
`acp.auto_approve_requests: true` **only** in its own disposable workflow (the global
default stays fail-closed), and in the measured real turns the agent did not send
`session/request_permission` at all. Measured state and the phase status:
`../docs/fork/cline-acp-integration.md`.

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

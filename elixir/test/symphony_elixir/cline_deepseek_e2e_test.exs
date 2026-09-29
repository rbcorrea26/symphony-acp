defmodule SymphonyElixir.ClineDeepseekE2ETest do
  @moduledoc """
  Opt-in integration test: the real Cline CLI `3.0.65` resolving the **DeepSeek**
  provider as the ACP agent of the path the fork implements.

  `cline_acp_e2e_test.exs` proves the ACP path with the real Cline, whatever
  provider its isolated runtime resolves. This file proves the **model layer**
  (phase 5): the pipeline's isolated Cline must select the DeepSeek provider
  through `CLINE_PROVIDER`/`CLINE_MODEL`/`CLINE_API_KEY`, which the platform's
  wrapper injects. That mechanism is measured, not assumed — see
  `docs/fork/cline-acp-integration.md` §9 and the platform's ADR-0003
  (`agentic-dev-environment`).

  It is explicitly opt-in, so it never runs in `make all` and CI never depends on
  a paid model, a network or a credential:

      make cline-deepseek-e2e

  Environment:

    * `SYMPHONY_RUN_CLINE_DEEPSEEK_E2E=1` — the gate; without it the test is
      skipped (never in `make all`, never in CI);
    * `SYMPHONY_CLINE_ACP_COMMAND` — the `acp.command`; default is the platform
      wrapper `$HOME/automation/bin/cline --acp`, which declares provider/model
      and delivers the provider credential to the agent process;
    * `SYMPHONY_CLINE_DEEPSEEK_MODEL` — the model the turn must have used
      (default `deepseek-v4-flash`, the provider default in Cline `3.0.65`);
    * `SYMPHONY_CLINE_STATE_DIR` — the pipeline's **isolated** Cline state
      (default `$HOME/automation/state/cline`), where the agent records
      `provider`/`model` per session. It must never be the personal `~/.cline`.

  What makes this test fail-closed: besides the deterministic effect in the
  disposable project, it reads the session record the agent writes in its own
  isolated state and requires `provider == "deepseek"` plus the expected model. A
  run that fell back to another provider, or that had no provider credential,
  fails here with an explicit message instead of being reported as "phase 5
  verified".

  Cost: the model call is paid. One successful turn is enough and the test stays
  out of the normal suite. Usage/cost figures of the run are printed as
  transient operational evidence only — they are never asserted and never
  versioned.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Executor

  @run_gate "SYMPHONY_RUN_CLINE_DEEPSEEK_E2E"
  @command_env "SYMPHONY_CLINE_ACP_COMMAND"
  @model_env "SYMPHONY_CLINE_DEEPSEEK_MODEL"
  @state_env "SYMPHONY_CLINE_STATE_DIR"

  @provider_id "deepseek"
  @default_model "deepseek-v4-flash"

  @issue_id "issue-cline-deepseek-e2e"
  @issue_identifier "MT-DEEPSEEK"

  @read_timeout_ms 60_000
  @turn_timeout_ms 600_000
  @runner_timeout_ms 600_000
  @session_record_timeout_ms 60_000

  @skip_reason if System.get_env(@run_gate) != "1",
                 do: "set #{@run_gate}=1 (or `make cline-deepseek-e2e`) to run the real DeepSeek ACP test"

  @answer_script """
  #!/usr/bin/env bash
  # Prints the number this project is expected to produce.
  echo "1"
  """

  @task_prompt "The file answer.sh in this workspace prints the wrong number. " <>
                 "Change that file only, so that running `bash answer.sh` prints exactly 42 " <>
                 "and nothing else. Do not create, delete or modify any other file, do not use " <>
                 "the network and do not commit. Work item {{ issue.identifier }}."

  @moduletag :cline_deepseek_e2e
  @moduletag timeout: 900_000

  @tag skip: @skip_reason
  test "a real Cline turn through the ACP path uses the DeepSeek provider" do
    command = cline_command!()
    state_dir = cline_state_dir!()
    model = expected_model()

    context = disposable_project!(command)
    issue = work_item()

    run_through_runner!(context, issue)

    # Deterministic check of the disposable project the prompt asked for.
    {output, status} = System.cmd("bash", ["answer.sh"], cd: context.workspace, stderr_to_stdout: true)
    assert status == 0
    assert String.trim(output) == "42"
    refute File.read!(Path.join(context.workspace, "answer.sh")) == @answer_script

    changed = git_changed_paths(context.workspace)

    assert changed in [[], ["answer.sh"]],
           "only answer.sh may change in the disposable project, got: #{inspect(changed)}"

    assert String.starts_with?(context.workspace, context.test_root)

    # Evidence collected through the runner's own update channel, then teardown.
    assert_receive {:codex_worker_update, @issue_id, %{event: :session_started, codex_app_server_pid: os_pid}}
    assert_receive {:codex_worker_update, @issue_id, %{event: :turn_completed}}
    assert_agent_process_gone!(os_pid)

    # The model layer: the agent's own record of the session it just ran.
    record_path = session_record_path!(state_dir, context.workspace)
    record = record_path |> File.read!() |> Jason.decode!()

    assert record["provider"] == @provider_id, provider_not_used_message(record)
    assert record["model"] == model, model_not_used_message(record, model)
    assert Path.expand(record["cwd"]) == Path.expand(context.workspace)

    # No credential material may appear in the agent's own record.
    raw = File.read!(record_path)

    refute raw =~ "apiKey"
    refute raw =~ "api_key"
    refute raw =~ "secret"
    refute raw =~ "refresh_token"

    report_usage(record)
  end

  defp cline_command! do
    command = System.get_env(@command_env) || Path.join([System.user_home!(), "automation", "bin", "cline"]) <> " --acp"
    executable = command |> String.split() |> List.first()

    if String.contains?(executable, "/") and not File.exists?(executable) do
      flunk("""
      the real ACP agent command is not available: #{executable}

      Install the platform runtime (`install.sh`), or point this test at the agent
      explicitly, for example:

          export #{@command_env}="$HOME/automation/bin/cline --acp"
      """)
    end

    command
  end

  defp expected_model do
    System.get_env(@model_env) || @default_model
  end

  # The pipeline's isolated Cline state. The personal state of the operator's
  # Cline (`~/.cline`) is never read by this test.
  defp cline_state_dir! do
    state_dir =
      System.get_env(@state_env) || Path.join([System.user_home!(), "automation", "state", "cline"])

    personal = Path.join(System.user_home!(), ".cline")

    if Path.expand(state_dir) == Path.expand(personal) do
      flunk("""
      #{@state_env} points at the personal Cline state (#{personal}).

      The pipeline uses an isolated state (`$HOME/automation/state/cline`, injected by the
      wrapper as `--config`) and this test is not allowed to read the personal state.
      """)
    end

    if not File.dir?(state_dir) do
      flunk("""
      the pipeline's isolated Cline state does not exist: #{state_dir}

      The real ACP agent records `provider`/`model` per session there, and that record is how
      this test proves which provider was used. Install/authenticate the isolated runtime
      first:

          ./install.sh                     # platform repository
          #{System.get_env(@command_env) || "$HOME/automation/bin/cline"} auth
      """)
    end

    state_dir
  end

  # The agent writes `<state>/data/sessions/<id>/<id>.json` when the session ends
  # (the record of the run, without any credential). The state is the pipeline's
  # own, so the only filter needed is the disposable workspace of this test.
  defp session_record_path!(state_dir, workspace, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @session_record_timeout_ms

    case find_session_record(state_dir, workspace) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          the real Cline did not record a session for the disposable workspace under #{state_dir}.

          This test reads the agent's own record (`provider`/`model`) to prove which provider the
          real turn used; without it there is no evidence that DeepSeek was used, so it fails
          instead of assuming success. Check that `#{@state_env}` points at the pipeline's
          isolated state (default `$HOME/automation/state/cline`) and that the turn really
          reached the agent.
          """)
        else
          Process.sleep(500)
          session_record_path!(state_dir, workspace, deadline)
        end

      path ->
        path
    end
  end

  defp find_session_record(state_dir, workspace) do
    Path.wildcard(Path.join([state_dir, "data", "sessions", "*", "*.json"]))
    |> Enum.reject(&String.ends_with?(&1, ".messages.json"))
    |> Enum.filter(&record_for_workspace?(&1, workspace))
    |> List.last()
  end

  defp record_for_workspace?(path, workspace) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"cwd" => cwd}} when is_binary(cwd) <- Jason.decode(body) do
      Path.expand(cwd) == Path.expand(workspace)
    else
      _ -> false
    end
  end

  defp provider_not_used_message(record) do
    """
    the real ACP turn did not use the DeepSeek provider (recorded provider: #{inspect(record["provider"])}).

    The ACP path itself worked (the disposable project changed), so the model layer is what is
    missing. The platform wrapper only selects a provider when the provider credential is
    available, and the isolated runtime must never fall back to another provider's credential:

        ~/.config/agentic-dev-environment/env    # DEEPSEEK_API_KEY=<key> (chmod 600)
        ./doctor.sh | grep cline-model           # expected: PASS cline-model

    The measured mechanism and the evidence are recorded in `docs/fork/cline-acp-integration.md`
    and in the platform's ADR-0003.
    """
  end

  defp model_not_used_message(record, model) do
    """
    the real ACP turn used the provider "#{record["provider"]}" but not the expected model.

    expected: #{inspect(model)}
    recorded: #{inspect(record["model"])}

    Cline resolves the model from `CLINE_MODEL` and silently falls back to the provider default
    when that value is not a model of the provider, so the model really used must be checked. If
    the platform's default model changed on purpose, pass it explicitly:

        SYMPHONY_CLINE_DEEPSEEK_MODEL=<model-id> make cline-deepseek-e2e
    """
  end

  # Transient operational evidence (the operator reports it; it is never asserted
  # and never versioned -- see the platform's source-of-truth policy).
  defp report_usage(record) do
    usage = get_in(record, ["metadata", "usage"]) || %{}
    cost = get_in(record, ["metadata", "totalCost"])

    IO.puts(
      "[cline-deepseek-e2e] provider=#{record["provider"]} model=#{record["model"]} " <>
        "inputTokens=#{usage["inputTokens"]} outputTokens=#{usage["outputTokens"]} " <>
        "cacheReadTokens=#{usage["cacheReadTokens"]} totalCost=#{cost} (transient evidence, not versioned)"
    )
  end

  defp disposable_workspace!(command) do
    test_root = Path.join(System.tmp_dir!(), "symphony-cline-deepseek-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, @issue_identifier)

    # A `symphony-cline-deepseek-*` root left behind by a killed run would otherwise
    # be reused by the next VM (the integer is unique only inside one VM).
    File.rm_rf!(test_root)
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      executor_kind: "acp",
      acp_command: command,
      acp_auto_approve_requests: true,
      codex_read_timeout_ms: @read_timeout_ms,
      codex_turn_timeout_ms: @turn_timeout_ms,
      prompt: @task_prompt
    )

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace_root: workspace_root, workspace: workspace}
  end

  defp disposable_project!(command) do
    context = disposable_workspace!(command)

    File.write!(Path.join(context.workspace, "answer.sh"), @answer_script)
    git!(context.workspace, ["init", "-q", "-b", "main"])
    git!(context.workspace, ["add", "-A"])

    git!(context.workspace, [
      "-c",
      "user.name=Symphony E2E",
      "-c",
      "user.email=symphony@example.org",
      "commit",
      "-q",
      "-m",
      "disposable project"
    ])

    context
  end

  defp run_through_runner!(_context, issue) do
    test_pid = self()

    # Production selection, with no `executor:` injection: `Executor.module!()`
    # resolves `executor.kind: acp` from the workflow written above.
    outcome =
      Task.async(fn ->
        try do
          AgentRunner.run(issue, test_pid, issue_state_fetcher: &finished_issue_state/1, max_turns: 1)
        rescue
          error -> {:runner_error, Exception.message(error)}
        end
      end)
      |> Task.await(@runner_timeout_ms)

    case outcome do
      :ok ->
        assert Executor.module!() == Executor.Acp
        :ok

      {:runner_error, message} ->
        flunk(runner_failure(message))
    end
  end

  defp runner_failure(message) do
    if String.contains?(message, "acp_auth_required") do
      """
      the real Cline refused the ACP session: it is not authenticated in the isolated runtime.

      A real Cline was launched through `acp.command` and answered `session/new` with the ACP
      authentication error this client reports as `{:acp_auth_required, _}`. For the DeepSeek
      provider the pipeline's wrapper delivers the credential to the agent process, so this
      failure means the provider credential is missing (or the isolated Cline has neither that
      credential nor a restorable one):

          ~/.config/agentic-dev-environment/env    # DEEPSEEK_API_KEY=<key> (chmod 600)
          ./doctor.sh | grep cline-model           # expected: PASS cline-model

      Symphony stores no agent credential by design; then rerun (the workspace of the run is
      disposable and already removed):

          make cline-deepseek-e2e

      runner error: #{message}
      """
    else
      "the real Cline turn failed through AgentRunner -> Executor.Acp -> ACP.Client: #{message}"
    end
  end

  defp git_changed_paths(workspace) do
    {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.slice(3..-1//1) |> String.trim() end)
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (status #{status}): #{String.trim(output)}")
    end
  end

  defp assert_agent_process_gone!(os_pid, attempts \\ 50)

  defp assert_agent_process_gone!(os_pid, 0) do
    flunk("the ACP agent process launched by the client is still alive after teardown (os pid #{os_pid})")
  end

  defp assert_agent_process_gone!(os_pid, attempts) do
    if File.dir?("/proc/#{os_pid}") do
      Process.sleep(100)
      assert_agent_process_gone!(os_pid, attempts - 1)
    else
      :ok
    end
  end

  defp work_item do
    %Issue{
      id: @issue_id,
      identifier: @issue_identifier,
      title: "Change the answer of the disposable project with DeepSeek",
      description: "Real Cline turn over ACP using the DeepSeek provider in a disposable workspace",
      state: "In Progress",
      url: "https://example.org/issues/#{@issue_identifier}",
      labels: []
    }
  end

  defp finished_issue_state(issue_ids) do
    {:ok, Enum.map(issue_ids, fn id -> %Issue{id: id, identifier: @issue_identifier, state: "Done"} end)}
  end
end

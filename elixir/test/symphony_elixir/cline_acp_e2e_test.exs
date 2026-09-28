defmodule SymphonyElixir.ClineAcpE2ETest do
  @moduledoc """
  Opt-in integration test: the **real Cline CLI** as the ACP agent of the path
  the fork already implements.

  The deterministic suite (`test/symphony_elixir/acp_test.exs`) proves the ACP
  path against a fake agent and never needs a model, a network or a credential.
  This file is the other half: it launches the agent really installed in the
  platform's isolated runtime through the production path
  (`AgentRunner -> Executor.Acp -> ACP.Client -> stdio/JSON-RPC`) and looks for a
  verifiable effect in a disposable project.

  It is explicitly opt-in, so it never runs in `make all` and CI never depends on
  a model, a network or a credential:

      make cline-acp-e2e
      # equivalent:
      SYMPHONY_RUN_CLINE_ACP_E2E=1 mix test test/symphony_elixir/cline_acp_e2e_test.exs

  Environment:

    * `SYMPHONY_CLINE_ACP_COMMAND` — the `acp.command` used by the executor.
      Default: the platform wrapper `$HOME/automation/bin/cline --acp`, which
      injects the isolated data-dir. A personal Cline installation is never
      used, and no credential is ever passed by Symphony.
    * `SYMPHONY_RUN_CLINE_ACP_E2E=1` — the gate; without it both tests are
      skipped.

  What makes the full-turn test pass is a real turn: the agent must change the
  disposable project and the deterministic check must then pass. If the isolated
  runtime is not authenticated, the run blocks with `acp_auth_required` and the
  failure message names the human step (`~/automation/bin/cline auth`); the test
  never fabricates a pass, never authenticates on the agent's behalf and never
  carries a credential.

  Permissions: `acp.auto_approve_requests: true` is configured **for this
  disposable workspace only**, as an explicit per-run decision, so the agent can
  edit its own workspace without blocking the turn. The global default stays
  fail-closed and nothing here generalizes to a real consumer project.

  Measured state, evidence and the phase status are recorded in
  `docs/fork/cline-acp-integration.md`.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ACP.Client
  alias SymphonyElixir.Executor

  @run_gate "SYMPHONY_RUN_CLINE_ACP_E2E"
  @command_env "SYMPHONY_CLINE_ACP_COMMAND"
  @issue_id "issue-cline-acp-e2e"
  @issue_identifier "MT-CLINE"

  @read_timeout_ms 60_000
  @turn_timeout_ms 600_000
  @runner_timeout_ms 600_000

  @skip_reason if System.get_env(@run_gate) != "1",
                 do: "set #{@run_gate}=1 (or `make cline-acp-e2e`) to run the real Cline ACP integration test"

  @answer_script """
  #!/usr/bin/env bash
  # Prints the number this project is expected to produce.
  echo "1"
  """

  @task_prompt "The file answer.sh in this workspace prints the wrong number. " <>
                 "Change that file so that running `bash answer.sh` prints exactly 42 and nothing else, " <>
                 "then run it yourself to confirm the output is exactly 42. " <>
                 "Work only inside this workspace: do not create, delete or modify any other file, " <>
                 "do not use the network and do not commit. Work item {{ issue.identifier }}."

  @moduletag :cline_acp_e2e
  @moduletag timeout: 900_000

  @tag skip: @skip_reason
  test "the real Cline CLI completes the ACP handshake through ACP.Client" do
    command = cline_command!()
    context = disposable_workspace!(command, "handshake")

    {:ok, client} = Client.start(context.workspace, command: command, read_timeout_ms: @read_timeout_ms)

    assert {:ok, handshake} = Client.initialize(client)
    assert handshake.protocol_version == 1
    assert handshake.agent_info["name"] == "cline"
    assert is_binary(handshake.agent_info["version"])
    assert is_map(handshake.agent_capabilities)
    assert is_list(handshake.auth_methods)

    # `session/new` is where a real agent asks for what the client refuses to
    # fabricate. Both accepted answers are a real, parsed ACP frame from the real
    # agent: a session, or the explicit authentication block. Anything else
    # (timeout, malformed frame, unexpected error shape) fails here on purpose.
    case Client.new_session(client) do
      {:ok, session_id} ->
        assert is_binary(session_id)

      {:error, {:acp_auth_required, methods}} ->
        assert is_list(methods)

      other ->
        flunk("real Cline answered `session/new` with an unexpected ACP result: #{inspect(other)}")
    end

    assert :ok = Client.close(client)
  end

  @tag skip: @skip_reason
  test "AgentRunner drives a real Cline turn through Executor.Acp and the disposable project changes" do
    command = cline_command!()
    context = disposable_project!(command)
    issue = work_item()

    run_through_runner!(context, issue)

    # The deterministic check of the disposable project the prompt asked for.
    {output, status} = System.cmd("bash", ["answer.sh"], cd: context.workspace, stderr_to_stdout: true)
    assert status == 0
    assert String.trim(output) == "42"
    refute File.read!(Path.join(context.workspace, "answer.sh")) == @answer_script

    # Only the file the prompt asked for may change in the disposable project. An
    # empty worktree is accepted as well: committing inside the throwaway repo is
    # harmless and still leaves no change outside `answer.sh`.
    changed = git_changed_paths(context.workspace)

    assert changed in [[], ["answer.sh"]],
           "only answer.sh may change in the disposable project, got: #{inspect(changed)}"

    # Nothing outside the disposable workspace of this test was involved.
    assert String.starts_with?(context.workspace, context.test_root)

    # Evidence collected through the runner's own update channel, then teardown.
    assert_receive {:codex_worker_update, @issue_id, %{event: :session_started, codex_app_server_pid: os_pid}}
    assert_receive {:codex_worker_update, @issue_id, %{event: :turn_completed}}
    assert_agent_process_gone!(os_pid)
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

  defp disposable_workspace!(command, label) do
    test_root = Path.join(System.tmp_dir!(), "symphony-cline-acp-#{label}-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, @issue_identifier)

    # A `symphony-cline-acp-*` root left behind by a killed run would otherwise be
    # reused by the next VM (the integer is unique only inside one VM).
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
    context = disposable_workspace!(command, "turn")

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

      A real Cline was launched through `acp.command` and answered `session/new` with the
      ACP authentication error this client reports as `{:acp_auth_required, _}`. Symphony
      stores no agent credential by design, so this is a human step:

          ~/automation/bin/cline auth

      Then rerun (the workspace of the run is disposable and already removed):

          make cline-acp-e2e

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
      title: "Change the answer of the disposable project",
      description: "Real Cline turn over ACP in a disposable workspace",
      state: "In Progress",
      url: "https://example.org/issues/#{@issue_identifier}",
      labels: []
    }
  end

  defp finished_issue_state(issue_ids) do
    {:ok, Enum.map(issue_ids, fn id -> %Issue{id: id, identifier: @issue_identifier, state: "Done"} end)}
  end
end

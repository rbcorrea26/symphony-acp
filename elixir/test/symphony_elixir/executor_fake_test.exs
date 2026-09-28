defmodule SymphonyElixir.Executor.Fake do
  @moduledoc """
  Deterministic, offline test double for the `SymphonyElixir.Executor` behaviour.

  It exists to prove the executor abstraction without Cline, without a model
  provider, without network access and without credentials. It is defined by the
  test suite on purpose: it is never registered in `SymphonyElixir.Executor`, so
  no workflow can select it as a real executor, and it only reads and writes
  files inside the workspace it is given.

  Behavior is fully controlled by two files inside that workspace:

    * `fake-executor.plan` (optional) — one directive per line, `#` starts a
      comment, `start` covers session startup and `<turn>` is a 1-based turn:
      - `start fail` — `start_session/2` fails with `{:fake_start_failed, workspace}`
      - `<turn> ok` — the turn completes with one notification (the default)
      - `<turn> messages <count>` — emit `count` notifications before completing
      - `<turn> fail` — fails with `{:turn_failed, %{stop_reason: "fake_turn_failed"}}`
      - `<turn> cancel` — cancels with `{:turn_cancelled, %{stop_reason: "cancelled"}}`
    * `fake-executor.trace` (written) — lifecycle trace used by tests to assert
      turn count and teardown without global state: `session_started`,
      `turn_started <n>`, `turn_message <n> <i>`,
      `turn_completed|turn_failed|turn_cancelled <n>` and `session_stopped`.

  Events follow the shape the orchestrator consumes
  (`%{event: atom, timestamp: DateTime, session_id: String.t(), payload: map()}`)
  with the session and notification vocabulary mapped in
  `docs/fork/adr/0002-acp-protocol-mapping.md` §2.3–§2.4, including the composed
  `<session>-<turn>` session id.
  """

  @behaviour SymphonyElixir.Executor

  @plan_filename "fake-executor.plan"
  @trace_filename "fake-executor.trace"
  @provider_session_id "fake-session"
  @turn_actions ["ok", "fail", "cancel"]
  @default_turn %{action: "ok", messages: 1}

  @impl true
  def start_session(workspace, _opts) do
    with {:ok, plan} <- load_plan(workspace) do
      case plan.start do
        "fail" ->
          {:error, {:fake_start_failed, workspace}}

        _start ->
          trace(workspace, "session_started")

          {:ok, %{workspace: workspace, session_id: @provider_session_id}}
      end
    end
  end

  @impl true
  def run_turn(session, _prompt, _issue, opts) do
    if session_stopped?(session.workspace) do
      {:error, {:session_stopped, session.session_id}}
    else
      run_planned_turn(session, opts)
    end
  end

  @impl true
  def stop_session(%{workspace: workspace}) do
    trace(workspace, "session_stopped")
  end

  defp run_planned_turn(session, opts) do
    workspace = session.workspace
    turn = next_turn_number(workspace)
    session_id = "#{session.session_id}-#{turn}"
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    {:ok, plan} = load_plan(workspace)
    directive = Map.get(plan.turns, turn, @default_turn)

    trace(workspace, "turn_started #{turn}")
    emit(on_message, :session_started, %{"sessionId" => session_id, "turn" => turn}, session_id)
    emit_messages(on_message, workspace, turn, session_id, directive.messages)

    finish_turn(on_message, workspace, turn, session_id, directive.action)
  end

  defp finish_turn(on_message, workspace, turn, session_id, "fail") do
    reason = %{stop_reason: "fake_turn_failed"}

    emit(on_message, :turn_failed, Map.put(reason, "sessionId", session_id), session_id)
    trace(workspace, "turn_failed #{turn}")

    {:error, {:turn_failed, reason}}
  end

  defp finish_turn(on_message, workspace, turn, session_id, "cancel") do
    reason = %{stop_reason: "cancelled"}

    emit(on_message, :turn_cancelled, Map.put(reason, "sessionId", session_id), session_id)
    trace(workspace, "turn_cancelled #{turn}")

    {:error, {:turn_cancelled, reason}}
  end

  defp finish_turn(on_message, workspace, turn, session_id, "ok") do
    emit(
      on_message,
      :turn_completed,
      %{"sessionId" => session_id, "stopReason" => "end_turn", "turn" => turn},
      session_id
    )

    trace(workspace, "turn_completed #{turn}")

    {:ok, %{result: %{stop_reason: "end_turn"}, session_id: session_id, turn_id: turn}}
  end

  defp emit_messages(_on_message, _workspace, _turn, _session_id, 0), do: :ok

  defp emit_messages(on_message, workspace, turn, session_id, count) when is_integer(count) do
    Enum.each(1..count, fn index ->
      emit(
        on_message,
        :notification,
        %{
          "sessionId" => session_id,
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "fake message #{index}"}
        },
        session_id
      )

      trace(workspace, "turn_message #{turn} #{index}")
    end)
  end

  defp emit(on_message, event, payload, session_id) do
    on_message.(%{event: event, timestamp: DateTime.utc_now(), session_id: session_id, payload: payload})
  end

  defp default_on_message(_message), do: :ok

  defp session_stopped?(workspace), do: Enum.member?(trace_lines(workspace), "session_stopped")

  defp next_turn_number(workspace) do
    workspace
    |> trace_lines()
    |> Enum.count(&String.starts_with?(&1, "turn_started "))
    |> Kernel.+(1)
  end

  defp trace_lines(workspace) do
    case File.read(trace_path(workspace)) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp trace(workspace, line) do
    File.write!(trace_path(workspace), line <> "\n", [:append])
  end

  defp trace_path(workspace), do: Path.join(workspace, @trace_filename)

  defp load_plan(workspace) do
    case File.read(Path.join(workspace, @plan_filename)) do
      {:ok, content} -> parse_plan(content)
      {:error, :enoent} -> {:ok, empty_plan()}
      {:error, reason} -> {:error, {:fake_plan_unreadable, reason}}
    end
  end

  defp parse_plan(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({:ok, empty_plan()}, fn line, {:ok, plan} ->
      case parse_directive(line) do
        {:ok, directive} -> {:cont, {:ok, add_directive(plan, directive)}}
        :error -> {:halt, {:error, {:fake_plan_invalid, line}}}
      end
    end)
  end

  defp empty_plan, do: %{start: "ok", turns: %{}}

  defp add_directive(plan, %{scope: :start, action: action}), do: %{plan | start: action}

  defp add_directive(plan, %{scope: :turn, turn: turn} = directive) do
    put_in(plan, [:turns, turn], Map.take(directive, [:action, :messages]))
  end

  defp parse_directive(line) do
    case String.split(line) do
      ["start"] -> {:ok, %{scope: :start, action: "ok"}}
      ["start", "fail"] -> {:ok, %{scope: :start, action: "fail"}}
      [turn, action] -> parse_turn(turn, action, default_message_count(action))
      [turn, "messages", count] -> parse_turn(turn, "ok", count)
      _other -> :error
    end
  end

  defp default_message_count("ok"), do: "1"
  defp default_message_count(_action), do: "0"

  defp parse_turn(turn, action, count) when action in @turn_actions do
    with {turn_number, ""} <- Integer.parse(turn),
         true <- turn_number >= 1,
         {messages, ""} <- Integer.parse(count),
         true <- messages >= 0 do
      {:ok, %{scope: :turn, turn: turn_number, action: action, messages: messages}}
    else
      _invalid -> :error
    end
  end

  defp parse_turn(_turn, _action, _count), do: :error
end

defmodule SymphonyElixir.ExecutorFakeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Executor
  alias SymphonyElixir.Executor.Fake

  describe "fake executor (lifecycle contract)" do
    test "drives session start, multiple turns, notifications and stop deterministically" do
      workspace = workspace_with_plan!("2 messages 2")
      test_pid = self()
      on_message = fn message -> send(test_pid, {:fake_executor_message, message}) end

      assert {:ok, session} = Fake.start_session(workspace, worker_host: nil)
      assert session.session_id == "fake-session"

      assert {:ok, first_turn} = Fake.run_turn(session, "first prompt", issue(), on_message: on_message)
      assert first_turn == %{result: %{stop_reason: "end_turn"}, session_id: "fake-session-1", turn_id: 1}

      assert_receive {:fake_executor_message,
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: "fake-session-1",
                        payload: %{"turn" => 1}
                      }}

      assert_receive {:fake_executor_message,
                      %{
                        event: :notification,
                        payload: %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => %{"type" => "text", "text" => "fake message 1"}
                        }
                      }}

      assert_receive {:fake_executor_message, %{event: :turn_completed, session_id: "fake-session-1"}}

      assert {:ok, second_turn} = Fake.run_turn(session, "continuation prompt", issue(), on_message: on_message)
      assert second_turn.session_id == "fake-session-2"

      assert_receive {:fake_executor_message, %{event: :session_started, session_id: "fake-session-2"}}
      assert_receive {:fake_executor_message, %{event: :notification, payload: %{"content" => %{"text" => "fake message 1"}}}}
      assert_receive {:fake_executor_message, %{event: :notification, payload: %{"content" => %{"text" => "fake message 2"}}}}
      assert_receive {:fake_executor_message, %{event: :turn_completed, session_id: "fake-session-2"}}

      assert :ok = Fake.stop_session(session)

      assert trace_lines(workspace) == [
               "session_started",
               "turn_started 1",
               "turn_message 1 1",
               "turn_completed 1",
               "turn_started 2",
               "turn_message 2 1",
               "turn_message 2 2",
               "turn_completed 2",
               "session_stopped"
             ]
    end

    test "fails a turn deterministically" do
      workspace = workspace_with_plan!("1 fail")
      test_pid = self()

      assert {:ok, session} = Fake.start_session(workspace, [])

      assert {:error, {:turn_failed, %{stop_reason: "fake_turn_failed"}}} =
               Fake.run_turn(session, "prompt", issue(), on_message: fn message -> send(test_pid, message) end)

      assert_receive %{event: :turn_failed, session_id: "fake-session-1"}
      assert :ok = Fake.stop_session(session)

      assert trace_lines(workspace) == ["session_started", "turn_started 1", "turn_failed 1", "session_stopped"]
    end

    test "cancels a turn deterministically" do
      workspace = workspace_with_plan!("1 cancel")

      assert {:ok, session} = Fake.start_session(workspace, [])

      assert {:error, {:turn_cancelled, %{stop_reason: "cancelled"}}} = Fake.run_turn(session, "prompt", issue(), [])

      assert trace_lines(workspace) == ["session_started", "turn_started 1", "turn_cancelled 1"]
    end

    test "fails session startup deterministically without opening a session" do
      workspace = workspace_with_plan!("start fail")

      assert {:error, {:fake_start_failed, ^workspace}} = Fake.start_session(workspace, [])
      assert trace_lines(workspace) == []
    end

    test "rejects invalid plan lines and unsupported directives" do
      assert {:error, {:fake_plan_invalid, "1 bananas"}} =
               "1 bananas" |> workspace_with_plan!() |> Fake.start_session([])

      assert {:error, {:fake_plan_invalid, "start bananas"}} =
               "start bananas" |> workspace_with_plan!() |> Fake.start_session([])

      assert {:error, {:fake_plan_invalid, "0 ok"}} =
               "0 ok" |> workspace_with_plan!() |> Fake.start_session([])
    end

    test "ignores an absent plan and refuses turns after the session is stopped" do
      workspace = workspace_with_plan!(nil)
      test_pid = self()

      assert {:ok, session} = Fake.start_session(workspace, [])
      assert :ok = Fake.stop_session(session)

      assert {:error, {:session_stopped, "fake-session"}} =
               Fake.run_turn(session, "prompt", issue(), on_message: fn message -> send(test_pid, message) end)

      refute_receive {:fake_executor_message, _message}
      assert trace_lines(workspace) == ["session_started", "session_stopped"]
    end
  end

  describe "agent runner through the executor abstraction" do
    test "runs every turn through the injected executor and preserves continuation" do
      test_root = Path.join(System.tmp_dir!(), "symphony-executor-fake-runner-#{System.unique_integer([:positive])}")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        issue = fake_issue()
        workspace = Path.join(workspace_root, Workspace.workspace_key(issue))

        File.mkdir_p!(workspace)
        File.write!(plan_path(workspace), "1 messages 2\n")

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, max_turns: 2)

        test_pid = self()
        state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "In Progress", dispatchable: true}]} end

        assert :ok = AgentRunner.run(issue, test_pid, executor: Executor.Fake, issue_state_fetcher: state_fetcher)

        assert_receive {:worker_runtime_info, "issue-executor-fake", %{workspace_path: ^workspace}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :session_started, session_id: "fake-session-1"}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :notification, payload: %{"content" => %{"text" => "fake message 1"}}}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :notification, payload: %{"content" => %{"text" => "fake message 2"}}}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :turn_completed, session_id: "fake-session-1"}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :session_started, session_id: "fake-session-2"}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :notification, payload: %{"content" => %{"text" => "fake message 1"}}}}
        assert_receive {:codex_worker_update, "issue-executor-fake", %{event: :turn_completed, session_id: "fake-session-2"}}

        assert trace_lines(workspace) == [
                 "session_started",
                 "turn_started 1",
                 "turn_message 1 1",
                 "turn_message 1 2",
                 "turn_completed 1",
                 "turn_started 2",
                 "turn_message 2 1",
                 "turn_completed 2",
                 "session_stopped"
               ]
      after
        File.rm_rf(test_root)
      end
    end

    test "surfaces a deterministic executor failure and still stops the session" do
      test_root = Path.join(System.tmp_dir!(), "symphony-executor-fake-failure-#{System.unique_integer([:positive])}")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        issue = fake_issue()
        workspace = Path.join(workspace_root, Workspace.workspace_key(issue))

        File.mkdir_p!(workspace)
        File.write!(plan_path(workspace), "1 fail\n")

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert_raise RuntimeError, ~r/turn_failed/, fn ->
          AgentRunner.run(issue, nil, executor: Executor.Fake, issue_state_fetcher: &inactive_issue_state/1)
        end

        assert trace_lines(workspace) == ["session_started", "turn_started 1", "turn_failed 1", "session_stopped"]
      after
        File.rm_rf(test_root)
      end
    end

    test "surfaces a startup failure without stopping a session that never started" do
      test_root = Path.join(System.tmp_dir!(), "symphony-executor-fake-start-failure-#{System.unique_integer([:positive])}")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        issue = fake_issue()
        workspace = Path.join(workspace_root, Workspace.workspace_key(issue))

        File.mkdir_p!(workspace)
        File.write!(plan_path(workspace), "start fail\n")

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert_raise RuntimeError, ~r/fake_start_failed/, fn ->
          AgentRunner.run(issue, nil, executor: Executor.Fake, issue_state_fetcher: &inactive_issue_state/1)
        end

        refute File.exists?(trace_path(workspace))
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp workspace_with_plan!(plan) do
    workspace = Path.join(System.tmp_dir!(), "symphony-fake-executor-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    if is_binary(plan), do: File.write!(plan_path(workspace), plan)

    on_exit(fn -> File.rm_rf(workspace) end)

    workspace
  end

  defp plan_path(workspace), do: Path.join(workspace, "fake-executor.plan")

  defp trace_path(workspace), do: Path.join(workspace, "fake-executor.trace")

  defp trace_lines(workspace) do
    case File.read(trace_path(workspace)) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp fake_issue do
    %Issue{
      id: "issue-executor-fake",
      identifier: "MT-FAKE",
      title: "Drive the runner through the executor abstraction",
      description: "Deterministic executor with no model, no network and no credentials",
      state: "In Progress",
      url: "https://example.org/issues/MT-FAKE",
      labels: []
    }
  end

  defp issue do
    %Issue{
      id: "issue-fake-executor",
      identifier: "MT-FAKE-UNIT",
      title: "Fake executor unit contract",
      description: "Deterministic executor contract",
      state: "In Progress",
      url: "https://example.org/issues/MT-FAKE-UNIT",
      labels: []
    }
  end

  defp inactive_issue_state(issue_ids) do
    {:ok, Enum.map(issue_ids, fn id -> %Issue{id: id, identifier: "MT-FAKE", state: "Done"} end)}
  end
end

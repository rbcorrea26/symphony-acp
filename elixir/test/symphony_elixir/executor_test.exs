defmodule SymphonyElixir.ExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Executor

  @executor_callbacks [start_session: 2, run_turn: 4, stop_session: 1]
  @optional_executor_callbacks [validate_config: 1]

  test "executor behaviour requires the surface the agent runner uses" do
    assert Enum.sort(Executor.behaviour_info(:callbacks)) ==
             Enum.sort(@executor_callbacks ++ @optional_executor_callbacks)

    assert Executor.behaviour_info(:optional_callbacks) == @optional_executor_callbacks
  end

  test "codex executor declares the executor behaviour" do
    assert [Executor] = Executor.Codex.module_info(:attributes)[:behaviour]
  end

  test "executor.kind defaults to codex when the workflow has no executor block" do
    refute String.contains?(File.read!(Workflow.workflow_file_path()), "executor:")

    assert :ok = Config.validate!()
    assert Config.settings!().executor.kind == "codex"
    assert Executor.module!() == Executor.Codex
  end

  test "executor.kind codex selects the Codex delegate" do
    write_workflow_file!(Workflow.workflow_file_path(), executor_kind: "codex")

    assert Executor.module!() == Executor.Codex
    assert :ok = Executor.validate_config(Config.settings!())
  end

  test "for_kind resolves codex and rejects every other kind" do
    assert {:ok, Executor.Codex} = Executor.for_kind("codex")
    assert {:ok, Executor.Acp} = Executor.for_kind("acp")
    assert {:error, {:unsupported_executor_kind, ""}} = Executor.for_kind("")
    assert {:error, {:unsupported_executor_kind, nil}} = Executor.for_kind(nil)
  end

  test "unsupported executor kind fails dispatch preflight like an unsupported tracker kind" do
    write_workflow_file!(Workflow.workflow_file_path(), executor_kind: "acp-not-real")

    assert {:error, {:unsupported_executor_kind, "acp-not-real"}} = Config.validate!()

    assert {:error, {:unsupported_executor_kind, "acp-not-real"}} =
             Executor.validate_config(%{executor: %{kind: "acp-not-real"}, acp: %{command: nil}})
  end

  test "blank executor kind fails dispatch preflight" do
    write_workflow_file!(Workflow.workflow_file_path(), executor_kind: "")

    assert {:error, {:unsupported_executor_kind, ""}} = Config.validate!()
  end

  test "codex executor delegates session, turn and stop to the Codex app server client" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-executor-codex-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-EXECUTOR")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      write_fake_codex!(codex_binary)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-executor-codex",
        identifier: "MT-EXECUTOR",
        title: "Delegate to the Codex client",
        description: "Prove Executor.Codex is pure delegation",
        state: "In Progress",
        url: "https://example.org/issues/MT-EXECUTOR",
        labels: []
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:delegated_executor_message, message}) end

      assert {:ok, session} = Executor.Codex.start_session(workspace, worker_host: nil)
      assert {:ok, delegated_turn} = Executor.Codex.run_turn(session, "delegation prompt", issue, on_message: on_message)
      assert :ok = Executor.Codex.stop_session(session)

      assert_receive {:delegated_executor_message, %{event: :session_started, session_id: "thread-delegated-turn-delegated"}},
                     500

      assert_receive {:delegated_executor_message, %{event: :turn_completed}}, 500

      # Same arguments, same return value and same session term as the Codex client.
      assert {:ok, direct_turn} = AppServer.run(workspace, "delegation prompt", issue)
      assert delegated_turn == direct_turn
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_codex!(path) do
    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-delegated"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-delegated"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
        *) ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end
end

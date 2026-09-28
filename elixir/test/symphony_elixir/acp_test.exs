defmodule SymphonyElixir.AcpTest do
  @moduledoc """
  End-to-end proof of the ACP path.

  Every test in this file talks to `SymphonyElixir.ACP.FakeAgent`: a real,
  separate process launched by command, speaking the ACP protocol (JSON-RPC 2.0
  over stdio) exactly like a real agent would. Nothing here uses Cline, a model
  provider, the network or a credential.

  The fake agent is deterministic and programmed through `fake-acp.plan` in the
  workspace it is launched in, and it records what crossed the wire in
  `fake-acp.trace`. The script needs `bash` and `jq` (both already required by
  this repository: `jq` is used by the PR-description workflow).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ACP.Client
  alias SymphonyElixir.Executor
  alias SymphonyElixir.Executor.Acp

  @acp_session_id "sess-fake-acp"
  @acp_identifier "MT-ACP"
  @acp_issue_id "issue-acp-fake"

  describe "acp config" do
    test "executor.kind defaults to codex and the acp block defaults to fail closed" do
      refute String.contains?(File.read!(Workflow.workflow_file_path()), "acp:")

      assert :ok = Config.validate!()
      assert Config.settings!().executor.kind == "codex"
      assert Config.settings!().acp.command == nil
      assert Config.settings!().acp.auto_approve_requests == false
      assert Executor.module!() == Executor.Codex
    end

    test "executor.kind acp selects the ACP executor and requires a command" do
      write_workflow_file!(Workflow.workflow_file_path(), executor_kind: "acp")

      assert {:error, :missing_acp_command} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(), executor_kind: "acp", acp_command: "   ")

      assert {:error, :missing_acp_command} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(),
        executor_kind: "acp",
        acp_command: "/opt/acp/agent"
      )

      assert :ok = Config.validate!()
      assert Config.settings!().executor.kind == "acp"
      assert Config.settings!().acp.command == "/opt/acp/agent"
      assert Executor.module!() == Executor.Acp
      assert :ok = Executor.validate_config(Config.settings!())
    end

    test "acp.auto_approve_requests is explicit configuration, never implicit" do
      write_workflow_file!(Workflow.workflow_file_path(),
        executor_kind: "acp",
        acp_command: "/opt/acp/agent",
        acp_auto_approve_requests: true
      )

      assert :ok = Config.validate!()
      assert Config.settings!().acp.auto_approve_requests == true

      assert {:error, :missing_acp_command} = Executor.Acp.validate_config(%{acp: %{command: nil}})
      assert {:error, :missing_acp_command} = Executor.Acp.validate_config(%{acp: %{command: " "}})
      assert :ok = Executor.Acp.validate_config(%{acp: %{command: "acp-agent --stdio"}})
    end

    test "unknown executor kind still fails dispatch preflight" do
      write_workflow_file!(Workflow.workflow_file_path(),
        executor_kind: "acp-v2",
        acp_command: "/opt/acp/agent"
      )

      assert {:error, {:unsupported_executor_kind, "acp-v2"}} = Config.validate!()
    end

    test "invalid acp configuration is rejected while loading the workflow" do
      write_workflow_file!(Workflow.workflow_file_path(),
        executor_kind: "acp",
        acp_command: "/opt/acp/agent",
        acp_auto_approve_requests: "sometimes"
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "acp"
    end
  end

  describe "acp client" do
    test "handshake announces no client capability and creates the workspace session" do
      context = acp_setup!()
      refute File.exists?(plan_path(context.workspace))

      client = start_client!(context)

      assert {:ok, handshake} = Client.initialize(client)
      assert handshake.protocol_version == 1
      assert handshake.agent_capabilities == %{"loadSession" => false}
      assert handshake.agent_info["name"] == "fake-acp-agent"
      assert handshake.auth_methods == []

      assert {:ok, @acp_session_id} = Client.new_session(client)

      assert_trace_line!(
        context.workspace,
        "initialize_request protocolVersion=1 capabilities={} client=symphony"
      )

      assert_trace_line!(context.workspace, "session_new_request cwd=#{client.workspace} mcpServers=[]")
      assert :ok = Client.close(client)
    end

    test "initialize rejects a protocol version the client does not implement" do
      context = acp_setup!(plan: "initialize version 2")

      client = start_client!(context)

      assert {:error, {:acp_version_unsupported, 2}} = Client.initialize(client)
      assert_trace_line!(context.workspace, "initialize version 2")
      assert :ok = Client.close(client)
    end

    test "initialize rejects a handshake without a protocol version" do
      context = acp_setup!(plan: "initialize invalid")

      client = start_client!(context)

      assert {:error, {:acp_response_error, %{}}} = Client.initialize(client)
      assert :ok = Client.close(client)
    end

    test "initialize surfaces an agent error response" do
      context = acp_setup!(plan: "initialize error")

      client = start_client!(context)

      assert {:error, {:acp_response_error, %{"code" => -32_603}}} = Client.initialize(client)
      assert :ok = Client.close(client)
    end

    test "auth_required blocks the session and reports the announced methods" do
      context = acp_setup!(plan: "initialize auth_required")

      client = start_client!(context)

      assert {:error, {:acp_auth_required, [%{"id" => "fake-login", "name" => "Fake login"}]}} =
               Client.initialize(client)

      assert_trace_line!(context.workspace, "initialize auth_required")
      assert :ok = Client.close(client)
    end

    test "auth_required without method data still blocks with an explicit error" do
      context = acp_setup!(plan: "initialize auth_required_bare")

      client = start_client!(context)

      assert {:error, {:acp_auth_required, []}} = Client.initialize(client)
      assert :ok = Client.close(client)
    end

    test "initialize times out on silence instead of assuming compatibility" do
      context = acp_setup!(plan: "initialize silent")

      client = start_client!(context, read_timeout_ms: 150)

      assert {:error, :response_timeout} = Client.initialize(client)
      assert_trace_line!(context.workspace, "initialize silent")
      assert :ok = Client.close(client)
    end

    test "initialize tolerates an agent notification that arrives before its response" do
      context = acp_setup!(plan: "initialize notice")

      client = start_client!(context)

      assert {:ok, %{protocol_version: 1}} = Client.initialize(client)
      assert_trace_line!(context.workspace, "unknown_notification")
      assert :ok = Client.close(client)
    end

    test "session/new surfaces an agent error and a response without a session id" do
      context = acp_setup!(plan: "session/new error")

      client = start_client!(context)
      assert {:ok, _handshake} = Client.initialize(client)
      assert {:error, {:acp_response_error, %{"code" => -32_603}}} = Client.new_session(client)
      assert :ok = Client.close(client)

      context = acp_setup!(plan: "session/new invalid")

      client = start_client!(context)
      assert {:ok, _handshake} = Client.initialize(client)
      assert {:error, {:acp_response_error, %{}}} = Client.new_session(client)
      assert :ok = Client.close(client)
    end

    test "initialize reassembles frames that arrive in partial chunks" do
      context = acp_setup!(plan: "turn 1 messages 1")
      client = start_client!(context, line_bytes: 32)

      assert {:ok, %{protocol_version: 1}} = Client.initialize(client)
      assert {:ok, @acp_session_id} = Client.new_session(client)
      assert {:ok, %{stop_reason: "end_turn"}} = Client.prompt(client, @acp_session_id, "split prompt")
      assert_trace_line!(context.workspace, "turn_response end_turn")
      assert :ok = Client.close(client)
    end

    test "initialize rejects a response without a result and ignores bare json frames" do
      context = acp_setup!(plan: "initialize bare")
      client = start_client!(context)
      assert {:error, {:acp_response_error, %{"id" => 1}}} = Client.initialize(client)
      assert_trace_line!(context.workspace, "initialize bare")
      assert :ok = Client.close(client)

      context = acp_setup!(plan: "initialize noisejson")
      client = start_client!(context)
      assert {:ok, %{protocol_version: 1}} = Client.initialize(client)
      assert :ok = Client.close(client)
    end

    test "a client request outside the baseline fails the handshake explicitly" do
      context = acp_setup!(plan: "initialize unsupported")
      client = start_client!(context)

      assert {:error, {:acp_unsupported_request, "fs/read_text_file"}} = Client.initialize(client)
      assert_trace_line!(context.workspace, "unsupported_request fs/read_text_file")
      assert_trace_line!(context.workspace, "unsupported_response -32601")
      assert :ok = Client.close(client)
    end
  end

  describe "acp prompt turns" do
    test "prompt streams session updates and returns the stop reason" do
      context = acp_setup!(plan: "turn 1 messages 2")
      {client, session_id} = handshake!(context)

      assert {:ok, turn} =
               Client.prompt(client, session_id, "do the work", on_event: forward_acp_events())

      assert turn.stop_reason == "end_turn"
      assert turn.result == %{"stopReason" => "end_turn"}
      assert is_binary(turn.raw)

      assert_receive {:acp_event, %{type: :notification, payload: payload, raw: raw}}
      assert payload["sessionId"] == @acp_session_id
      assert %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text"}} = payload["update"]
      assert is_binary(raw)

      assert_receive {:acp_event, %{type: :notification}}
      refute_receive {:acp_event, _event}, 50

      assert_trace_line!(context.workspace, "prompt_request turn=1 sessionId=#{@acp_session_id} content=text")
      assert_trace_line!(context.workspace, "turn_response end_turn")
      assert :ok = Client.close(client)
    end

    test "prompt preserves the protocol session and request identity across turns" do
      context = acp_setup!(plan: "turn 1 ok\n\n# continuation\nturn 2 ok")
      {client, session_id} = handshake!(context)

      assert {:ok, %{stop_reason: "end_turn"}} = Client.prompt(client, session_id, "first prompt")
      assert {:ok, %{stop_reason: "end_turn"}} = Client.prompt(client, session_id, "second prompt")

      assert_trace_line!(context.workspace, "prompt_request turn=1 sessionId=#{@acp_session_id} content=text")
      assert_trace_line!(context.workspace, "prompt_request turn=2 sessionId=#{@acp_session_id} content=text")
      assert :ok = Client.close(client)
    end

    test "prompt returns every non-success stop reason unchanged" do
      plans = [
        {"turn 1 fail refusal", "refusal"},
        {"turn 1 fail max_tokens", "max_tokens"},
        {"turn 1 cancel", "cancelled"}
      ]

      for {directive, stop_reason} <- plans do
        context = acp_setup!(plan: directive)
        {client, session_id} = handshake!(context)

        assert {:ok, %{stop_reason: ^stop_reason}} = Client.prompt(client, session_id, "prompt")
        assert_trace_line!(context.workspace, "turn_response #{stop_reason}")
        assert :ok = Client.close(client)
      end
    end

    test "prompt times out on agent silence while the request is pending" do
      context = acp_setup!(plan: "turn 1 silent")
      {client, session_id} = handshake!(context, turn_timeout_ms: 150)

      assert {:error, :turn_timeout} = Client.prompt(client, session_id, "silent prompt")
      assert_trace_line!(context.workspace, "turn silent 1")
      assert :ok = Client.close(client)
    end

    test "prompt reports an unexpected process exit mid turn" do
      context = acp_setup!(plan: "turn 1 crash")
      {client, session_id} = handshake!(context)

      assert {:error, {:port_exit, 3}} = Client.prompt(client, session_id, "crashing prompt")
      assert_trace_line!(context.workspace, "turn crash 1")
      assert :ok = Client.close(client)
    end

    test "prompt rejects a result without a stop reason and an agent error response" do
      context = acp_setup!(plan: "turn 1 invalid")
      {client, session_id} = handshake!(context)
      assert {:error, {:acp_response_error, nil}} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "turn_response invalid")
      assert :ok = Client.close(client)

      context = acp_setup!(plan: "turn 1 error")
      {client, session_id} = handshake!(context)
      assert {:error, {:acp_response_error, %{"code" => -32_603}}} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "turn_response error")
      assert :ok = Client.close(client)
    end

    test "prompt keeps the turn alive through malformed frames, non json noise and bare json frames" do
      context = acp_setup!(plan: "turn 1 malformed\nturn 2 noise\nturn 3 noisejson")
      {client, session_id} = handshake!(context)
      test_pid = self()
      on_event = fn event -> send(test_pid, {:acp_event, event}) end

      assert {:ok, %{stop_reason: "end_turn"}} = Client.prompt(client, session_id, "prompt", on_event: on_event)
      assert_receive {:acp_event, %{type: :malformed, payload: payload}}
      assert payload =~ ~s({"jsonrpc":"2.0","id":)
      assert_receive {:acp_event, %{type: :notification}}
      refute_receive {:acp_event, %{type: :malformed}}

      log =
        capture_log(fn ->
          assert {:ok, %{stop_reason: "end_turn"}} = Client.prompt(client, session_id, "prompt", on_event: on_event)
        end)

      assert log =~ "fake-acp: warning: this line is not JSON"
      assert_receive {:acp_event, %{type: :notification, raw: raw}}
      assert raw =~ "after non-json line"

      assert {:ok, %{stop_reason: "end_turn"}} = Client.prompt(client, session_id, "prompt", on_event: on_event)
      assert_receive {:acp_event, %{type: :notification, payload: %{"note" => _note}}}
      assert :ok = Client.close(client)
    end
  end

  describe "acp stderr separation" do
    test "agent diagnostics on stderr never reach the parser during initialize" do
      context = acp_setup!(plan: "initialize stderr_probe")
      client = start_client!(context)

      # The frame the agent wrote to stderr carries this request id and an
      # unsupported protocol version: if stderr were merged into the protocol
      # stream, `initialize` would answer with it instead of the stdout response.
      assert {:ok, %{protocol_version: 1}} = Client.initialize(client)

      assert_trace_line!(context.workspace, "stderr_probe initialize")
      assert :ok = Client.close(client)
    end

    test "a stderr frame cannot answer a pending initialize" do
      context = acp_setup!(plan: "initialize stderr_silent")
      client = start_client!(context, read_timeout_ms: 150)

      assert {:error, :response_timeout} = Client.initialize(client)
      assert_trace_line!(context.workspace, "stderr_probe initialize")
      assert :ok = Client.close(client)
    end

    test "a stderr frame cannot fabricate a session id" do
      context = acp_setup!(plan: "session/new stderr_probe")
      {client, session_id} = handshake!(context)

      assert session_id == @acp_session_id
      refute session_id == "sess-from-stderr"
      assert_trace_line!(context.workspace, "stderr_probe session_new")
      assert :ok = Client.close(client)
    end

    test "stderr content cannot satisfy a pending prompt or change its stop reason" do
      context = acp_setup!(plan: "turn 1 stderr_probe")
      {client, session_id} = handshake!(context)

      assert {:ok, turn} =
               Client.prompt(client, session_id, "prompt", on_event: forward_acp_events())

      assert turn.result == %{"stopReason" => "end_turn"}

      # The first event is the real stdout `session/update`; a notification built
      # from the stderr probe would fail these assertions.
      assert_receive {:acp_event, %{type: :notification, payload: payload, raw: raw}}
      assert payload["sessionId"] == @acp_session_id
      assert payload["update"]["sessionUpdate"] == "agent_message_chunk"
      refute raw =~ "stderr"

      refute_receive {:acp_event, %{type: :malformed}}, 50
      refute_receive {:acp_event, _event}, 50

      assert_trace_line!(context.workspace, "stderr_probe turn 1")
      assert :ok = Client.close(client)
    end

    test "a stderr frame cannot answer a pending prompt" do
      context = acp_setup!(plan: "turn 1 stderr_silent")
      {client, session_id} = handshake!(context, turn_timeout_ms: 150)

      assert {:error, :turn_timeout} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "stderr_probe turn 1")
      assert :ok = Client.close(client)
    end

    test "non-JSON on stdout is still tolerated and still logged" do
      context = acp_setup!(plan: "initialize noise")
      client = start_client!(context)

      log = capture_log(fn -> assert {:ok, %{protocol_version: 1}} = Client.initialize(client) end)

      assert log =~ "ACP stdout output: fake-acp: warning: this line is not JSON"
      assert_trace_line!(context.workspace, "initialize noise")
      assert :ok = Client.close(client)
    end

    test "the remote worker command keeps stderr out of the protocol stream" do
      previous_path = System.get_env("PATH")
      on_exit(fn -> restore_env("PATH", previous_path) end)

      context =
        acp_setup!(plan: "initialize stderr_probe\nsession/new stderr_probe\nturn 1 stderr_probe")

      ssh_trace = Path.join(context.test_root, "ssh.trace")
      install_fake_ssh!(context.test_root, ssh_trace)

      {client, session_id} = handshake!(context, worker_host: "acp-worker")

      # `ssh` forwards the remote stderr to its own stderr, so the same separation
      # has to hold for the remote path: the probe answers a spoofed session id and
      # a spoofed stop reason, and neither may win.
      assert session_id == @acp_session_id
      assert client.metadata.worker_host == "acp-worker"

      assert {:ok, turn} =
               Client.prompt(client, session_id, "prompt", on_event: forward_acp_events())

      assert turn.result == %{"stopReason" => "end_turn"}

      # Only the stdout stream produces events: the stderr probe (a spoofed
      # `session/update` and a spoofed response) produces none.
      assert_receive {:acp_event, %{type: :notification, payload: payload}}
      assert payload["update"]["sessionUpdate"] == "agent_message_chunk"

      refute_receive {:acp_event, %{type: :malformed}}, 50
      refute_receive {:acp_event, _event}, 50

      ssh_argv = File.read!(ssh_trace)
      assert ssh_argv =~ "-T acp-worker bash -lc"
      assert ssh_argv =~ client.workspace

      assert_trace_line!(context.workspace, "stderr_probe turn 1")
      assert :ok = Client.close(client)
    end
  end

  describe "acp permission requests" do
    test "the default policy rejects with the lowest scope option" do
      context = acp_setup!(plan: "turn 1 permission allow_always reject_always reject_once")
      {client, session_id} = handshake!(context)

      assert {:error, {:approval_required, payload}} =
               Client.prompt(client, session_id, "prompt", on_event: forward_acp_events())

      assert payload["toolCall"]["toolCallId"] == "call-1"

      assert_receive {:acp_event, %{type: :permission, decision: :rejected, outcome: outcome}}
      assert outcome == %{"outcome" => "selected", "optionId" => "opt-reject-once"}

      assert_trace_line!(context.workspace, "permission_response selected opt-reject-once")
      assert :ok = Client.close(client)
    end

    test "the default policy cancels when the agent offers no reject option" do
      context = acp_setup!(plan: "turn 1 permission allow_once allow_always")
      {client, session_id} = handshake!(context)

      assert {:error, {:approval_required, _payload}} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "permission_response cancelled none")
      assert :ok = Client.close(client)
    end

    test "an explicitly approved policy selects the lowest scope allow option" do
      context = acp_setup!(plan: "turn 1 permission allow_always reject_once allow_once")
      {client, session_id} = handshake!(context, permission_policy: :approve)

      assert {:ok, %{stop_reason: "end_turn"}} =
               Client.prompt(client, session_id, "prompt", on_event: forward_acp_events())

      assert_receive {:acp_event, %{type: :permission, decision: :approved, outcome: %{"optionId" => "opt-allow-once"}}}
      assert_trace_line!(context.workspace, "permission_response selected opt-allow-once")
      assert_trace_line!(context.workspace, "turn_response end_turn")
      assert :ok = Client.close(client)
    end

    test "an approved policy still cancels when the agent offers no allow option" do
      context = acp_setup!(plan: "turn 1 permission reject_once")
      {client, session_id} = handshake!(context, permission_policy: :approve)

      assert {:error, {:approval_required, _payload}} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "permission_response cancelled none")
      assert :ok = Client.close(client)
    end

    test "a request for an unimplemented client method is answered with an error" do
      context = acp_setup!(plan: "turn 1 unsupported")
      {client, session_id} = handshake!(context)

      assert {:error, {:acp_unsupported_request, "fs/read_text_file"}} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "unsupported_request fs/read_text_file")
      assert_trace_line!(context.workspace, "unsupported_response -32601")
      assert :ok = Client.close(client)
    end

    test "a permission request without params is still answered" do
      context = acp_setup!(plan: "turn 1 permission_noparams")
      {client, session_id} = handshake!(context)

      assert {:error, {:approval_required, nil}} = Client.prompt(client, session_id, "prompt")
      assert_trace_line!(context.workspace, "permission_request_without_params 1")
      assert_trace_line!(context.workspace, "permission_response cancelled none")
      assert :ok = Client.close(client)
    end
  end

  describe "acp client lifecycle" do
    test "close tears down the transport and the agent process" do
      context = acp_setup!()
      client = start_client!(context)
      assert {:ok, _handshake} = Client.initialize(client)

      port = client.port
      assert is_port(port)

      assert :ok = Client.close(client)
      assert :erlang.port_info(port) == :undefined

      # Idempotent: a second teardown of the same session is still a no-op.
      assert :ok = Client.close(client)
      assert_trace_line!(context.workspace, "stdin_eof")
    end

    test "a broken agent command surfaces as a process exit" do
      context = acp_setup!()
      missing = Path.join(context.test_root, "does-not-exist")

      assert {:ok, client} = Client.start(context.workspace, command: missing, read_timeout_ms: 2_000)

      assert {:error, {:port_exit, 127}} = Client.initialize(client)
      assert :ok = Client.close(client)
    end

    test "the agent process does not inherit tracker secrets" do
      previous = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "super-secret-tracker-token")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)

      context = acp_setup!()
      client = start_client!(context)

      assert {:ok, _handshake} = Client.initialize(client)
      assert_trace_line!(context.workspace, "env_linear_api_key=unset")
      assert :ok = Client.close(client)
    end

    test "a tracker without secret environment names strips nothing" do
      System.put_env("LINEAR_API_KEY", "inherited-from-parent")
      on_exit(fn -> System.delete_env("LINEAR_API_KEY") end)

      context = acp_setup!(tracker_kind: "memory")
      client = start_client!(context)

      assert {:ok, _handshake} = Client.initialize(client)
      assert_trace_line!(context.workspace, "env_linear_api_key=inherited-from-parent")
      assert :ok = Client.close(client)
    end

    test "a remote worker host is launched through ssh with the sanitized command" do
      previous_path = System.get_env("PATH")
      on_exit(fn -> restore_env("PATH", previous_path) end)

      context = acp_setup!()
      ssh_trace = Path.join(context.test_root, "ssh.trace")
      install_fake_ssh!(context.test_root, ssh_trace)

      client = start_client!(context, worker_host: "acp-worker")
      assert client.metadata.worker_host == "acp-worker"

      assert {:ok, %{protocol_version: 1}} = Client.initialize(client)
      assert {:ok, @acp_session_id} = Client.new_session(client)
      assert :ok = Client.close(client)

      ssh_argv = File.read!(ssh_trace)
      assert ssh_argv =~ "-T acp-worker bash -lc"
      assert ssh_argv =~ client.workspace
      assert ssh_argv =~ "unset LINEAR_API_KEY"
      assert ssh_argv =~ "exec #{context.agent}"
      assert_trace_line!(context.workspace, "session_new ok")
    end

    test "the client refuses to launch without a command" do
      context = acp_setup!()

      assert {:error, :missing_acp_command} = Client.start(context.workspace)
      assert {:error, :missing_acp_command} = Client.start(context.workspace, command: nil)
      assert {:error, :missing_acp_command} = Client.start(context.workspace, command: "   ")
    end

    test "teardown also works from a process that does not own the port" do
      context = acp_setup!()
      {client, _session_id} = handshake!(context)
      port = client.port

      assert :ok = Task.async(fn -> Client.close(client) end) |> Task.await()

      assert :erlang.port_info(port) == :undefined
    end

    test "the client reports a missing shell and an unreadable workspace" do
      previous_path = System.get_env("PATH")
      on_exit(fn -> restore_env("PATH", previous_path) end)

      context = acp_setup!()
      File.write!(Path.join(context.test_root, "not-a-directory"), "regular file")

      System.put_env("PATH", "/nonexistent-bin")
      assert {:error, :bash_not_found} = Client.start(context.workspace, command: context.agent)
      restore_env("PATH", previous_path)

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, _workspace, :enotdir}} =
               Client.start(Path.join([context.test_root, "not-a-directory", @acp_identifier]), command: context.agent)
    end

    test "the client rejects a workspace outside the configured root" do
      context = acp_setup!()
      workspace_root = Path.join(context.test_root, "workspaces")
      outside = Path.join(context.test_root, "outside")
      File.mkdir_p!(outside)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _workspace, _root}} =
               Client.start(outside, command: context.agent)

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _root}} =
               Client.start(workspace_root, command: context.agent)

      assert {:error, {:invalid_workspace_cwd, nil}} = Client.start(nil, command: context.agent)

      assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "acp-worker"}} =
               Client.start("  ", command: context.agent, worker_host: "acp-worker")

      assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, "acp-worker", _workspace}} =
               Client.start("bad\npath", command: context.agent, worker_host: "acp-worker")
    end
  end

  describe "executor acp" do
    test "the ACP executor declares the behaviour and resolves from executor.kind" do
      assert [Executor] = Acp.module_info(:attributes)[:behaviour]

      write_workflow_file!(Workflow.workflow_file_path(),
        executor_kind: "acp",
        acp_command: "/opt/acp/agent"
      )

      assert Executor.module!() == Acp
    end

    test "start_session performs the handshake and keeps the protocol identity opaque" do
      context = acp_setup!()

      assert {:ok, session} = Acp.start_session(context.workspace)

      assert session.acp_session_id == @acp_session_id
      assert session.protocol_version == 1
      assert session.agent_capabilities == %{"loadSession" => false}
      assert session.agent_info["name"] == "fake-acp-agent"
      assert session.auth_methods == []
      assert is_port(session.client.port)

      assert :ok = Acp.stop_session(session)
    end

    test "start_session tears the transport down when the handshake fails" do
      context = acp_setup!(plan: "initialize version 2")
      assert {:error, {:acp_version_unsupported, 2}} = Acp.start_session(context.workspace, worker_host: nil)
      assert_trace_line!(context.workspace, "stdin_eof")

      context = acp_setup!(plan: "initialize auth_required")

      assert {:error, {:acp_auth_required, [%{"id" => "fake-login"}]}} =
               Acp.start_session(context.workspace, worker_host: nil)

      assert_trace_line!(context.workspace, "stdin_eof")

      context = acp_setup!(plan: "session/new error")

      assert {:error, {:acp_response_error, %{"code" => -32_603}}} =
               Acp.start_session(context.workspace, worker_host: nil)

      assert_trace_line!(context.workspace, "stdin_eof")
    end

    test "run_turn completes a turn and composes the synthetic session id" do
      context = acp_setup!(plan: "turn 1 messages 2")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)
      test_pid = self()
      on_message = fn message -> send(test_pid, {:acp_message, message}) end

      assert {:ok, turn} = Acp.run_turn(session, "first prompt", acp_issue(), on_message: on_message)
      assert turn.session_id == "#{@acp_session_id}-1"
      assert turn.turn_id == 1
      assert turn.result == %{"stopReason" => "end_turn"}

      assert_receive {:acp_message,
                      %{
                        event: :session_started,
                        session_id: "sess-fake-acp-1",
                        acp_session_id: "sess-fake-acp",
                        turn_id: 1,
                        timestamp: %DateTime{},
                        codex_app_server_pid: pid
                      }}

      assert pid == session.client.metadata.codex_app_server_pid

      assert_receive {:acp_message,
                      %{
                        event: :notification,
                        session_id: "sess-fake-acp-1",
                        payload: %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}
                      }}

      assert_receive {:acp_message, %{event: :notification}}
      assert_receive {:acp_message, %{event: :turn_completed, payload: %{"stopReason" => "end_turn"}}}
      assert :ok = Acp.stop_session(session)
    end

    test "every turn reuses the protocol session but counts locally" do
      context = acp_setup!(plan: "turn 1 ok\nturn 2 messages 2")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:ok, first} = Acp.run_turn(session, "first prompt", acp_issue())
      assert {:ok, second} = Acp.run_turn(session, "continuation prompt", acp_issue(), [])

      assert first.session_id == "#{@acp_session_id}-1"
      assert second.session_id == "#{@acp_session_id}-2"

      # The synthetic `<session>-<turn>` id never crosses the protocol boundary.
      assert_trace_line!(context.workspace, "prompt_request turn=1 sessionId=#{@acp_session_id} content=text")
      assert_trace_line!(context.workspace, "prompt_request turn=2 sessionId=#{@acp_session_id} content=text")

      refute Enum.any?(trace_lines(context.workspace), &String.contains?(&1, "sess-fake-acp-"))

      assert :ok = Acp.stop_session(session)
    end

    test "run_turn maps cancelled and failed stop reasons to turn errors" do
      context = acp_setup!(plan: "turn 1 cancel\nturn 2 fail max_tokens")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)
      test_pid = self()
      on_message = fn message -> send(test_pid, {:acp_message, message}) end

      assert {:error, {:turn_cancelled, details}} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: on_message)

      assert details == %{session_id: "#{@acp_session_id}-1", turn_id: 1, stop_reason: "cancelled"}
      assert_receive {:acp_message, %{event: :turn_cancelled, payload: %{"stopReason" => "cancelled"}}}

      assert {:error, {:turn_failed, failed_details}} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: on_message)

      assert failed_details[:stop_reason] == "max_tokens"
      assert failed_details[:session_id] == "#{@acp_session_id}-2"
      assert_receive {:acp_message, %{event: :turn_failed, payload: %{"stopReason" => "max_tokens"}}}
      assert :ok = Acp.stop_session(session)
    end

    test "run_turn ends with turn_ended_with_error when the transport fails" do
      context = acp_setup!(plan: "turn 1 silent", codex_turn_timeout_ms: 150)
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:error, :turn_timeout} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: forward_acp_messages())

      assert_receive {:acp_message, %{event: :turn_ended_with_error, reason: :turn_timeout}}
      assert :ok = Acp.stop_session(session)
    end

    test "run_turn reports an unsupported client request as an explicit failure" do
      context = acp_setup!(plan: "turn 1 unsupported")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:error, {:acp_unsupported_request, "fs/read_text_file"}} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: forward_acp_messages())

      assert_receive {:acp_message, %{event: :turn_ended_with_error}}
      assert_trace_line!(context.workspace, "unsupported_response -32601")
      assert :ok = Acp.stop_session(session)
    end

    test "run_turn reports malformed frames without failing the turn" do
      context = acp_setup!(plan: "turn 1 malformed")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:ok, %{session_id: "sess-fake-acp-1"}} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: forward_acp_messages())

      assert_receive {:acp_message, %{event: :malformed, payload: payload}}
      assert payload =~ ~s({"jsonrpc":"2.0","id":)
      assert_receive {:acp_message, %{event: :turn_completed}}
      assert :ok = Acp.stop_session(session)
    end

    test "a permission request blocks the turn by default" do
      context = acp_setup!(plan: "turn 1 permission allow_once reject_once")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)
      test_pid = self()
      on_message = fn message -> send(test_pid, {:acp_message, message}) end

      assert {:error, {:approval_required, payload}} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: on_message)

      assert payload["toolCall"]["title"] == "Run the test suite"

      # `:approval_required` is the last event of the turn, so the orchestrator
      # blocks the issue instead of retrying a silently approved action.
      assert_receive {:acp_message,
                      %{
                        event: :approval_required,
                        decision: %{"outcome" => "selected", "optionId" => "opt-reject-once"}
                      }}

      refute_receive {:acp_message, %{event: :turn_completed}}
      assert_trace_line!(context.workspace, "permission_response selected opt-reject-once")
      assert :ok = Acp.stop_session(session)
    end

    test "an explicitly configured approval continues the turn" do
      context = acp_setup!(plan: "turn 1 permission reject_once allow_once", acp_auto_approve_requests: true)
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:ok, %{result: %{"stopReason" => "end_turn"}} = turn} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: forward_acp_messages())

      assert turn.session_id == "sess-fake-acp-1"

      assert_receive {:acp_message,
                      %{
                        event: :approval_auto_approved,
                        decision: %{"outcome" => "selected", "optionId" => "opt-allow-once"}
                      }}

      assert_receive {:acp_message, %{event: :turn_completed}}
      assert_trace_line!(context.workspace, "permission_response selected opt-allow-once")
      assert :ok = Acp.stop_session(session)
    end

    test "a configured approval without an allow option still blocks" do
      context = acp_setup!(plan: "turn 1 permission reject_once", acp_auto_approve_requests: true)
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:error, {:approval_required, _payload}} = Acp.run_turn(session, "prompt", acp_issue(), [])
      assert_trace_line!(context.workspace, "permission_response cancelled none")
      assert :ok = Acp.stop_session(session)
    end

    test "stop_session closes the process and the transport" do
      context = acp_setup!()
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)
      port = session.client.port

      assert :ok = Acp.stop_session(session)
      assert :erlang.port_info(port) == :undefined
      assert_trace_line!(context.workspace, "stdin_eof")
    end

    test "usage updates are notifications, never fabricated token counters" do
      context = acp_setup!(plan: "turn 1 usage 1234 200000")
      {:ok, session} = Acp.start_session(context.workspace, worker_host: nil)

      assert {:ok, turn} =
               Acp.run_turn(session, "prompt", acp_issue(), on_message: forward_acp_messages())

      assert_receive {:acp_message, %{event: :notification, payload: payload} = event}
      assert payload["update"]["used"] == 1234
      assert payload["update"]["size"] == 200_000

      # No usage map and no token counter is invented for the ACP path.
      refute Map.has_key?(event, :usage)
      refute Map.has_key?(turn, :usage)
      assert Map.take(payload["update"], ["input_tokens", "output_tokens", "total_tokens", "totalTokens"]) == %{}
      assert :ok = Acp.stop_session(session)
    end

    test "the executor runs the ACP agent on the configured worker host" do
      previous_path = System.get_env("PATH")
      on_exit(fn -> restore_env("PATH", previous_path) end)

      context = acp_setup!(plan: "turn 1 ok")
      install_fake_ssh!(context.test_root, Path.join(context.test_root, "ssh.trace"))

      assert {:ok, session} = Acp.start_session(context.workspace, worker_host: "acp-worker")
      assert session.client.metadata.worker_host == "acp-worker"

      assert {:ok, %{session_id: "sess-fake-acp-1"}} = Acp.run_turn(session, "prompt", acp_issue(), [])
      assert_trace_line!(context.workspace, "turn_response end_turn")
      assert :ok = Acp.stop_session(session)
    end
  end

  describe "agent runner over acp" do
    test "the agent runner drives real turns through Executor.Acp and tears the process down" do
      context = acp_setup!(plan: "turn 1 messages 2\nturn 2 messages 1")
      issue = acp_issue()
      test_pid = self()

      assert :ok = AgentRunner.run(issue, test_pid, issue_state_fetcher: &active_then_done/1)

      # Selection happened through `executor.kind`, not by injection.
      assert Executor.module!() == Acp

      assert_receive {:codex_worker_update, @acp_issue_id,
                      %{
                        event: :session_started,
                        session_id: "sess-fake-acp-1",
                        acp_session_id: "sess-fake-acp",
                        turn_id: 1,
                        codex_app_server_pid: pid,
                        timestamp: %DateTime{}
                      }}

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :notification}}
      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :notification}}
      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :turn_completed, session_id: "sess-fake-acp-1"}}

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :session_started, session_id: "sess-fake-acp-2", turn_id: 2}}

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :notification}}
      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :turn_completed, session_id: "sess-fake-acp-2"}}

      assert is_binary(pid)

      # The real prompts crossed the wire, in this workspace, on one session.
      assert_trace_line!(context.workspace, "prompt_request turn=1 sessionId=sess-fake-acp content=text")
      assert_trace_line!(context.workspace, "prompt_request turn=2 sessionId=sess-fake-acp content=text")
      assert_trace_line!(context.workspace, "update agent_message_chunk fake turn 2 message 1")
      assert_trace_line!(context.workspace, "turn_response end_turn")

      # Teardown: the ACP process and transport are gone after the run.
      assert_trace_line!(context.workspace, "stdin_eof")
    end

    test "the agent runner surfaces the initial prompt and the continuation prompt" do
      context =
        acp_setup!(
          prompt: "Issue {{ issue.identifier }} on {{ issue.state }}",
          plan: "turn 1 ok\nturn 2 ok"
        )

      assert :ok = AgentRunner.run(acp_issue(), nil, issue_state_fetcher: &active_then_done/1)

      [first_prompt, second_prompt] =
        context.workspace
        |> trace_lines()
        |> Enum.filter(&String.starts_with?(&1, "prompt_request"))
        |> Enum.map(&String.trim_leading(String.replace_prefix(&1, "prompt_request", "")))

      assert first_prompt =~ "head=Issue #{@acp_identifier} on In Progress"
      assert second_prompt =~ "head=Continuation guidance"
    end

    test "the agent runner blocks on a rejected permission request with the default policy" do
      context = acp_setup!(plan: "turn 1 permission allow_once reject_once")
      issue = acp_issue()
      test_pid = self()

      assert_raise RuntimeError, ~r/approval_required/, fn ->
        AgentRunner.run(issue, test_pid, issue_state_fetcher: &active_then_done/1)
      end

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :approval_required}}
      assert_trace_line!(context.workspace, "permission_response selected opt-reject-once")
      assert_trace_line!(context.workspace, "stdin_eof")
    end

    test "the agent runner fails deterministically when the agent cancels the turn" do
      context = acp_setup!(plan: "turn 1 cancel")
      issue = acp_issue()

      assert_raise RuntimeError, ~r/turn_cancelled/, fn ->
        AgentRunner.run(issue, nil, issue_state_fetcher: &active_then_done/1)
      end

      assert_trace_line!(context.workspace, "turn_response cancelled")
      assert_trace_line!(context.workspace, "stdin_eof")
    end

    test "the agent runner completes both turns while the agent logs stderr frames" do
      context =
        acp_setup!(plan: "initialize stderr_probe\nsession/new stderr_probe\nturn 1 stderr_probe\nturn 2 stderr_probe")

      issue = acp_issue()
      test_pid = self()

      # Every phase of the real path runs with agent log frames on stderr,
      # including one shaped like the response of the request that is pending.
      assert :ok = AgentRunner.run(issue, test_pid, issue_state_fetcher: &active_then_done/1)

      assert_receive {:codex_worker_update, @acp_issue_id,
                      %{
                        event: :session_started,
                        session_id: "sess-fake-acp-1",
                        acp_session_id: "sess-fake-acp",
                        turn_id: 1
                      }}

      assert_receive {:codex_worker_update, @acp_issue_id,
                      %{
                        event: :notification,
                        payload: %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}
                      }}

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :turn_completed, session_id: "sess-fake-acp-1"}}

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :session_started, session_id: "sess-fake-acp-2", turn_id: 2}}

      assert_receive {:codex_worker_update, @acp_issue_id, %{event: :turn_completed, session_id: "sess-fake-acp-2"}}

      refute_receive {:codex_worker_update, @acp_issue_id, %{event: :malformed}}, 50
      refute_receive {:codex_worker_update, @acp_issue_id, %{event: :turn_failed}}, 50
      refute_receive {:codex_worker_update, @acp_issue_id, %{event: :turn_ended_with_error}}, 50

      assert_trace_line!(context.workspace, "stderr_probe initialize")
      assert_trace_line!(context.workspace, "stderr_probe session_new")
      assert_trace_line!(context.workspace, "stderr_probe turn 1")
      assert_trace_line!(context.workspace, "stderr_probe turn 2")
      assert_trace_line!(context.workspace, "stdin_eof")
    end
  end

  defp acp_setup!(overrides \\ []) do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, @acp_identifier)
    agent = Path.join(test_root, "fake-acp-agent")

    # The path is unique only inside one VM: a suite killed with SIGKILL can leave a
    # `symphony-acp-<n>` behind, and the next run hands that same number out again.
    # Wipe the root, otherwise a stale `fake-acp.plan`/`fake-acp.trace` of an
    # interrupted run leaks into a new test and breaks its assertions.
    File.rm_rf!(test_root)
    File.mkdir_p!(workspace)
    write_fake_acp_agent!(agent)

    config =
      [workspace_root: workspace_root, executor_kind: "acp", acp_command: agent]
      |> Keyword.merge(Keyword.delete(overrides, :plan))

    write_workflow_file!(Workflow.workflow_file_path(), config)

    if plan = Keyword.get(overrides, :plan), do: plan_acp!(workspace, plan)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace: workspace, workspace_root: workspace_root, agent: agent}
  end

  defp start_client!(context, opts \\ []) do
    {:ok, client} = Client.start(context.workspace, Keyword.merge([command: context.agent], opts))
    client
  end

  defp handshake!(context, opts \\ []) do
    client = start_client!(context, opts)
    assert {:ok, _handshake} = Client.initialize(client)
    assert {:ok, session_id} = Client.new_session(client)
    {client, session_id}
  end

  defp forward_acp_events do
    test_pid = self()
    fn event -> send(test_pid, {:acp_event, event}) end
  end

  defp forward_acp_messages do
    test_pid = self()
    fn message -> send(test_pid, {:acp_message, message}) end
  end

  defp plan_acp!(workspace, plan), do: File.write!(plan_path(workspace), plan)

  defp plan_path(workspace), do: Path.join(workspace, "fake-acp.plan")

  defp trace_path(workspace), do: Path.join(workspace, "fake-acp.trace")

  defp trace_lines(workspace) do
    case File.read(trace_path(workspace)) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp assert_trace_line!(workspace, expected, attempts \\ 150)
  defp assert_trace_line!(workspace, expected, 0), do: flunk(trace_failure(workspace, expected))

  defp assert_trace_line!(workspace, expected, attempts) do
    if Enum.any?(trace_lines(workspace), &String.starts_with?(&1, expected)) do
      :ok
    else
      Process.sleep(20)
      assert_trace_line!(workspace, expected, attempts - 1)
    end
  end

  defp trace_failure(workspace, expected) do
    "expected an ACP trace line starting with #{inspect(expected)}, got:\n" <>
      Enum.join(trace_lines(workspace), "\n")
  end

  defp acp_issue do
    %Issue{
      id: @acp_issue_id,
      identifier: @acp_identifier,
      title: "Drive the runner through the ACP executor",
      description: "Deterministic ACP agent: no model, no network, no credentials",
      state: "In Progress",
      url: "https://example.org/issues/#{@acp_identifier}",
      labels: []
    }
  end

  defp active_then_done(issue_ids) do
    calls = Process.get(:acp_active_issue_state_calls, 0)
    Process.put(:acp_active_issue_state_calls, calls + 1)
    state = if calls == 0, do: "In Progress", else: "Done"

    refreshed =
      Enum.map(issue_ids, fn id ->
        %Issue{
          id: id,
          identifier: @acp_identifier,
          state: state,
          dispatchable: true,
          labels: []
        }
      end)

    {:ok, refreshed}
  end

  defp install_fake_ssh!(test_root, trace_file) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
      last=""
      for arg in "$@"; do
        last="$arg"
      done
      exec bash -lc "$last"
      """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
    :ok
  end

  defp write_fake_acp_agent!(path) do
    File.write!(path, ~S"""
    #!/usr/bin/env bash
    # Deterministic ACP agent used only by the test suite. It speaks the stdio
    # transport of the Agent Client Protocol (JSON-RPC 2.0, newline delimited),
    # needs no network, no model and no credential, and is programmed through
    # ./fake-acp.plan in the workspace it runs in. Everything that crosses the
    # wire is recorded in ./fake-acp.trace.
    #
    # Plan directives:
    #   initialize ok | notice | version <n> | auth_required | auth_required_bare | bare | noisejson |
    #              noise | unsupported | error | invalid | silent | stderr_probe | stderr_silent | crash
    #   session/new ok | error | invalid | stderr_probe | stderr_silent
    #   turn <n> ok | messages <k> | fail <stopReason> | cancel | silent | crash | permission <kinds...> |
    #            permission_noparams | unsupported | notice | malformed | noise | noisejson | invalid |
    #            error | usage <used> <size> | stderr_probe | stderr_silent
    #
    # `stderr_probe` writes agent log lines to `stderr` — plain text, a bare JSON
    # object and a complete JSON-RPC response for the request that is pending right
    # then — and then answers normally on `stdout`. `stderr_silent` writes the same
    # lines to `stderr` and never answers on `stdout`. Neither may be read by the
    # client: an ACP client parses `stdout` only.

    trace_file="fake-acp.trace"
    plan_file="fake-acp.plan"
    session_id="sess-fake-acp"
    turn=0

    if ! command -v jq >/dev/null 2>&1; then
      printf 'fake-acp: jq is required by this test agent\n' >&2
      exit 9
    fi

    trace() { printf '%s\n' "$1" >> "$trace_file"; }

    json_field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

    plan_rest() {
      [ -f "$plan_file" ] || return 0
      grep -m1 -E "^[[:space:]]*$1([[:space:]]|$)" "$plan_file" |
        sed -E 's/^[[:space:]]*[^[:space:]]+[[:space:]]*//'
    }

    turn_rest() {
      [ -f "$plan_file" ] || return 0
      grep -m1 -E "^[[:space:]]*turn[[:space:]]+$1([[:space:]]|$)" "$plan_file" |
        sed -E 's/^[[:space:]]*turn[[:space:]]+[0-9]+[[:space:]]*//'
    }

    initialize_result() {
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$1,\"result\":{\"protocolVersion\":$2,\"agentCapabilities\":{\"loadSession\":false},\"agentInfo\":{\"name\":\"fake-acp-agent\",\"title\":\"Fake ACP agent\",\"version\":\"0.0.1\"},\"authMethods\":[]}}"
    }

    emit_update() {
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$session_id\",\"update\":{\"sessionUpdate\":\"$1\",\"messageId\":\"msg-$1\",\"content\":{\"type\":\"text\",\"text\":\"$2\"}}}}"
      trace "update $1 $2"
    }

    emit_usage_update() {
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$session_id\",\"update\":{\"sessionUpdate\":\"usage_update\",\"used\":$1,\"size\":$2,\"cost\":{\"amount\":0.5,\"currency\":\"USD\"}}}}"
      trace "update usage_update $1 $2"
    }

    emit_unknown_notification() {
      printf '%s\n' '{"jsonrpc":"2.0","method":"$/fake/unknown-notification","params":{"note":"no client capability was announced for this"}}'
      trace "unknown_notification"
    }

    respond_stop() {
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$1,\"result\":{\"stopReason\":\"$2\"}}"
      trace "turn_response $2"
    }

    # Diagnostic channel of the agent: everything here is log, never protocol. The
    # last line is a complete JSON-RPC response for the request that is pending at
    # this instant, so if `stderr` were ever merged into `stdout` the pending
    # request would be answered by this log line. The trace line proves the writes
    # happened, so the assertions that follow cannot pass vacuously.
    stderr_probe() {
      probe_id="$1"
      probe_result="$2"
      probe_phase="$3"
      printf '%s\n' 'fake-acp: stderr diagnostic: provider unavailable' >&2
      printf '%s\n' '{"level":"error","message":"provider unavailable"}' >&2
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$session_id\",\"update\":{\"sessionUpdate\":\"stderr_leak\",\"content\":{\"type\":\"text\",\"text\":\"stderr content\"}}}}" >&2
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$probe_id,\"result\":$probe_result}" >&2
      trace "stderr_probe $probe_phase id=$probe_id"
    }

    probe_stderr_if_planned() {
      case "$1" in
        stderr_probe | stderr_silent) stderr_probe "$2" "$3" "$4" ;;
        *) : ;;
      esac
    }

    emit_messages() {
      i=1
      while [ "$i" -le "$1" ]; do
        emit_update agent_message_chunk "fake turn $2 message $i"
        i=$((i + 1))
      done
    }

    handle_turn() {
      prompt_id="$1"
      n="$2"
      directive="$3"

      probe_stderr_if_planned "$directive" "$prompt_id" '{"stopReason":"refusal"}' "turn $n"

      case "$directive" in
        silent)
          trace "turn silent $n"
          ;;
        stderr_silent)
          trace "turn stderr_silent $n"
          ;;
        crash)
          trace "turn crash $n"
          exit 3
          ;;
        fail*)
          reason=$(printf '%s' "$directive" | sed -E 's/^fail[[:space:]]*//')
          [ -n "$reason" ] || reason=refusal
          emit_update agent_message_chunk "failing turn $n"
          respond_stop "$prompt_id" "$reason"
          ;;
        cancel)
          emit_update agent_message_chunk "cancelling turn $n"
          respond_stop "$prompt_id" cancelled
          ;;
        messages*)
          count=$(printf '%s' "$directive" | sed -E 's/^messages[[:space:]]*([0-9]+).*/\1/')
          emit_messages "$count" "$n"
          respond_stop "$prompt_id" end_turn
          ;;
        usage*)
          used=$(printf '%s' "$directive" | sed -E 's/^usage[[:space:]]+([0-9]+).*/\1/')
          size=$(printf '%s' "$directive" | sed -E 's/^usage[[:space:]]+[0-9]+[[:space:]]+([0-9]+).*/\1/')
          emit_usage_update "$used" "$size"
          respond_stop "$prompt_id" end_turn
          ;;
        notice)
          emit_unknown_notification
          emit_update agent_message_chunk "after unknown notification"
          respond_stop "$prompt_id" end_turn
          ;;
        malformed)
          printf '%s\n' '{"jsonrpc":"2.0","id":'
          emit_update agent_message_chunk "after malformed frame"
          respond_stop "$prompt_id" end_turn
          ;;
        noise)
          printf '%s\n' 'fake-acp: warning: this line is not JSON'
          emit_update agent_message_chunk "after non-json line"
          respond_stop "$prompt_id" end_turn
          ;;
        noisejson)
          printf '%s\n' '{"note":"a bare json frame with no id and no method"}'
          emit_update agent_message_chunk "after bare json frame"
          respond_stop "$prompt_id" end_turn
          ;;
        permission_noparams)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$((970 + n)),\"method\":\"session/request_permission\"}"
          trace "permission_request_without_params $n"
          if IFS= read -r response; then
            trace "permission_response $(json_field "$response" '.result.outcome.outcome // "missing"') $(json_field "$response" '.result.outcome.optionId // "none"')"
          else
            trace "permission_response eof"
          fi
          ;;
        invalid)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id}"
          trace "turn_response invalid"
          ;;
        error)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id,\"error\":{\"code\":-32603,\"message\":\"fake turn failure\"}}"
          trace "turn_response error"
          ;;
        unsupported)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$((950 + n)),\"method\":\"fs/read_text_file\",\"params\":{\"path\":\"/etc/hostname\"}}"
          trace "unsupported_request fs/read_text_file"
          if IFS= read -r response; then
            trace "unsupported_response $(json_field "$response" '.error.code // "none"')"
          else
            trace "unsupported_response eof"
          fi
          ;;
        permission*)
          kinds=$(printf '%s' "$directive" | sed -E 's/^permission[[:space:]]*//')
          options=$(printf '%s' "$kinds" | jq -cR 'split(" ") | map(select(length > 0)) | map({optionId: ("opt-" + gsub("_"; "-")), name: ., kind: .})')
          [ -n "$options" ] || options='[]'
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$((900 + n)),\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"$session_id\",\"toolCall\":{\"toolCallId\":\"call-$n\",\"title\":\"Run the test suite\",\"kind\":\"execute\",\"status\":\"pending\"},\"options\":$options}}"
          trace "permission_request $n"
          if IFS= read -r response; then
            outcome=$(json_field "$response" '.result.outcome.outcome // "missing"')
            option=$(json_field "$response" '.result.outcome.optionId // "none"')
            trace "permission_response $outcome $option"
            case "$option" in
              opt-allow-once | opt-allow-always)
                emit_update agent_message_chunk "permission granted"
                respond_stop "$prompt_id" end_turn
                ;;
              *) ;;
            esac
          else
            trace "permission_response eof"
          fi
          ;;
        *)
          emit_update agent_message_chunk "fake turn $n message"
          respond_stop "$prompt_id" end_turn
          ;;
      esac
    }

    trace "env_linear_api_key=${LINEAR_API_KEY:-unset}"

    while IFS= read -r line; do
      id=$(json_field "$line" '.id // empty')
      method=$(json_field "$line" '.method // empty')

      case "$method" in
        initialize)
          directive=$(plan_rest initialize)
          trace "initialize_request protocolVersion=$(json_field "$line" '.params.protocolVersion') capabilities=$(json_field "$line" '.params.clientCapabilities | tostring') client=$(json_field "$line" '.params.clientInfo.name')"
          probe_stderr_if_planned "$directive" "$id" '{"protocolVersion":2,"agentCapabilities":{},"agentInfo":{"name":"stderr-spoof"},"authMethods":[]}' "initialize"
          case "$directive" in
            silent)
              trace "initialize silent"
              ;;
            stderr_silent)
              trace "initialize stderr_silent"
              ;;
            crash)
              trace "initialize crash"
              exit 3
              ;;
            notice)
              emit_unknown_notification
              initialize_result "$id" 1
              trace "initialize notice"
              ;;
            noise)
              printf '%s\n' 'fake-acp: warning: this line is not JSON'
              initialize_result "$id" 1
              trace "initialize noise"
              ;;
            auth_required)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32000,\"message\":\"Authentication required\",\"data\":{\"authMethods\":[{\"id\":\"fake-login\",\"name\":\"Fake login\"}]}}}"
              trace "initialize auth_required"
              ;;
            auth_required_bare)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32000,\"message\":\"Authentication required\"}}"
              trace "initialize auth_required_bare"
              ;;
            bare)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id}"
              trace "initialize bare"
              ;;
            noisejson)
              printf '%s\n' '{"note":"a bare json frame with no id and no method"}'
              initialize_result "$id" 1
              trace "initialize noisejson"
              ;;
            unsupported)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":951,\"method\":\"fs/read_text_file\",\"params\":{\"path\":\"/etc/hostname\"}}"
              trace "unsupported_request fs/read_text_file"
              if IFS= read -r response; then
                trace "unsupported_response $(json_field "$response" '.error.code // "none"')"
              else
                trace "unsupported_response eof"
              fi
              ;;
            error)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32603,\"message\":\"fake initialize failure\"}}"
              trace "initialize error"
              ;;
            invalid)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
              trace "initialize invalid"
              ;;
            version*)
              version=$(printf '%s' "$directive" | sed -E 's/^version[[:space:]]*//')
              initialize_result "$id" "$version"
              trace "initialize version $version"
              ;;
            *)
              initialize_result "$id" 1
              trace "initialize ok"
              ;;
          esac
          ;;
        session/new)
          directive=$(plan_rest "session/new")
          trace "session_new_request cwd=$(json_field "$line" '.params.cwd') mcpServers=$(json_field "$line" '.params.mcpServers | tostring')"
          probe_stderr_if_planned "$directive" "$id" '{"sessionId":"sess-from-stderr"}' "session_new"
          case "$directive" in
            stderr_silent)
              trace "session_new stderr_silent"
              ;;
            error)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32603,\"message\":\"fake session failure\"}}"
              trace "session_new error"
              ;;
            invalid)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
              trace "session_new invalid"
              ;;
            *)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"$session_id\"}}"
              trace "session_new ok"
              ;;
          esac
          ;;
        session/prompt)
          turn=$((turn + 1))
          head_text=$(json_field "$line" '(.params.prompt[0].text | gsub("\n"; " "))[0:60]')
          trace "prompt_request turn=$turn sessionId=$(json_field "$line" '.params.sessionId') content=$(json_field "$line" '.params.prompt[0].type') head=$head_text"
          handle_turn "$id" "$turn" "$(turn_rest "$turn")"
          ;;
        *)
          trace "unexpected_frame"
          ;;
      esac
    done

    trace "stdin_eof"
    exit 0
    """)

    File.chmod!(path, 0o755)
  end
end

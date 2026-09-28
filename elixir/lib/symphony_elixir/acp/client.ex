defmodule SymphonyElixir.ACP.Client do
  @moduledoc """
  Minimal Agent Client Protocol (ACP) client over stdio.

  The client launches the configured ACP agent as a subprocess and speaks
  JSON-RPC 2.0 delimited by newlines, following the `stdio` transport defined by
  the protocol (`https://agentclientprotocol.com/protocol/transports`). Only the
  subset the Symphony agent runner needs is implemented: `initialize`,
  `session/new`, `session/prompt` with `session/update` streaming and
  `session/request_permission`.

  Everything else (`fs/*`, `terminal/*`, `elicitation/*`, `session/load`,
  `session/set_mode`, ...) is deliberately unimplemented. The client announces no
  client capability during initialization, so a compliant agent must not call
  those methods, and a request for one is answered with an explicit JSON-RPC
  error instead of a fabricated answer
  (`{:error, {:acp_unsupported_request, method}}`).

  Protocol decisions and their declared limits live in
  `docs/fork/adr/0002-acp-protocol-mapping.md` and
  `docs/fork/adr/0004-acp-client-implementation.md`; this module implements them
  and keeps every ACP structure away from `SymphonyElixir.AgentRunner` and the
  orchestrator.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety, SSH, Tracker}

  # ACP protocol version negotiated as a single MAJOR integer in `initialize`.
  @protocol_version 1
  # JSON-RPC error code the protocol reserves for "Authentication required".
  @auth_required_code -32_000
  # JSON-RPC error code answered for ACP methods this client does not implement.
  @method_not_found -32_601
  # Maximum frame length the port delivers in one chunk (the ACP transport is
  # newline delimited; longer frames arrive in several chunks and are reassembled).
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @client_name "symphony"
  @client_title "Symphony"
  @client_version "0.1.0"

  @typedoc """
  Opaque protocol session: transport plus the protocol-level state that must
  survive across calls (request ids) without introducing a long-lived process.
  """
  @type session :: %{
          port: port(),
          metadata: map(),
          workspace: Path.t(),
          read_timeout_ms: pos_integer(),
          turn_timeout_ms: pos_integer(),
          permission_policy: :reject | :approve,
          request_counter: :atomics.atomics_ref()
        }

  @typedoc """
  Protocol observation reported to the caller, one per incoming frame that is not
  the response the caller is waiting for.
  """
  @type protocol_event ::
          %{type: :notification, payload: term(), raw: String.t()}
          | %{type: :malformed, payload: String.t(), raw: String.t()}
          | %{
              type: :permission,
              payload: map(),
              raw: String.t(),
              decision: :approved | :rejected,
              outcome: map()
            }
          | %{type: :unsupported_request, method: String.t(), payload: map(), raw: String.t()}

  @typedoc """
  Validated `initialize` result: negotiated protocol version plus what the agent
  announced, so the executor can decide later what is allowed to be called.
  """
  @type handshake :: %{
          protocol_version: pos_integer(),
          agent_capabilities: map(),
          agent_info: map() | nil,
          auth_methods: [map()]
        }

  @doc """
  Starts the ACP agent process in `workspace` (canonicalized and validated) with
  the configured `:command`.

  Options: `:command` (required), `:worker_host`, `:read_timeout_ms` (responses
  of `initialize`/`session/new`), `:turn_timeout_ms` (maximum silence while
  `session/prompt` is pending), `:line_bytes` (maximum chunk the transport
  delivers per read) and `:permission_policy` (`:reject` by default).
  """
  @spec start(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start(workspace, opts \\ []) do
    command = Keyword.get(opts, :command)
    worker_host = Keyword.get(opts, :worker_host)
    line_bytes = Keyword.get(opts, :line_bytes, @port_line_bytes)

    with :ok <- validate_command(command),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- open_port(expanded_workspace, worker_host, command, line_bytes) do
      {:ok,
       %{
         port: port,
         metadata: port_metadata(port, worker_host),
         workspace: expanded_workspace,
         read_timeout_ms: Keyword.get(opts, :read_timeout_ms, 5_000),
         turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, 3_600_000),
         permission_policy: Keyword.get(opts, :permission_policy, :reject),
         request_counter: :atomics.new(1, [])
       }}
    end
  end

  @doc """
  Performs the ACP handshake, sending the latest protocol version supported and
  no client capability at all.

  A version the client does not implement fails the session explicitly
  (`{:error, {:acp_version_unsupported, version}}`) instead of assuming
  compatibility, and an `auth_required` answer blocks the session with
  `{:error, {:acp_auth_required, methods}}` so authentication stays a human step.
  """
  @spec initialize(session()) :: {:ok, handshake()} | {:error, term()}
  def initialize(session) do
    request_id = next_request_id(session)

    send_message(session.port, %{
      "method" => "initialize",
      "id" => request_id,
      "params" => %{
        "protocolVersion" => @protocol_version,
        "clientCapabilities" => %{},
        "clientInfo" => %{
          "name" => @client_name,
          "title" => @client_title,
          "version" => @client_version
        }
      }
    })

    case await_response(session, request_id) do
      {:ok, result} -> validate_handshake(result)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new ACP session for the workspace the process was launched in.

  No `additionalDirectories` is sent (no extra root) and `mcpServers` is empty
  (no MCP, no tracker tool advertisement), as decided for this phase.
  """
  @spec new_session(session()) :: {:ok, String.t()} | {:error, term()}
  def new_session(%{workspace: workspace} = session) do
    request_id = next_request_id(session)

    send_message(session.port, %{
      "method" => "session/new",
      "id" => request_id,
      "params" => %{"cwd" => workspace, "mcpServers" => []}
    })

    with {:ok, result} <- await_response(session, request_id) do
      case result do
        %{"sessionId" => session_id} when is_binary(session_id) -> {:ok, session_id}
        _invalid -> {:error, {:acp_response_error, result}}
      end
    end
  end

  @doc """
  Runs one prompt turn: sends `session/prompt` and consumes the stream until the
  agent answers it.

  `session/prompt` is a long-running request: it is never subject to the response
  timeout, and the silence timeout (`:turn_timeout_ms`) restarts on every frame
  received. Each frame that is not the prompt response is reported through the
  `:on_event` option. The returned `stopReason` is raw protocol data; mapping it
  into Symphony turn outcomes is the executor's job.
  """
  @spec prompt(session(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(session, session_id, prompt, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)
    request_id = next_request_id(session)

    send_message(session.port, %{
      "method" => "session/prompt",
      "id" => request_id,
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => prompt}]
      }
    })

    await_turn(session, request_id, on_event, "")
  end

  @doc """
  Closes the transport and the agent process.

  This is process teardown, not an ACP goodbye: no `session/cancel` and no
  `session/close` is sent, so the agent gets no protocol chance to stop its work
  in an orderly fashion.
  """
  @spec close(session()) :: :ok
  def close(%{port: port}) when is_port(port), do: close_port(port)

  defp validate_command(command) when is_binary(command) do
    if String.trim(command) == "" do
      {:error, :missing_acp_command}
    else
      :ok
    end
  end

  defp validate_command(_command), do: {:error, :missing_acp_command}

  defp validate_handshake(%{"protocolVersion" => @protocol_version} = result) do
    {:ok,
     %{
       protocol_version: @protocol_version,
       agent_capabilities: Map.get(result, "agentCapabilities") || %{},
       agent_info: Map.get(result, "agentInfo"),
       auth_methods: List.wrap(Map.get(result, "authMethods"))
     }}
  end

  defp validate_handshake(%{"protocolVersion" => version}),
    do: {:error, {:acp_version_unsupported, version}}

  defp validate_handshake(result), do: {:error, {:acp_response_error, result}}

  defp await_response(session, request_id), do: await_response(session, request_id, "")

  defp await_response(session, request_id, pending_line) do
    port = session.port

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_response_frame(session, request_id, pending_line <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        await_response(session, request_id, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      session.read_timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response_frame(session, request_id, line) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, response_error(error)}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = frame} ->
        {:error, {:acp_response_error, frame}}

      {:ok, %{"method" => method} = frame} when is_binary(method) ->
        # `session/update` and requests may arrive outside a prompt turn. There
        # is no turn consumer yet, so keep the connection healthy and only log.
        case handle_agent_method(session, method, frame, line, &default_on_event/1) do
          :continue -> await_response(session, request_id, "")
          {:error, reason} -> {:error, reason}
        end

      {:ok, frame} ->
        emit(&default_on_event/1, %{type: :notification, payload: frame, raw: line})
        await_response(session, request_id, "")

      {:error, _reason} ->
        log_non_json_stream_line(line, "response stream")
        await_response(session, request_id, "")
    end
  end

  defp await_turn(session, request_id, on_event, pending_line) do
    port = session.port

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_turn_frame(session, request_id, on_event, pending_line <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        await_turn(session, request_id, on_event, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      session.turn_timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_turn_frame(session, request_id, on_event, line) do
    case Jason.decode(line) do
      {:ok, %{"method" => method} = frame} when is_binary(method) ->
        case handle_agent_method(session, method, frame, line, on_event) do
          :continue -> await_turn(session, request_id, on_event, "")
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, response_error(error)}

      {:ok, %{"id" => ^request_id} = frame} ->
        turn_result(Map.get(frame, "result"), line)

      {:ok, frame} ->
        emit(on_event, %{type: :notification, payload: frame, raw: line})
        await_turn(session, request_id, on_event, "")

      {:error, _reason} ->
        log_non_json_stream_line(line, "turn stream")

        if protocol_message_candidate?(line) do
          emit(on_event, %{type: :malformed, payload: line, raw: line})
        end

        await_turn(session, request_id, on_event, "")
    end
  end

  defp turn_result(%{"stopReason" => stop_reason} = result, line) when is_binary(stop_reason) do
    {:ok, %{stop_reason: stop_reason, result: result, raw: line}}
  end

  defp turn_result(result, _line), do: {:error, {:acp_response_error, result}}

  defp handle_agent_method(_session, "session/update", frame, line, on_event) do
    emit(on_event, %{type: :notification, payload: Map.get(frame, "params"), raw: line})
    :continue
  end

  defp handle_agent_method(session, "session/request_permission", %{"id" => request_id} = frame, line, on_event) do
    params = Map.get(frame, "params")
    {outcome, decision} = permission_outcome(session.permission_policy, params)

    send_message(session.port, %{"id" => request_id, "result" => %{"outcome" => outcome}})

    emit(on_event, %{
      type: :permission,
      payload: params,
      raw: line,
      decision: decision,
      outcome: outcome
    })

    case decision do
      :approved -> :continue
      :rejected -> {:error, {:approval_required, params}}
    end
  end

  defp handle_agent_method(session, method, %{"id" => request_id} = frame, line, on_event) do
    # A method with an id is a request. The client announced no capability, so
    # every request outside the baseline it implements is unsupported: answer
    # with an explicit error and fail the turn instead of inventing a response.
    send_message(session.port, %{
      "id" => request_id,
      "error" => %{
        "code" => @method_not_found,
        "message" => "Unsupported ACP client method: #{method}"
      }
    })

    emit(on_event, %{type: :unsupported_request, method: method, payload: frame, raw: line})
    {:error, {:acp_unsupported_request, method}}
  end

  defp handle_agent_method(_session, _method, frame, line, on_event) do
    # Unknown notification: observe it and keep the turn alive.
    emit(on_event, %{type: :notification, payload: frame, raw: line})
    :continue
  end

  defp permission_outcome(:reject, params) do
    permission_selection(params, ["reject_once", "reject_always"], :rejected)
  end

  defp permission_outcome(:approve, params) do
    permission_selection(params, ["allow_once", "allow_always"], :approved)
  end

  defp permission_selection(params, kinds, decision) do
    case find_permission_option(params, kinds) do
      nil ->
        {%{"outcome" => "cancelled"}, :rejected}

      option ->
        {%{"outcome" => "selected", "optionId" => option["optionId"]}, decision}
    end
  end

  defp find_permission_option(params, kinds) do
    options = permission_options(params)

    Enum.find_value(kinds, fn kind ->
      Enum.find(options, fn option ->
        Map.get(option, "kind") == kind and is_binary(Map.get(option, "optionId"))
      end)
    end)
  end

  defp permission_options(params) when is_map(params) do
    params
    |> Map.get("options")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  # A malformed permission request (no params) is still answered, never ignored.
  defp permission_options(_params), do: []

  defp response_error(%{"code" => @auth_required_code} = error) do
    {:acp_auth_required, auth_methods(error)}
  end

  defp response_error(error), do: {:acp_response_error, error}

  defp auth_methods(%{"data" => %{"authMethods" => methods}}), do: List.wrap(methods)
  defp auth_methods(_error), do: []

  defp next_request_id(%{request_counter: counter}), do: :atomics.add_get(counter, 1, 1)

  defp emit(on_event, event) when is_function(on_event, 1), do: on_event.(event)

  defp default_on_event(%{type: type} = event) do
    Logger.debug("ACP client notification ignored: #{inspect(type)} #{inspect(Map.get(event, :raw))}")
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp validate_workspace_cwd(workspace, _worker_host), do: {:error, {:invalid_workspace_cwd, workspace}}

  defp open_port(workspace, nil, command, line_bytes) do
    secret_names = tracker_secret_environment_names()

    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(local_launch_command(command, secret_names))],
              cd: String.to_charlist(workspace),
              env: secret_port_env(secret_names),
              line: line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp open_port(workspace, worker_host, command, line_bytes) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, command, tracker_secret_environment_names())

    SSH.start_port(worker_host, remote_command, line: line_bytes)
  end

  defp local_launch_command(command, secret_names) do
    [tracker_secret_unset_command(secret_names), "exec #{command}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, command, secret_names) when is_binary(workspace) do
    ["cd #{shell_escape(workspace)}", tracker_secret_unset_command(secret_names), "exec #{command}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp secret_port_env(secret_names) do
    Enum.map(secret_names, fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command([]), do: nil
  defp tracker_secret_unset_command(names), do: "unset " <> Enum.join(names, " ")

  # Same tracker binding the Codex path uses, so the ACP child process inherits
  # the same sanitized environment (no tracker secret) as an app-server child.
  defp tracker_secret_environment_names do
    Tracker.bind_agent_tools().secret_environment_names
    |> valid_environment_names()
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    # A port opened with `spawn_executable` always exposes the OS pid; the ACP
    # protocol itself carries no pid, so the client reports the one it launched.
    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    base_metadata = %{codex_app_server_pid: to_string(os_pid)}

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _other -> base_metadata
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  defp close_port(port) when is_port(port) do
    # Closing twice, or racing a process exit, must never mask the original error
    # in the caller's `after` block, so teardown always answers `:ok`.
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("ACP #{stream_label} output: #{text}")
      else
        Logger.debug("ACP #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end
end

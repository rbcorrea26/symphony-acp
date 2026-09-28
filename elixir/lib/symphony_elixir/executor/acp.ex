defmodule SymphonyElixir.Executor.Acp do
  @moduledoc """
  Agent Client Protocol (ACP) executor.

  It implements the `SymphonyElixir.Executor` behaviour on top of the minimal
  ACP client (`SymphonyElixir.ACP.Client`): one ACP process per attempt, the
  `initialize`/`session/new` handshake, then one `session/prompt` per turn. ACP
  structures are translated here into the vocabulary the orchestrator already
  consumes, so `SymphonyElixir.AgentRunner` keeps owning workspace, hooks, turn
  policy, continuation and retry.

  Declared limits of this phase
  (`docs/fork/adr/0002-acp-protocol-mapping.md`,
  `docs/fork/adr/0004-acp-client-implementation.md`):

    * no ACP sandbox is promised: `codex.thread_sandbox`/`turn_sandbox_policy`
      are not sent to the agent and no `fs`/`terminal` capability is announced;
    * `session/request_permission` is fail-closed by default
      (`acp.auto_approve_requests: false`) and even the configured approval is a
      per-call decision, never a global policy equivalent to
      `codex.approval_policy: never`;
    * `stop_session/1` closes the process and the transport. That is **not** an
      ACP `session/cancel`/`session/close` and does not claim to be one;
    * no metric is fabricated: ACP `usage_update` payloads travel as
      notifications and are never converted into Codex token counters.
  """

  @behaviour SymphonyElixir.Executor

  require Logger

  alias SymphonyElixir.ACP.Client
  alias SymphonyElixir.Config

  @typedoc """
  Session term owned by this executor and opaque to the agent runner.

  `acp_session_id` is the real protocol identity of the session; `turn_counter`
  is local bookkeeping that produces the synthetic `<sessionId>-<n>` id the
  runner uses for logging and `turn_count`, which is never sent back to the agent
  as if it were protocol identity.
  """
  @type session :: %{
          client: Client.session(),
          acp_session_id: String.t(),
          protocol_version: pos_integer(),
          agent_capabilities: map(),
          agent_info: map() | nil,
          auth_methods: [map()],
          turn_counter: :atomics.atomics_ref()
        }

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = Config.settings!()

    with {:ok, client} <-
           Client.start(workspace,
             command: settings.acp.command,
             worker_host: worker_host,
             read_timeout_ms: settings.codex.read_timeout_ms,
             turn_timeout_ms: settings.codex.turn_timeout_ms,
             permission_policy: permission_policy(settings.acp)
           ) do
      open_session(client)
    end
  end

  @impl true
  @doc """
  Dispatch preflight for the `executor.*`/`acp.*` configuration.

  `acp.*` is only meaningful for `executor.kind: acp`, and an ACP executor
  without a command cannot start anything, so that combination fails preflight
  with `{:error, :missing_acp_command}` instead of dispatching a doomed worker.
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{acp: %{command: command}}) do
    if is_binary(command) and String.trim(command) != "" do
      :ok
    else
      {:error, :missing_acp_command}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_number = next_turn_number(session)
    session_id = "#{session.acp_session_id}-#{turn_number}"

    Logger.info("ACP session started for #{issue_context(issue)} session_id=#{session_id}")

    emit(on_message, session, :session_started, %{
      session_id: session_id,
      acp_session_id: session.acp_session_id,
      turn_id: turn_number
    })

    on_event = fn event -> handle_event(on_message, session, session_id, event) end
    result = Client.prompt(session.client, session.acp_session_id, prompt, on_event: on_event)

    finish_turn(on_message, session, session_id, turn_number, result)
  end

  @impl true
  def stop_session(%{client: client}), do: Client.close(client)

  defp open_session(client) do
    case handshake(client) do
      {:ok, acp_session_id, handshake} ->
        {:ok, build_session(client, acp_session_id, handshake)}

      {:error, reason} ->
        Client.close(client)
        {:error, reason}
    end
  end

  defp handshake(client) do
    with {:ok, handshake} <- Client.initialize(client),
         {:ok, acp_session_id} <- Client.new_session(client) do
      {:ok, acp_session_id, handshake}
    end
  end

  defp build_session(client, acp_session_id, handshake) do
    %{
      client: client,
      acp_session_id: acp_session_id,
      protocol_version: handshake.protocol_version,
      agent_capabilities: handshake.agent_capabilities,
      agent_info: handshake.agent_info,
      auth_methods: handshake.auth_methods,
      turn_counter: :atomics.new(1, [])
    }
  end

  defp permission_policy(%{auto_approve_requests: true}), do: :approve
  defp permission_policy(_acp_settings), do: :reject

  defp finish_turn(on_message, session, session_id, turn_number, result) do
    case result do
      {:ok, %{stop_reason: "end_turn"} = turn} ->
        emit(on_message, session, :turn_completed, %{
          session_id: session_id,
          payload: turn.result,
          raw: turn.raw
        })

        {:ok, %{session_id: session_id, turn_id: turn_number, result: turn.result}}

      {:ok, %{stop_reason: stop_reason} = turn} ->
        turn_error(on_message, session, session_id, turn_number, stop_reason, turn.result, turn.raw)

      {:error, {:approval_required, _payload} = reason} ->
        # The rejected permission request already emitted `:approval_required`,
        # and it stays the last event so the orchestrator blocks the issue.
        {:error, reason}

      {:error, reason} ->
        turn_failure(on_message, session, session_id, reason)
    end
  end

  defp turn_error(on_message, session, session_id, turn_number, "cancelled", result, raw) do
    details = %{session_id: session_id, turn_id: turn_number, stop_reason: "cancelled"}

    emit(on_message, session, :turn_cancelled, %{session_id: session_id, payload: result, raw: raw})
    {:error, {:turn_cancelled, details}}
  end

  defp turn_error(on_message, session, session_id, turn_number, stop_reason, result, raw) do
    details = %{session_id: session_id, turn_id: turn_number, stop_reason: stop_reason}

    emit(on_message, session, :turn_failed, %{session_id: session_id, payload: result, raw: raw})
    {:error, {:turn_failed, details}}
  end

  defp turn_failure(on_message, session, session_id, reason) do
    Logger.warning("ACP session ended with error for session_id=#{session_id}: #{inspect(reason)}")

    emit(on_message, session, :turn_ended_with_error, %{session_id: session_id, reason: reason})
    {:error, reason}
  end

  defp handle_event(on_message, session, session_id, %{type: :notification} = event) do
    emit(on_message, session, :notification, %{
      session_id: session_id,
      payload: event.payload,
      raw: event.raw
    })
  end

  defp handle_event(on_message, session, session_id, %{type: :malformed} = event) do
    emit(on_message, session, :malformed, %{
      session_id: session_id,
      payload: event.payload,
      raw: event.raw
    })
  end

  defp handle_event(on_message, session, session_id, %{type: :permission} = event) do
    event_name = if event.decision == :approved, do: :approval_auto_approved, else: :approval_required

    emit(on_message, session, event_name, %{
      session_id: session_id,
      payload: event.payload,
      raw: event.raw,
      decision: event.outcome
    })
  end

  defp handle_event(_on_message, _session, _session_id, %{type: :unsupported_request}) do
    # The turn ends with `{:error, {:acp_unsupported_request, method}}`, and the
    # error path reports it with the request payload.
    :ok
  end

  defp next_turn_number(%{turn_counter: counter}), do: :atomics.add_get(counter, 1, 1)

  defp emit(on_message, session, event, details) do
    message =
      session.client.metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
    :ok
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end

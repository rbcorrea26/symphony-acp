defmodule SymphonyElixir.Executor do
  @moduledoc """
  Executor boundary for the agent runner.

  `SymphonyElixir.AgentRunner` owns workspace, hooks, turn policy, continuation
  and retry; it reaches the coding agent only through this behaviour, so the
  concrete client (Codex app-server today, an ACP client later) is selected by
  configuration instead of being hardcoded.

  The session term is opaque: no protocol structure crosses this boundary, and
  no executor implementation is allowed to own orchestration policy.

  This mirrors the indirection already used by `SymphonyElixir.Tracker`
  (`kind -> module` map plus a behaviour), including the unsupported-kind error
  shape used by dispatch preflight.
  """

  alias SymphonyElixir.Config

  @executors %{
    "codex" => SymphonyElixir.Executor.Codex
  }

  @type session :: term()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @doc """
  Resolves a configured executor kind to its implementation module.
  """
  @spec for_kind(term()) :: {:ok, module()} | {:error, term()}
  def for_kind(kind) do
    case Map.fetch(@executors, kind) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_executor_kind, kind}}
    end
  end

  @doc """
  Returns the implementation module selected by `executor.kind`.

  Dispatch preflight rejects unsupported kinds before a worker starts
  (`SymphonyElixir.Config.validate_settings/1`), so this call only sees validated
  configuration and mirrors `SymphonyElixir.Tracker.adapter/0`.
  """
  @spec module!() :: module()
  def module! do
    {:ok, module} = for_kind(Config.settings!().executor.kind)
    module
  end

  @doc """
  Validates the `executor` config block for dispatch preflight.
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind}) do
    case for_kind(kind) do
      {:ok, _module} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

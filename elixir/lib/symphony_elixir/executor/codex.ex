defmodule SymphonyElixir.Executor.Codex do
  @moduledoc """
  Codex app-server executor.

  Pure delegation to `SymphonyElixir.Codex.AppServer`: same arguments, same
  return values and the same session term, which stays opaque to the caller.
  This module exists only to place the existing Codex client behind the
  `SymphonyElixir.Executor` boundary and does not change any Codex behavior
  (approval policy, sandbox policy, timeouts, streaming or dynamic tools).
  """

  @behaviour SymphonyElixir.Executor

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, opts), do: AppServer.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts), do: AppServer.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)
end

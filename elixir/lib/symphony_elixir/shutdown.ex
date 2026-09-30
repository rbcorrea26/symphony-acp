defmodule SymphonyElixir.Shutdown do
  @moduledoc """
  Explicit, graceful end of an on-demand run (fork extension, ADR-0009 of the platform).

  A resident Symphony never needs this: upstream keeps polling forever. The
  on-demand lifecycle does, because the platform starts Symphony only when there is
  work and expects it to **finish** — with a meaningful exit code — instead of being
  killed by a shell `timeout`. Nothing here kills a process: it asks the VM to stop
  gracefully, which stops the applications and every worker.

  Exit codes (contract with the platform's dispatcher):

    * `0` — nothing left to do for this cycle (idle; work may or may not have run)
    * `1` — the run failed (tracker/config error)
    * `3` — work is still pending when the runtime cap was reached

  `:shutdown_fun` is injectable so tests can assert the decision without stopping
  the test VM.

  The code is also recorded before the VM is asked to stop, because the end of the
  process is decided by two different places: `request/2` starts the graceful stop
  and `SymphonyElixir.CLI` observes the supervision tree going down. Recording it
  is what keeps the requested code — the contract with the platform's dispatcher —
  from being replaced by the resident default there
  (`exit_code_for_reason/1`).
  """

  require Logger

  @type code :: non_neg_integer()

  @exit_code_key :shutdown_exit_code

  @spec request(code(), String.t()) :: :ok
  def request(code, reason) when is_integer(code) and is_binary(reason) do
    Logger.info("On-demand cycle finished (#{reason}) exit=#{code}")
    Application.put_env(:symphony_elixir, @exit_code_key, code)

    fun = Application.get_env(:symphony_elixir, :shutdown_fun, &System.stop/1)
    fun.(code)

    :ok
  end

  @doc """
  Exit code to use when the supervision tree goes down.

  An on-demand cycle records the code it asked for and that code wins: it is the
  contract with the platform's dispatcher (`0` idle, `3` runtime cap reached). A
  resident Symphony (upstream, no on-demand flag) never records one, so the
  upstream mapping stays exactly as it was: `:normal` is a clean exit and anything
  else is a failure.
  """
  @spec exit_code_for_reason(term()) :: code()
  def exit_code_for_reason(reason) do
    case Application.get_env(:symphony_elixir, @exit_code_key) do
      code when is_integer(code) -> code
      _ -> resident_exit_code(reason)
    end
  end

  defp resident_exit_code(:normal), do: 0
  defp resident_exit_code(_reason), do: 1
end

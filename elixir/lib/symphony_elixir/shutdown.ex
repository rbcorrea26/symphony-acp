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
  """

  require Logger

  @type code :: non_neg_integer()

  @spec request(code(), String.t()) :: :ok
  def request(code, reason) when is_integer(code) and is_binary(reason) do
    Logger.info("On-demand cycle finished (#{reason}) exit=#{code}")

    fun = Application.get_env(:symphony_elixir, :shutdown_fun, &System.stop/1)
    fun.(code)

    :ok
  end
end

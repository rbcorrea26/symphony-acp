defmodule SymphonyElixir.Delivery.Gates do
  @moduledoc """
  Runs one consumer-defined command in the issue workspace with a hard timeout.

  It is the single command runner of the delivery stage: the repository gates
  (`delivery.gates`) and the named evidences of the acceptance contract
  (`delivery.evidence`) use the same code path, so "exit != 0 fails" and "a
  command that never finishes is a failure, not a hang" hold for both.

  The command is the **project's own** command, read from the workflow; nothing
  from an issue is ever executed.
  """

  @doc """
  Runs `command` with `sh -lc` inside `workspace`.

  Returns `{:ok, output}` on exit 0, `{:error, {:command_failed, status, output}}`
  on a non-zero exit and `{:error, {:command_timeout, timeout_ms}}` when the
  timeout is reached (the process is killed instead of blocking the run).
  """
  @spec run(Path.t(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def run(workspace, command, timeout_ms) when is_binary(command) do
    task = Task.async(fn -> System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:command_failed, status, output}}
      nil -> {:error, {:command_timeout, timeout_ms}}
    end
  end
end

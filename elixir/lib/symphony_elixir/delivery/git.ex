defmodule SymphonyElixir.Delivery.Git do
  @moduledoc """
  Local git operations of the delivery stage.

  Everything runs inside the issue workspace created by
  `SymphonyElixir.Workspace`; the canonical clone is never touched. No command
  ever performs a force push, and no command writes to the base branch: the only
  ref the pipeline publishes is the per-issue delivery branch.

  The push authenticates through a throwaway `GIT_ASKPASS` helper. The helper
  file contains no secret (it echoes an environment variable of its own child
  process), the credential never appears in `argv`, in the workspace or in a log
  line, and the file is removed even when the push fails.
  """

  require Logger

  @askpass_env "ADE_GIT_ASKPASS_TOKEN"
  @askpass_script """
  #!/bin/sh
  # Throwaway helper written by the delivery stage: no secret is stored here.
  printf '%s\\n' "${#{@askpass_env}}"
  """

  @max_output_bytes 2_048

  @type identity :: %{name: String.t(), email: String.t()}

  @spec status(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def status(workspace) do
    case run(workspace, ["status", "--porcelain"]) do
      {:ok, output} -> {:ok, changed_paths(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec changed_paths(String.t()) :: [String.t()]
  def changed_paths(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.slice(3..-1//1) |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  @spec checkout_branch(Path.t(), String.t()) :: :ok | {:error, term()}
  def checkout_branch(workspace, branch) do
    expect_ok(run(workspace, ["checkout", "-B", branch]))
  end

  @spec add_all(Path.t()) :: :ok | {:error, term()}
  def add_all(workspace), do: expect_ok(run(workspace, ["add", "-A"]))

  @spec commit(Path.t(), String.t(), identity()) :: :ok | {:error, term()}
  def commit(workspace, message, %{name: name, email: email}) do
    run(workspace, [
      "-c",
      "user.name=#{name}",
      "-c",
      "user.email=#{email}",
      "commit",
      "-q",
      "-m",
      message
    ])
    |> expect_ok()
  end

  @doc """
  Publishes the delivery branch to `origin`.

  `opts[:askpass_root]` selects where the throwaway `GIT_ASKPASS` helper is
  written (default: the system temporary directory), so an environment without a
  writable temp directory can point the pipeline somewhere it trusts.
  """
  @spec push(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def push(workspace, branch, token), do: push(workspace, branch, token, [])

  @spec push(Path.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def push(workspace, branch, token, opts) when is_binary(token) and token != "" do
    with {:ok, askpass} <- write_askpass(Keyword.get(opts, :askpass_root, System.tmp_dir!())) do
      try do
        workspace
        |> run_with_env(
          ["push", "origin", "refs/heads/#{branch}:refs/heads/#{branch}"],
          %{
            "GIT_ASKPASS" => askpass,
            "GIT_TERMINAL_PROMPT" => "0",
            @askpass_env => token
          }
        )
        |> expect_ok()
      after
        File.rm(askpass)
      end
    end
  end

  def push(_workspace, _branch, _token, _opts), do: {:error, :missing_delivery_credential}

  @spec sanitize(String.t()) :: String.t()
  def sanitize(output) when is_binary(output) do
    output
    |> String.slice(0, @max_output_bytes)
    |> mask_credentials()
  end

  defp write_askpass(root) do
    dir = Path.join(root, "symphony-delivery-askpass-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "askpass.sh")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, @askpass_script),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:askpass_unavailable, reason}}
    end
  end

  defp mask_credentials(output) do
    output
    |> String.replace(~r/(gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_\-]*/, "\\1***")
    |> String.replace(~r{(x-access-token:)[^@\s]*}, "\\1***")
  end

  defp run(workspace, args), do: run_with_env(workspace, args, %{})

  defp run_with_env(workspace, args, env) do
    opts = [cd: workspace, stderr_to_stdout: true] ++ if(env == %{}, do: [], else: [env: env])

    case System.cmd("git", args, opts) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        sanitized = sanitize(output)
        Logger.warning("Delivery git command failed args=#{inspect(args)} status=#{status} output=#{inspect(sanitized)}")
        {:error, {:git_command_failed, args, status, sanitized}}
    end
  rescue
    error in ErlangError -> {:error, {:git_not_available, Exception.message(error)}}
  end

  defp expect_ok({:ok, _output}), do: :ok
  defp expect_ok({:error, _reason} = error), do: error
end

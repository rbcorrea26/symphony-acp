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

  Reading the candidate (who changed) is this module's other job, and the
  acceptance contract depends on it: `change_set/1` reports the destination path
  of renames and every untracked file individually, and `added_lines/1` gives the
  prohibition scan the added lines with the path they belong to. Both are
  bounded, so a huge candidate cannot turn the gate into an unbounded scan.
  """

  require Logger

  @askpass_env "ADE_GIT_ASKPASS_TOKEN"
  @askpass_script """
  #!/bin/sh
  # Throwaway helper written by the delivery stage: no secret is stored here.
  printf '%s\\n' "${#{@askpass_env}}"
  """

  @max_output_bytes 2_048
  @max_scanned_files 200
  @max_scanned_lines 2_000
  @max_scanned_bytes 262_144
  @max_diff_bytes 1_048_576

  @type identity :: %{name: String.t(), email: String.t()}
  @type change :: %{path: String.t(), status: String.t()}
  @type added_line :: %{path: String.t(), text: String.t()}

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

  @doc """
  The candidate change set: one entry per path the agent changed, with the
  destination path of a rename.

  `--porcelain -z -uall` is used on purpose. `-z` is unquoted, so a path with a
  space or a non-ASCII character arrives intact, and `-uall` lists each untracked
  file instead of a compressed `dir/`, which is what lets an expected path inside
  a directory the agent just created be matched.
  """
  @spec change_set(Path.t()) :: {:ok, [change()]} | {:error, term()}
  def change_set(workspace) do
    case run_raw(workspace, ["status", "--porcelain", "-z", "-uall"]) do
      {:ok, output} -> {:ok, change_entries(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parses a `git status --porcelain -z` output (`XY PATH\\0[ORIGIN\\0]`)."
  @spec change_entries(String.t()) :: [change()]
  def change_entries(output) when is_binary(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> parse_entries([])
  end

  @doc """
  The added lines of the candidate, with the path they belong to.

  Tracked modifications come from `git diff HEAD` (added lines only, so an
  untouched line is never scanned) and untracked files are read from disk. The
  result is bounded by `@max_scanned_files`/`@max_scanned_lines` and reports
  `truncated: true` when the cap was reached, so the caller can say the scan was
  incomplete instead of pretending it was exhaustive.
  """
  @spec added_lines(Path.t()) :: {:ok, %{lines: [added_line()], truncated: boolean()}} | {:error, term()}
  def added_lines(workspace) do
    with {:ok, diff} <- run_raw(workspace, ["-c", "core.quotePath=false", "diff", "HEAD", "--no-color", "--unified=0"]),
         {:ok, untracked} <- run_raw(workspace, ["ls-files", "--others", "--exclude-standard", "-z"]) do
      {diff_lines, diff_truncated} = diff_added_lines(diff)
      {file_lines, files_dropped, bytes_partial} = untracked_lines(workspace, untracked)
      lines = diff_lines ++ file_lines

      {:ok,
       %{
         lines: Enum.take(lines, @max_scanned_lines),
         truncated: diff_truncated or files_dropped or bytes_partial or length(lines) > @max_scanned_lines
       }}
    end
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
    # Git output and candidate paths are bytes, not necessarily UTF-8: replacing
    # the invalid sequences keeps `String` operations (and the log line) safe
    # instead of raising while the pipeline is reporting a failure.
    output
    |> String.replace_invalid()
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

  defp run_raw(workspace, args), do: run_with_env(workspace, args, %{}, & &1)

  defp run_with_env(workspace, args, env, transform \\ &String.trim/1) do
    opts = [cd: workspace, stderr_to_stdout: true] ++ if(env == %{}, do: [], else: [env: env])

    case System.cmd("git", args, opts) do
      {output, 0} ->
        {:ok, transform.(output)}

      {output, status} ->
        sanitized = sanitize(output)
        Logger.warning("Delivery git command failed args=#{inspect(args)} status=#{status} output=#{inspect(sanitized)}")
        {:error, {:git_command_failed, args, status, sanitized}}
    end
  rescue
    error in ErlangError -> {:error, {:git_not_available, Exception.message(error)}}
  end

  # --- candidate reading --------------------------------------------------

  defp parse_entries([], acc), do: Enum.reverse(acc)

  defp parse_entries([field | rest], acc) do
    entry = change_entry(field)
    # In the `-z` format a rename/copy is two fields: the destination (with the
    # status) followed by the origin, which is not a change of its own.
    rest = if rename?(entry.status), do: Enum.drop(rest, 1), else: rest

    parse_entries(rest, [entry | acc])
  end

  defp change_entry(field) do
    %{status: field |> String.slice(0, 2) |> String.trim(), path: String.slice(field, 3..-1//1)}
  end

  defp rename?(status), do: String.contains?(status, ["R", "C"])

  defp diff_added_lines(diff) do
    {text, truncated} = limit_bytes(diff, @max_diff_bytes)

    {lines, _path} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], nil}, &diff_line/2)

    {Enum.reverse(lines), truncated}
  end

  # The child capture of `git diff` is proportional to the candidate's own diff
  # (that is a declared limit of the stage); the parse is bounded, so the
  # structures built here are not, and the verdict says the scan was truncated.
  defp limit_bytes(binary, limit) do
    if byte_size(binary) > limit do
      {binary_part(binary, 0, limit), true}
    else
      {binary, false}
    end
  end

  defp diff_line("+++ b/" <> path, {lines, _path}), do: {lines, path |> String.trim_trailing()}
  defp diff_line("+++ " <> _other, {lines, _path}), do: {lines, nil}
  defp diff_line("+" <> text, {lines, path}), do: {added_line(path || "diff", text) ++ lines, path}
  defp diff_line(_line, {lines, path}), do: {lines, path}

  defp untracked_lines(workspace, untracked) do
    paths = String.split(untracked, <<0>>, trim: true)
    {scanned, dropped} = Enum.split(paths, @max_scanned_files)
    results = Enum.map(scanned, &file_lines(workspace, &1))

    {Enum.flat_map(results, &elem(&1, 0)), dropped != [], Enum.any?(results, &elem(&1, 1))}
  end

  defp file_lines(workspace, path) do
    case read_limited(Path.join(workspace, path), @max_scanned_bytes) do
      {:ok, content, partial} ->
        lines = content |> String.split(~r/\r?\n/, trim: true) |> Enum.flat_map(&added_line(path, &1))
        {lines, partial}

      {:error, _reason} ->
        {[], false}
    end
  end

  defp read_limited(path, limit) do
    with {:ok, stat} <- File.lstat(path),
         :ok <- require_regular(stat),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        # One byte more than the cap tells whether the file was only partially
        # scanned, instead of pretending the prefix was the whole content.
        case IO.binread(io, limit + 1) do
          :eof -> {:ok, "", false}
          data when byte_size(data) > limit -> {:ok, binary_part(data, 0, limit), true}
          data -> {:ok, data, false}
        end
      after
        File.close(io)
      end
    end
  end

  # `lstat` (not `stat`): a symlink is reported as such and refused instead of
  # being followed to whatever it points at.
  defp require_regular(%File.Stat{type: :regular}), do: :ok
  defp require_regular(%File.Stat{type: type}), do: {:error, {:not_a_regular_file, type}}

  # A binary or non-UTF-8 file is not a line of shell code: it is skipped instead
  # of crashing the scan. Symlinks are not followed either (`read_limited/2`
  # refuses anything that is not a regular file), so a link cannot make the scan
  # read something outside the workspace.
  defp added_line(path, text) do
    if String.valid?(text), do: [%{path: path, text: text}], else: []
  end

  defp expect_ok({:ok, _output}), do: :ok
  defp expect_ok({:error, _reason} = error), do: error
end

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
  prohibition scan the added lines with the path they belong to.

  Both reads are **bounded and fail closed**: the change set is capped
  (`@max_change_set` entries, non-UTF-8 paths refused) and the added-lines scan
  stops at its budgets (`@max_diff_bytes`, `@max_scanned_files`,
  `@max_scanned_bytes`, `@max_scanned_lines`), declaring `truncated` when a bound
  was reached. The declared residual: the child captures of `git` are proportional
  to what the candidate produced; the *parse* and the structures built here are
  limited.
  """

  require Logger

  @askpass_env "ADE_GIT_ASKPASS_TOKEN"
  @askpass_script """
  #!/bin/sh
  # Throwaway helper written by the delivery stage: no secret is stored here.
  printf '%s\\n' "${#{@askpass_env}}"
  """

  @max_output_bytes 2_048
  @max_change_set 5_000
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
  space arrives intact, and `-uall` lists each untracked file instead of a
  compressed `dir/`, which is what lets an expected path inside a directory the
  agent just created be matched.

  The read is **bounded and fails closed**: a change set above `@max_change_set`
  entries is an error instead of a partial verdict, and a path that is not valid
  UTF-8 is refused (the entry cannot be matched or persisted safely) instead of
  crashing the run. The child capture of `git status` is proportional to the
  number of changes, which is a declared limit of the stage.
  """
  @spec change_set(Path.t()) :: {:ok, [change()]} | {:error, term()}
  def change_set(workspace) do
    with {:ok, output} <- run_raw(workspace, ["status", "--porcelain", "-z", "-uall"]) do
      case change_entries(output) do
        {:ok, entries} -> {:ok, entries}
        :overflow -> {:error, {:change_set_too_large, @max_change_set}}
        :invalid_encoding -> {:error, {:change_set_not_utf8, :rejected}}
      end
    end
  end

  @doc """
  Parses a `git status --porcelain -z` output (`XY PATH\\0[ORIGIN\\0]`).

  At most `@max_change_set + 1` entries are materialized: `:overflow` means the
  change set is too big to be accepted, and `:invalid_encoding` means a path is
  not valid UTF-8.
  """
  @spec change_entries(String.t()) :: {:ok, [change()]} | :overflow | :invalid_encoding
  def change_entries(output) when is_binary(output) do
    if String.valid?(output) do
      output |> String.split(<<0>>, trim: true) |> parse_entries([], 0)
    else
      :invalid_encoding
    end
  end

  @doc """
  The added lines of the candidate, with the path they belong to.

  Tracked modifications come from `git diff HEAD` (added lines only, so an
  untouched line is never scanned) and untracked files are read from disk. Every
  step is bounded (`@max_diff_bytes`, `@max_scanned_files`, `@max_scanned_bytes`,
  `@max_scanned_lines`) and the collection **stops at the line budget** instead of
  building everything and truncating afterwards; `truncated: true` says a bound was
  reached, so the caller can declare the scan incomplete instead of pretending it
  was exhaustive.
  """
  @spec added_lines(Path.t()) :: {:ok, %{lines: [added_line()], truncated: boolean()}} | {:error, term()}
  def added_lines(workspace) do
    with {:ok, diff} <- run_raw(workspace, ["-c", "core.quotePath=false", "diff", "HEAD", "--no-color", "--unified=0"]),
         {:ok, untracked} <- run_raw(workspace, ["ls-files", "--others", "--exclude-standard", "-z"]) do
      {diff_lines, diff_truncated} = diff_added_lines(diff)
      budget = @max_scanned_lines - length(diff_lines)
      {file_lines, files_dropped, files_truncated} = untracked_lines(workspace, untracked, budget)

      {:ok,
       %{
         lines: diff_lines ++ file_lines,
         truncated: diff_truncated or files_dropped or files_truncated
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

  defp parse_entries([], acc, _count), do: {:ok, Enum.reverse(acc)}

  defp parse_entries(_fields, _acc, count) when count >= @max_change_set, do: :overflow

  defp parse_entries([field | rest], acc, count) do
    entry = change_entry(field)
    # In the `-z` format a rename/copy is two fields: the destination (with the
    # status) followed by the origin, which is not a change of its own.
    rest = if rename?(entry.status), do: Enum.drop(rest, 1), else: rest

    parse_entries(rest, [entry | acc], count + 1)
  end

  # Binary match on purpose: the status is ASCII and the path is raw bytes (the
  # output was validated as UTF-8 before this parse, so `String` is safe here).
  defp change_entry(<<x::binary-size(1), y::binary-size(1), " ", path::binary>>) do
    %{status: String.trim(x <> y), path: path}
  end

  defp rename?(status), do: String.contains?(status, ["R", "C"])

  defp diff_added_lines(diff) do
    {text, text_truncated} = limit_bytes(diff, @max_diff_bytes)

    {lines, _path, truncated} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce_while({[], nil, false}, &diff_step/2)

    {Enum.reverse(lines), text_truncated or truncated}
  end

  # The collection stops at the documented line budget: the `+`-lines are not all
  # built to be truncated afterwards.
  defp diff_step(line, {lines, path, truncated}) do
    case diff_line(line, path) do
      {:header, new_path} -> {:cont, {lines, new_path, truncated}}
      {:added, text, file} -> add_line(added_line(file, text), {lines, path, truncated})
      :skip -> {:cont, {lines, path, truncated}}
    end
  end

  defp add_line([], acc), do: {:cont, acc}

  defp add_line([line], {lines, path, truncated}) do
    if length(lines) >= @max_scanned_lines do
      {:halt, {lines, path, true}}
    else
      {:cont, {[line | lines], path, truncated}}
    end
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

  defp diff_line("+++ b/" <> path, _path), do: {:header, String.trim_trailing(path)}
  defp diff_line("+++ " <> _other, _path), do: {:header, nil}
  defp diff_line("+" <> text, path), do: {:added, text, path || "diff"}
  defp diff_line(_line, _path), do: :skip

  defp untracked_lines(_workspace, _untracked, budget) when budget <= 0, do: {[], false, true}

  defp untracked_lines(workspace, untracked, budget) do
    paths = String.split(untracked, <<0>>, trim: true)
    {scanned, dropped} = Enum.split(paths, @max_scanned_files)

    {lines, partial, exhausted} =
      Enum.reduce_while(scanned, {[], false, false}, fn path, {lines, partial, _exhausted} ->
        {file_lines, file_partial} = file_lines(workspace, path)
        {taken, over} = Enum.split(file_lines, budget - length(lines))
        acc = {taken ++ lines, partial or file_partial, over != []}

        if over == [], do: {:cont, acc}, else: {:halt, acc}
      end)

    {lines, dropped != [], partial or exhausted}
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

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
  acceptance contract depends on it: `change_set/1` reports a rename as the
  destination **plus the origin as a deletion** (the rename removed it, so a scope
  that authorized only the destination must not be able to delete an unrelated
  file) and every untracked file individually, and `added_lines/1` gives the
  prohibition scan the added lines with the path they belong to.

  A **resumed** cycle has no worktree change set to read: the candidate was
  committed by the cycle that created it and the workspace is clean, so the change
  set comes from git instead — `candidate_change_set/2` reads the branch head
  against `merge_base/2`, the commit the branch forked from. A clean workspace is
  never a change set of its own (that would be an invented empty read) and a
  contract that became stricter after the publication is evaluated against the real
  content of the published candidate.

  The reads are **bounded and fail closed**: the change set is capped
  (`@max_change_set` entries, non-UTF-8 paths refused), the **parse of both
  formats is bounded while it reads** — one NUL-delimited field at a time, so a
  candidate with millions of paths never materializes a list of millions of entries
  before the cap applies — and the added-lines scan stops at its budgets
  (`@max_diff_bytes`, enforced while the `git diff` child is still running so the
  whole diff is never captured; `@max_scanned_files`, `@max_scanned_bytes`,
  `@max_scanned_lines`), declaring `truncated` when a bound was reached. The
  declared residual: the captures of `git status`, `git ls-files` and of the
  candidate `git diff` are proportional to the number of paths the candidate
  produced (the change set is capped at `@max_change_set`); the *parse* and the
  structures built here are limited.
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
  The candidate change set: one entry per change the agent made.

  A rename is two entries — the destination with the status `R` and the origin
  with the status `D` — because the rename **deleted the origin**: a `strict`
  contract that authorized only the destination would otherwise be a way to remove
  an unauthorized path. A copy is only the destination; its origin stays.

  `--porcelain -z -uall` is used on purpose. `-z` is unquoted (and reports the
  destination of a rename before its origin), so a path with a space arrives
  intact, and `-uall` lists each untracked file instead of a compressed `dir/`,
  which is what lets an expected path inside a directory the agent just created be
  matched.

  The read is **bounded and fails closed**: a change set above `@max_change_set`
  entries is an error instead of a partial verdict, and a path that is not valid
  UTF-8 is refused (the entry cannot be matched or persisted safely) instead of
  crashing the run. The child capture of `git status` is proportional to the
  number of changes, which is a declared limit of the stage.
  """
  @spec change_set(Path.t()) :: {:ok, [change()]} | {:error, term()}
  def change_set(workspace) do
    with {:ok, output} <- run_raw(workspace, ["status", "--porcelain", "-z", "-uall"]) do
      entries_result(change_entries(output))
    end
  end

  @doc """
  The change set of a **published** candidate: the delivery branch head against the
  commit it forked from.

  A resumed cycle has nothing in the worktree to read — the candidate was committed
  by the cycle that created it —, so the change set is derived from git instead of
  being invented as empty: `base` is `merge_base/2` (the fork point with the base
  branch), which makes the diff exactly what the branch brought over the base, even
  if the base branch moved after the clone.

  The shape and the bounds are the same as `change_set/1`: a rename is the
  destination plus the origin **as a deletion**, a copy is only the destination, the
  cap and the non-UTF-8 refusal apply. Only the git format differs —
  `--name-status -z` prints the status first and, for a rename or a copy, the source
  before the destination (the opposite of the porcelain format).
  """
  @spec candidate_change_set(Path.t(), String.t()) :: {:ok, [change()]} | {:error, term()}
  def candidate_change_set(workspace, base) do
    args = ["-c", "core.quotePath=false", "diff", "--name-status", "--find-renames", "--find-copies", "-z", base]

    with {:ok, output} <- run_raw(workspace, args) do
      entries_result(scan_diff(output, [], 0))
    end
  end

  @doc """
  The commit a candidate branch forked from: the merge base of `HEAD` with
  `base_branch`.

  `base_branch` is resolved as the remote-tracking branch `origin/<base_branch>`
  first and as the local branch of the same name after, so a workspace cloned with a
  remote and one created from a local branch both resolve. A base branch that does
  not exist is an error instead of an empty diff: a change set that cannot be
  derived must fail closed, never be read as "the candidate changed nothing".
  """
  @spec merge_base(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def merge_base(workspace, base_branch) do
    with {:ok, ref} <- base_ref(workspace, base_branch) do
      run(workspace, ["merge-base", ref, "HEAD"])
    end
  end

  # `for-each-ref` answers with nothing for a ref that does not exist (exit 0)
  # instead of failing: an absent base branch is an expected negative of a probe, not
  # a git command failure to log.
  defp base_ref(workspace, base_branch) do
    ["refs/remotes/origin/#{base_branch}", "refs/heads/#{base_branch}"]
    |> Enum.reduce_while({:error, {:delivery_base_missing, base_branch}}, fn ref, missing ->
      case run(workspace, ["for-each-ref", "--format=%(objectname)", ref]) do
        {:ok, ""} -> {:cont, missing}
        {:ok, _sha} -> {:halt, {:ok, ref}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Parses a `git status --porcelain -z` output (`XY PATH\\0[ORIGIN\\0]`).

  The status `R` (rename) yields two entries — the destination and the origin as a
  deletion — while `C` (copy) yields only the destination. The scan is **bounded
  while it reads**: it takes one NUL-delimited field at a time and stops at the
  first entry above `@max_change_set`, so the list of paths is never materialized
  before the cap applies. Nothing past that point is read — not even decoded as
  UTF-8, since the answer is already the same failure. `:overflow` means the change
  set is too big to be accepted; `:invalid_encoding` means a field *inside* the cap
  is not valid UTF-8.
  """
  @spec change_entries(String.t()) :: {:ok, [change()]} | :overflow | :invalid_encoding
  def change_entries(output) when is_binary(output), do: scan_porcelain(output, [], 0)

  @doc """
  The added lines of the candidate, with the path they belong to.

  Tracked modifications come from `git diff` against `revision` (added lines only,
  so an untouched line is never scanned) and untracked files are read from disk.
  Every step is bounded (`@max_diff_bytes`, `@max_scanned_files`,
  `@max_scanned_bytes`, `@max_scanned_lines`) and the collection **stops at the
  budget it reached** instead of building everything and truncating afterwards;
  `truncated: true` says a bound was reached, so the caller can declare the scan
  incomplete instead of pretending it was exhaustive.

  `revision` is what the tracked lines are read against: `HEAD` (the default) for
  the change set the workspace is about to commit, and `merge_base/2` when the
  subject is a **published** candidate — the scan then reads the added lines of the
  candidate itself instead of reporting a clean scan over an empty worktree. The
  list of untracked files is read the same way the change sets are: **while it is
  read**, one NUL-delimited path at a time up to `@max_scanned_files`, so the whole
  `git ls-files` output is not materialized to apply the cap afterwards.

  The `git diff` child is read **bounded**: the reader stops at `@max_diff_bytes`
  and closes the port (which kills `git`), so a huge diff is never captured in the
  memory of the worker — see `diff_output/2`.
  """
  @spec added_lines(Path.t()) :: {:ok, %{lines: [added_line()], truncated: boolean()}} | {:error, term()}
  def added_lines(workspace), do: added_lines(workspace, "HEAD")

  @spec added_lines(Path.t(), String.t()) :: {:ok, %{lines: [added_line()], truncated: boolean()}} | {:error, term()}
  def added_lines(workspace, revision) do
    with {:ok, diff, diff_truncated} <- diff_output(workspace, revision),
         {:ok, untracked} <- run_raw(workspace, ["ls-files", "--others", "--exclude-standard", "-z"]) do
      {diff_lines, parse_truncated} = diff_added_lines(diff)
      budget = @max_scanned_lines - length(diff_lines)
      {file_lines, files_dropped, files_truncated} = untracked_lines(workspace, untracked, budget)

      {:ok,
       %{
         lines: diff_lines ++ file_lines,
         truncated: diff_truncated or parse_truncated or files_dropped or files_truncated
       }}
    end
  end

  @doc """
  The SHA of the local `HEAD` of the workspace, right after `create_candidate/4`
  committed it: it is the content the acceptance and the local gates validated, so
  the delivery can tell whether the observed candidate is still that commit.
  """
  @spec head_sha(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def head_sha(workspace), do: run(workspace, ["rev-parse", "HEAD"])

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

  # --- parsing of the change set formats ----------------------------------

  # One field at a time, cut on the NUL that ends it: `binary_part/3` returns a
  # sub-binary of the output (already in memory), never a copy of the rest, and the
  # `<<0, rest>>` clause skips the empty field a doubled or trailing NUL would
  # produce — the same "trim" the previous `String.split/3` did. Exhausted input is
  # the empty field, so no consumer needs a second "end of stream" answer.
  defp next_field(<<0, rest::binary>>), do: next_field(rest)

  defp next_field(binary) do
    case :binary.match(binary, <<0>>) do
      :nomatch ->
        {binary, <<>>}

      {at, 1} ->
        {binary_part(binary, 0, at), binary_part(binary, at + 1, byte_size(binary) - at - 1)}
    end
  end

  defp scan_porcelain(binary, acc, count) do
    case next_field(binary) do
      {<<>>, _rest} -> {:ok, Enum.reverse(acc)}
      {field, rest} -> porcelain_entry(field, rest, acc, count)
    end
  end

  defp porcelain_entry(field, rest, acc, count) do
    with :ok <- encoding(field),
         {:ok, rest, entries} <- porcelain_entries(change_entry(field), rest) do
      keep(entries, rest, acc, count, &scan_porcelain/3)
    end
  end

  defp scan_diff(binary, acc, count) do
    case next_field(binary) do
      {<<>>, _rest} -> {:ok, Enum.reverse(acc)}
      {field, rest} -> diff_entry(field, rest, acc, count)
    end
  end

  defp diff_entry(field, rest, acc, count) do
    with :ok <- encoding(field),
         {:ok, rest, entries} <- diff_entries(field, rest) do
      keep(entries, rest, acc, count, &scan_diff/3)
    end
  end

  # The scan stops at the first entry above the cap instead of building the whole
  # list and truncating afterwards: the caller gets the fail-closed answer, and the
  # bytes past that point are never read.
  defp keep(entries, rest, acc, count, scan) do
    materialized = count + length(entries)

    if materialized > @max_change_set do
      :overflow
    else
      scan.(rest, Enum.reverse(entries, acc), materialized)
    end
  end

  defp entries_result({:ok, entries}), do: {:ok, entries}
  defp entries_result(:overflow), do: {:error, {:change_set_too_large, @max_change_set}}
  defp entries_result(:invalid_encoding), do: {:error, {:change_set_not_utf8, :rejected}}

  defp encoding(field) do
    if String.valid?(field), do: :ok, else: :invalid_encoding
  end

  # In the `-z` **porcelain** format a rename/copy is two fields: the destination
  # (which carries the status) followed by the origin. A rename **removed** the
  # origin, so the origin is reported as a deletion of its own — otherwise a
  # candidate could rename an unauthorized path into an authorized one and delete
  # the origin with no finding at all. A copy leaves the origin in place, so it is
  # consumed and not reported at all.
  defp porcelain_entries(%{status: status} = entry, rest) do
    if rename?(status) or copy?(status), do: origin_field(rest, status, entry), else: {:ok, rest, [entry]}
  end

  defp origin_field(rest, status, entry) do
    case next_field(rest) do
      # An origin that is missing (a malformed read) does not crash the parse.
      {<<>>, remaining} ->
        {:ok, remaining, [entry]}

      {origin, remaining} ->
        case encoding(origin) do
          :ok -> {:ok, remaining, origin_entries(status, entry, origin)}
          :invalid_encoding -> :invalid_encoding
        end
    end
  end

  defp origin_entries(status, entry, origin) do
    if rename?(status), do: [entry, %{status: "D", path: origin}], else: [entry]
  end

  # `git diff --name-status -z` emits `STATUS\0PATH\0` and, for a rename or a copy,
  # `STATUS\0SOURCE\0DESTINATION\0` — the source **first**, the opposite of the
  # porcelain format. A rename becomes the same two entries as `change_set/1` and a
  # copy only the destination.
  defp diff_entries(field, rest) do
    {source, remaining} = next_field(rest)

    with :ok <- encoding(source) do
      case String.first(field) do
        letter when letter in ~w(R C) -> diff_rename(letter, source, remaining)
        letter -> {:ok, remaining, [%{status: letter, path: source}]}
      end
    end
  end

  defp diff_rename(letter, source, remaining) do
    {destination, rest} = next_field(remaining)

    with :ok <- encoding(destination), do: {:ok, rest, renamed(letter, source, destination)}
  end

  defp renamed("C", _source, destination), do: [%{status: "C", path: destination}]

  defp renamed("R", source, destination) do
    [%{status: "R", path: destination}, %{status: "D", path: source}]
  end

  # Binary match on purpose: the status is ASCII and the path is raw bytes (the
  # field was validated as UTF-8 before this parse, so `String` is safe here).
  defp change_entry(<<x::binary-size(1), y::binary-size(1), " ", path::binary>>) do
    %{status: String.trim(x <> y), path: path}
  end

  defp rename?(status), do: String.contains?(status, "R")
  defp copy?(status), do: String.contains?(status, "C")

  # The parse keeps the state of the file: `+++ b/path` is a header **only** outside a
  # hunk (before the first `@@`), so an added source line that starts with `++ b/`
  # cannot be mistaken for one — taking it as a header would both drop it from the
  # scan and steal the path of every line after it.
  defp diff_added_lines(diff) do
    {lines, _path, _state, truncated} =
      diff
      |> String.split(~r/\r?\n/)
      |> Enum.reduce_while({[], nil, :header, false}, &diff_step/2)

    {Enum.reverse(lines), truncated}
  end

  # The collection stops at the documented line budget: the `+`-lines are not all
  # built to be truncated afterwards.
  defp diff_step(line, {lines, path, state, truncated}) do
    case diff_line(line, state) do
      :file -> {:cont, {lines, nil, :header, truncated}}
      {:header, new_path} -> {:cont, {lines, new_path, :header, truncated}}
      :hunk -> {:cont, {lines, path, :hunk, truncated}}
      {:added, text} -> add_line(added_line(path || "diff", text), {lines, path, :hunk, truncated})
      :skip -> {:cont, {lines, path, state, truncated}}
    end
  end

  defp add_line([], acc), do: {:cont, acc}

  defp add_line([line], {lines, path, state, truncated}) do
    if length(lines) >= @max_scanned_lines do
      {:halt, {lines, path, state, true}}
    else
      {:cont, {[line | lines], path, state, truncated}}
    end
  end

  # The diff of a candidate can be arbitrarily big, so the child is read
  # **bounded**: the reader stops at `@max_diff_bytes`, closes the port (which kills
  # `git`) and reports the truncation. `System.cmd/3` — what `run_raw/2` uses —
  # would capture the whole diff in the memory of the worker first. The port is
  # owned by a task on purpose: the bytes the child had already sent die with that
  # process, so no later read can see the tail of another candidate's diff.
  defp diff_output(workspace, revision) do
    args = ["-c", "core.quotePath=false", "diff", revision, "--no-color", "--unified=0"]
    read_git_bounded(workspace, args, @max_diff_bytes)
  end

  defp read_git_bounded(workspace, args, limit) do
    case System.find_executable("git") do
      nil ->
        {:error, {:git_not_available, "git executable not found"}}

      git ->
        Task.async(fn -> read_bounded(git, workspace, args, limit) end)
        |> Task.await(:infinity)
    end
  end

  defp read_bounded(git, workspace, args, limit) do
    port =
      Port.open({:spawn_executable, String.to_charlist(git)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: workspace
      ])

    collect(port, args, limit)
  end

  defp collect(port, args, limit), do: collect(port, args, limit, [], 0)

  defp collect(port, args, limit, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        {kept, truncated} = take_chunk(data, limit - size)

        if truncated do
          Port.close(port)
          {:ok, to_binary([kept | chunks]), true}
        else
          collect(port, args, limit, [kept | chunks], size + byte_size(kept))
        end

      {^port, {:exit_status, 0}} ->
        {:ok, to_binary(chunks), false}

      {^port, {:exit_status, status}} ->
        output = chunks |> to_binary() |> sanitize()

        Logger.warning("Delivery git command failed args=#{inspect(args)} status=#{status} output=#{inspect(output)}")
        {:error, {:git_command_failed, args, status, output}}
    end
  end

  defp take_chunk(data, remaining) when byte_size(data) > remaining do
    {binary_part(data, 0, remaining), true}
  end

  defp take_chunk(data, _remaining), do: {data, false}

  defp to_binary(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  # A unified diff line is classified with the state of the parse: `+++ b/path` is a
  # header only outside a hunk, and `diff --git` is what opens a new file.
  defp diff_line("diff --git " <> _rest, _state), do: :file
  defp diff_line("+++ b/" <> path, :header), do: {:header, String.trim_trailing(path)}
  defp diff_line("+++ " <> _other, :header), do: {:header, nil}
  defp diff_line("@@" <> _rest, _state), do: :hunk
  defp diff_line("+" <> text, _state), do: {:added, text}
  defp diff_line(_line, _state), do: :skip

  defp untracked_lines(_workspace, _untracked, budget) when budget <= 0, do: {[], false, true}

  defp untracked_lines(workspace, untracked, budget) do
    {paths, dropped} = untracked_paths(untracked, @max_scanned_files)

    {lines, partial, exhausted} =
      Enum.reduce_while(paths, {[], false, false}, fn path, {lines, partial, _exhausted} ->
        {file_lines, file_partial} = file_lines(workspace, path)
        {taken, over} = Enum.split(file_lines, budget - length(lines))
        acc = {taken ++ lines, partial or file_partial, over != []}

        if over == [], do: {:cont, acc}, else: {:halt, acc}
      end)

    {lines, dropped, partial or exhausted}
  end

  # The paths are taken from the NUL-delimited list **while it is read** — the whole list
  # of untracked files is never materialized to apply the file cap afterwards — and one
  # path beyond the cap is what tells whether the list was cut.
  defp untracked_paths(binary, left) do
    case next_field(binary) do
      {<<>>, _rest} ->
        {[], false}

      {_path, _rest} when left <= 0 ->
        {[], true}

      {path, rest} ->
        {paths, cut} = untracked_paths(rest, left - 1)
        {[path | paths], cut}
    end
  end

  defp file_lines(workspace, path) do
    case read_limited(Path.join(workspace, path), @max_scanned_bytes) do
      {:ok, content, partial} ->
        lines = content |> String.split(~r/\r?\n/, trim: true) |> Enum.flat_map(&added_line(path, &1))
        {lines, partial}

      # Not a regular file (a symlink, a directory, a device): skipping it is
      # deliberate and does not make the scan partial — its content is not a line of
      # the candidate, and following a link could read outside the workspace.
      {:error, {:not_a_regular_file, _type}} ->
        {[], false}

      # A regular file that could not be read is a **hole in the scan**: it may hold a
      # prohibition this layer cannot see, so the scan is declared incomplete instead
      # of complete-without-that-file (strict fails closed, advisory reports it).
      {:error, _reason} ->
        {[], true}
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

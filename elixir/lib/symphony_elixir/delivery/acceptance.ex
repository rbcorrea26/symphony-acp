defmodule SymphonyElixir.Delivery.Acceptance do
  @moduledoc """
  Acceptance contract gate of the delivery stage (`pipeline_contract`).

  This is the layer that answers **"was the issue satisfied?"**, and it is
  independent from the two others: `delivery.gates` answers "is the repository
  still valid?" and the GitHub check runs answer "did the published candidate
  pass the CI?". All three run before a candidate is promoted, and green gates do
  not replace acceptance.

  This module is the impure side of the contract: `SymphonyElixir.PipelineContract`
  parses the issue body and decides scope over data, while here the candidate
  change set is read from the workspace, the required evidence is executed and the
  verdict is logged, returned as `SymphonyElixir.Delivery.Acceptance.Result` and
  persisted in the handoff comment.

  Policy:

    * the acceptance is checked **before** the gates and before anything is
      published: a blocking finding (`strict` mode, or a contract that cannot be
      enforced) fails the run, so no branch, no pull request and no label exist;
    * `advisory` findings are reported and the delivery continues — the
      architectural review decides (`ARCHITECT_PASS`/`REWORK`/`BLOCKED` belongs to
      the next increment);
    * evidence is **named**: the issue demands names (`required_evidence`), the
      workflow provides the commands (`delivery.evidence`). The name
      `repository-gates` is reserved and is satisfied by the gates stage itself,
      which runs immediately before this phase; a demanded name without a provider
      is a finding, never an invented pass;
    * an issue without a contract is **not configured**, not implicitly strict;
    * there is no candidate change set to accept (a `--resume-only` cycle over an
      already published candidate, or nothing to publish): the verdict is
      `not_applicable` instead of failing, because the candidate being resumed was
      accepted by the cycle that created it;
    * both phases read the change set from the workspace; the read is cheap, has
      no state and keeps the two phases independently testable, which is also why
      a retry over the same candidate produces the same verdict.

  What this layer does **not** verify is declared instead of assumed: the
  forbidden-operation check is a pattern scan of the added lines of the candidate,
  so "no finding" is not a proof of absence, and the contents/quality of what was
  delivered belong to the gates, the review and the architect — see the `limits`
  of the result and `docs/fork/acceptance-contract.md`.
  """

  require Logger

  alias SymphonyElixir.Delivery.Acceptance.Result
  alias SymphonyElixir.Delivery.{Gates, Git}
  alias SymphonyElixir.PipelineContract
  alias SymphonyElixir.PipelineContract.Finding
  alias SymphonyElixir.Tracker.Issue

  @reserved_evidence "repository-gates"
  @max_summary_findings 3
  @comment_text_limit 300
  @max_persisted_bytes 16_384

  @doc """
  Scope, prohibition and contract findings of the candidate change set.

  Returns `{:error, {:delivery_acceptance_failed, result}}` when the verdict
  blocks the delivery; `advisory` findings come back in `{:ok, result}`.
  """
  @spec scope(Path.t(), Issue.t()) :: {:ok, Result.t()} | {:error, term()}
  def scope(workspace, %Issue{} = issue) do
    case contract_of(issue) do
      {:ok, :absent} -> {:ok, Result.not_configured()}
      {:error, reason} -> Result.invalid_contract(reason) |> decide(:scope)
      {:ok, contract} -> scope_phase(workspace, contract)
    end
  end

  @doc """
  Evidence required by the contract for this candidate.

  Only the names demanded by the issue are executed, and each one is resolved
  through the registry of the workflow (`delivery.evidence`) or the reserved
  `repository-gates`.
  """
  @spec evidence(Path.t(), Issue.t(), map()) :: {:ok, Result.t()} | {:error, term()}
  def evidence(workspace, %Issue{} = issue, delivery) do
    case contract_of(issue) do
      {:ok, :absent} -> {:ok, Result.not_configured()}
      {:error, reason} -> Result.invalid_contract(reason) |> decide(:evidence)
      {:ok, contract} -> evidence_phase(workspace, contract, delivery)
    end
  end

  @doc "One-line, human-readable acceptance summary (log and handoff comment)."
  @spec describe(Result.t()) :: String.t()
  def describe(%Result{status: :not_configured}), do: "not declared in the issue body (acceptance not configured)"
  def describe(%Result{status: :not_applicable}), do: "not applicable (no candidate change set to accept)"

  def describe(%Result{status: :pass} = result) do
    "`#{result.mode}` passed (#{length(result.change_set.delivered)}/#{length(result.change_set.expected)} expected path(s) delivered, " <>
      "#{length(result.evidence)} evidence)#{limits_note(result)}"
  end

  def describe(%Result{} = result) do
    "`#{result.mode}` #{verdict_word(result.status)} (#{length(result.findings)} finding(s)): " <>
      "#{findings_summary(result.findings)}#{limits_note(result)}"
  end

  @doc """
  Machine-readable view of the verdict, persisted so the next stage can consume the
  findings.

  The payload is **bounded by construction** (`@max_persisted_bytes`): it goes into
  a GitHub comment, which has a size limit, and the contract allows 256 evidence
  names with commands the project declares. A verdict above the cap is compacted —
  the evidence commands are dropped first, then the arrays are cut to what still
  fits — and the omitted counts say what was left out, so a consumer can tell a
  short verdict from a truncated one.
  """
  @spec summary_json(Result.t()) :: String.t()
  def summary_json(%Result{} = result) do
    json = Jason.encode!(result)

    if byte_size(json) <= @max_persisted_bytes do
      json
    else
      result |> compact_payload() |> Jason.encode!()
    end
  end

  defp compact_payload(%Result{} = result) do
    payload = %{
      status: result.status,
      contract_version: result.contract_version,
      mode: result.mode,
      findings: [],
      evidence: [],
      # The upper bounds are the totals on purpose: the payload measured while
      # items are added is never smaller than the one written at the end, so the
      # cap holds after the real counts replace them.
      omitted: %{findings: length(result.findings), evidence: length(result.evidence)},
      limits: result.limits,
      persisted: "compact: the full verdict exceeded #{@max_persisted_bytes} bytes"
    }

    {findings, omitted_findings, payload} = fit(result.findings, :findings, payload)

    # The evidence commands (project configuration, and the biggest part of the
    # payload) are the first thing dropped: the name and the status of what was
    # observed survive.
    {evidence, omitted_evidence, payload} =
      fit(Enum.map(result.evidence, &Map.take(&1, [:name, :status])), :evidence, payload)

    %{
      payload
      | findings: findings,
        evidence: evidence,
        omitted: %{findings: omitted_findings, evidence: omitted_evidence}
    }
  end

  # Items are added while the **encoded** payload still fits: the size is measured,
  # not estimated, so the guarantee is the size of the JSON that is really
  # persisted. The first item that does not fit and every item after it are counted
  # as omitted.
  defp fit(items, key, payload) do
    {kept, _omitted, payload} =
      Enum.reduce_while(items, {[], 0, payload}, fn item, {kept, omitted, payload} ->
        attempt = %{payload | key => kept ++ [item]}

        if byte_size(Jason.encode!(attempt)) <= @max_persisted_bytes do
          {:cont, {kept ++ [item], omitted, attempt}}
        else
          {:halt, {kept, omitted, payload}}
        end
      end)

    {kept, length(items) - length(kept), payload}
  end

  @doc "Marker of the persisted acceptance block of a candidate."
  @spec comment_marker(String.t()) :: String.t()
  def comment_marker(candidate_sha), do: "<!-- acceptance:result:#{candidate_sha} -->"

  @doc """
  The persisted acceptance block of the handoff comment: a marker plus the JSON
  of the verdict, so the findings survive the process and a later stage can read
  them without parsing prose.
  """
  @spec comment_block(Result.t(), String.t()) :: String.t()
  def comment_block(%Result{} = result, candidate_sha) do
    "#{comment_marker(candidate_sha)}\n```json\n#{summary_json(result)}\n```"
  end

  defp contract_of(%Issue{description: description}) do
    case PipelineContract.parse(description) do
      :absent -> {:ok, :absent}
      {:ok, contract} -> {:ok, contract}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scope_phase(workspace, contract) do
    with {:ok, changed} <- Git.change_set(workspace),
         {:ok, %{lines: lines, truncated: truncated}} <- Git.added_lines(workspace) do
      case changed do
        [] -> {:ok, result_not_applicable(contract)}
        _changed -> scope_result(contract, changed, lines, truncated) |> decide(:scope)
      end
    end
  end

  defp evidence_phase(workspace, contract, delivery) do
    case Git.change_set(workspace) do
      {:ok, []} -> {:ok, result_not_applicable(contract)}
      {:ok, _changed} -> evidence_result(contract, workspace, delivery) |> decide(:evidence)
      {:error, reason} -> {:error, reason}
    end
  end

  defp result_not_applicable(contract) do
    Result.not_applicable(mode: contract.scope_mode, contract_version: contract.version)
  end

  defp scope_result(contract, changed, lines, truncated) do
    paths = PipelineContract.path_findings(contract, Enum.map(changed, & &1.path))
    prohibitions = PipelineContract.prohibition_findings(contract, lines)

    Result.evaluated(
      mode: contract.scope_mode,
      contract_version: contract.version,
      findings: sanitize(paths.findings ++ prohibitions.findings),
      change_set: %{
        expected: paths.expected,
        delivered: paths.delivered,
        changed: paths.changed,
        unexpected: paths.unexpected
      },
      limits: limits(contract, truncated or paths.truncated or prohibitions.truncated)
    )
  end

  defp limits(contract, truncated) do
    heuristic = if PipelineContract.prohibition_scan?(contract), do: [:prohibition_scan_is_heuristic], else: []
    capped = if truncated, do: [:change_scan_truncated], else: []
    heuristic ++ capped ++ [:content_not_verified]
  end

  defp evidence_result(contract, workspace, delivery) do
    # The issue is untrusted input and may demand up to 256 evidences: the phase
    # has ONE deadline (`delivery.gates_timeout_ms`), not one per command, so a
    # contract cannot occupy a worker for hours by multiplying it.
    deadline = System.monotonic_time(:millisecond) + delivery.gates_timeout_ms

    {results, _deadline} =
      Enum.map_reduce(contract.required_evidence, deadline, &run_evidence(&1, workspace, delivery, &2))

    findings = results |> Enum.reject(&(&1.status == :passed)) |> Enum.map(&evidence_finding/1)

    Result.evaluated(
      mode: contract.scope_mode,
      contract_version: contract.version,
      findings: sanitize(findings),
      evidence: results,
      limits: [:content_not_verified]
    )
  end

  # The gates stage runs immediately before this phase, and reaching it means the
  # gates passed: the reserved name is the record of that layer, not a new command.
  defp run_evidence(@reserved_evidence, _workspace, delivery, deadline) do
    {%{name: @reserved_evidence, status: :passed, command: delivery.gates}, deadline}
  end

  defp run_evidence(name, workspace, delivery, deadline) do
    case Map.get(delivery.evidence, name) do
      nil -> {%{name: name, status: :missing_provider, command: nil}, deadline}
      command -> run_evidence_command(name, workspace, command, deadline)
    end
  end

  defp run_evidence_command(name, workspace, command, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("Delivery evidence skipped name=#{name} reason=evidence_phase_deadline")
      {%{name: name, status: :deadline_exceeded, command: command}, deadline}
    else
      run_with_budget(name, workspace, command, remaining, deadline)
    end
  end

  defp run_with_budget(name, workspace, command, remaining, deadline) do
    case Gates.run(workspace, command, remaining) do
      {:ok, _output} ->
        Logger.info("Delivery evidence passed name=#{name} command=#{inspect(command)}")
        {%{name: name, status: :passed, command: command}, deadline}

      {:error, {:command_failed, status, output}} ->
        Logger.warning("Delivery evidence failed name=#{name} status=#{status} output=#{inspect(Git.sanitize(output))}")
        {%{name: name, status: :failed, command: command}, deadline}

      {:error, {:command_timeout, timeout_ms}} ->
        Logger.warning("Delivery evidence timed out name=#{name} timeout_ms=#{timeout_ms}")
        {%{name: name, status: :timeout, command: command}, deadline}
    end
  end

  defp evidence_finding(%{name: name, status: :missing_provider}) do
    %Finding{
      code: :required_evidence_missing,
      category: :evidence,
      message: "required evidence `#{name}` has no provider in `delivery.evidence`"
    }
  end

  defp evidence_finding(%{name: name, status: :deadline_exceeded}) do
    %Finding{
      code: :required_evidence_failed,
      category: :evidence,
      message: "required evidence `#{name}` was not executed: the evidence phase budget was already spent"
    }
  end

  defp evidence_finding(%{name: name, status: status, command: command}) do
    %Finding{
      code: :required_evidence_failed,
      category: :evidence,
      message: "required evidence `#{name}` (`#{command}`) reported #{status}"
    }
  end

  defp decide(result, stage) do
    cond do
      result.status == :pass ->
        Logger.info("Delivery acceptance passed stage=#{stage} mode=#{result.mode} " <> verdict_log(result))
        {:ok, result}

      Result.blocking?(result) ->
        Logger.error("Delivery acceptance failed stage=#{stage} mode=#{result.mode || :unknown} " <> verdict_log(result))
        {:error, {:delivery_acceptance_failed, result}}

      true ->
        Logger.warning("Delivery acceptance diverged stage=#{stage} mode=advisory " <> verdict_log(result))
        {:ok, result}
    end
  end

  defp verdict_log(result) do
    "findings=#{length(result.findings)}#{limits_note(result)}"
  end

  defp verdict_word(:fail), do: "failed"
  defp verdict_word(_status), do: "diverged"

  defp findings_summary(findings) do
    details = findings |> Enum.take(@max_summary_findings) |> Enum.map_join("; ", &describe_finding/1)
    extra = length(findings) - @max_summary_findings

    if extra > 0, do: details <> " (+#{extra} more)", else: details
  end

  defp describe_finding(%Finding{message: message, path: nil}), do: message
  defp describe_finding(%Finding{message: message, path: path}), do: "#{message} [#{safe_text(path)}]"

  defp limits_note(%Result{limits: []}), do: ""

  defp limits_note(%Result{limits: limits}) do
    " [limits: #{Enum.map_join(limits, ", ", &limit_label/1)}]"
  end

  defp limit_label(:prohibition_scan_is_heuristic), do: "prohibition scan is heuristic, not a proof of absence"
  defp limit_label(:change_scan_truncated), do: "change scan truncated at the documented cap"
  defp limit_label(:content_not_verified), do: "content/quality not verified by this layer"

  # Findings carry text taken from the candidate (paths and added lines) and end up
  # in a log line and in a GitHub comment: credentials are masked, HTML is
  # neutralized (a change cannot rewrite the comment) and whitespace collapsed (a
  # newline cannot forge a log line). The `path` field stays literal for machine
  # consumers; the prose is the escaped one.
  defp sanitize(findings), do: Enum.map(findings, &%{&1 | message: safe_text(&1.message)})

  defp safe_text(text) do
    text
    |> Git.sanitize()
    |> String.replace("<", "&lt;")
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @comment_text_limit)
  end
end

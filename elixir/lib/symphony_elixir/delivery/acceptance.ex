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
  change set is read from the workspace, the required evidence is executed and
  the verdict is logged and reported in the handoff comment.

  Policy:

    * the acceptance is checked **before** anything is published: a `strict`
      finding fails the run, so no branch, no pull request and no label exist;
    * an `advisory` divergence is reported and the delivery continues — the
      architectural review decides (`ARCHITECT_PASS`/`REWORK`/`BLOCKED` is the
      next increment of the phase);
    * evidence is **named**: the issue demands names (`required_evidence`), the
      workflow provides the commands (`delivery.evidence`). The name
      `repository-gates` is reserved and is satisfied by the gates stage itself,
      which runs immediately before this phase;
    * there is no candidate change set to accept (a `--resume-only` cycle over an
      already published candidate, or nothing to publish): the report says
      `not_applicable` instead of failing, because the candidate being resumed was
      validated by the cycle that created it;
    * both phases read the change set from the workspace; the read is cheap, has
      no state and keeps the two phases independently testable.
  """

  require Logger

  alias SymphonyElixir.Delivery.{Gates, Git}
  alias SymphonyElixir.PipelineContract
  alias SymphonyElixir.Tracker.Issue

  @reserved_evidence "repository-gates"
  @max_summary_findings 3
  @severity %{absent: 0, not_applicable: 1, passed: 2, diverged: 3}

  @type status :: :absent | :not_applicable | :passed | :diverged

  @type evidence_result :: %{name: String.t(), status: atom(), command: String.t() | nil}

  @type report :: %{
          mode: :strict | :advisory | :absent,
          status: status(),
          paths: %{expected: [String.t()], delivered: [String.t()], changed: [String.t()], unauthorized: [String.t()]},
          evidence: [evidence_result()],
          violations: [PipelineContract.violation()],
          truncated: boolean()
        }

  @doc """
  The contract of the issue, read from its body.

  `{:ok, :absent}` means the issue declares no contract (the layer does not
  apply). A declared contract that cannot be enforced — unsupported version,
  unknown field, invalid pattern, invalid YAML — is an error: the delivery fails
  without publishing instead of ignoring a contract the pipeline does not
  understand.
  """
  @spec contract(Issue.t()) :: {:ok, :absent | PipelineContract.t()} | {:error, term()}
  def contract(%Issue{description: description}) do
    case PipelineContract.parse(description) do
      :absent -> {:ok, :absent}
      {:ok, contract} -> {:ok, contract}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Scope and prohibition findings of the candidate change set.

  Returns `{:error, {:delivery_acceptance_failed, report}}` when a `strict`
  contract has findings; in `advisory` the findings are reported and the delivery
  continues.
  """
  @spec scope(Path.t(), :absent | PipelineContract.t()) :: {:ok, report()} | {:error, term()}
  def scope(_workspace, :absent), do: {:ok, absent_report()}

  def scope(workspace, %PipelineContract{} = contract) do
    with {:ok, changed} <- Git.change_set(workspace),
         {:ok, %{lines: lines, truncated: truncated}} <- Git.added_lines(workspace) do
      case changed do
        [] -> {:ok, not_applicable_report(contract)}
        _changed -> decide(contract, scope_report(contract, changed, lines, truncated), :scope)
      end
    end
  end

  @doc """
  Evidence required by the contract for this candidate.

  Only the names demanded by the issue are executed: the workflow maps each name
  to a command (`delivery.evidence`) and a name without a provider is a finding.
  """
  @spec evidence(Path.t(), :absent | PipelineContract.t(), map()) :: {:ok, report()} | {:error, term()}
  def evidence(_workspace, :absent, _delivery), do: {:ok, absent_report()}

  def evidence(workspace, %PipelineContract{} = contract, delivery) do
    case Git.change_set(workspace) do
      {:ok, []} -> {:ok, not_applicable_report(contract)}
      {:ok, _changed} -> decide(contract, evidence_report(contract, workspace, delivery), :evidence)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Merges the two phases into the single acceptance report of the delivery."
  @spec summarize(report(), report()) :: report()
  def summarize(scope, evidence) do
    %{
      mode: scope.mode,
      status: worst_status(scope.status, evidence.status),
      paths: scope.paths,
      evidence: evidence.evidence,
      violations: scope.violations ++ evidence.violations,
      truncated: scope.truncated or evidence.truncated
    }
  end

  @doc "One-line, human-readable acceptance summary (log and handoff comment)."
  @spec describe(report()) :: String.t()
  def describe(%{status: :absent}), do: "not declared in the issue body"
  def describe(%{status: :not_applicable}), do: "not applicable (no candidate change set to accept)"

  def describe(%{mode: mode, status: :passed, paths: paths, evidence: evidence}) do
    "`#{mode}` passed (#{length(paths.delivered)}/#{length(paths.expected)} expected path(s) delivered, #{length(evidence)} evidence)"
  end

  def describe(%{mode: mode, violations: violations}) do
    "`#{mode}` diverged (#{length(violations)} finding(s)): " <> findings_summary(violations)
  end

  defp decide(contract, report, stage) do
    cond do
      report.violations == [] ->
        Logger.info("Delivery acceptance passed stage=#{stage} mode=#{report.mode}")
        {:ok, report}

      PipelineContract.strict?(contract) ->
        Logger.error("Delivery acceptance failed stage=#{stage} mode=strict findings=#{findings_summary(report.violations)}")
        {:error, {:delivery_acceptance_failed, report}}

      true ->
        Logger.warning("Delivery acceptance diverged stage=#{stage} mode=advisory findings=#{findings_summary(report.violations)}")
        {:ok, report}
    end
  end

  defp scope_report(contract, changed, lines, truncated) do
    paths = PipelineContract.path_findings(contract, Enum.map(changed, & &1.path))
    prohibitions = PipelineContract.prohibition_findings(contract, lines)
    violations = paths.violations ++ prohibitions.violations

    %{
      mode: contract.scope_mode,
      status: status(violations),
      paths: %{
        expected: paths.expected,
        delivered: paths.delivered,
        changed: paths.changed,
        unauthorized: paths.unauthorized
      },
      evidence: [],
      violations: sanitize(violations),
      truncated: paths.truncated or prohibitions.truncated or truncated
    }
  end

  defp evidence_report(contract, workspace, delivery) do
    results = Enum.map(contract.required_evidence, &run_evidence(&1, workspace, delivery))
    violations = results |> Enum.reject(&(&1.status == :passed)) |> Enum.map(&violation_of/1)

    %{
      mode: contract.scope_mode,
      status: status(violations),
      paths: %{expected: [], delivered: [], changed: [], unauthorized: []},
      evidence: results,
      violations: violations,
      truncated: false
    }
  end

  # The gates stage runs immediately before this phase, and reaching it means the
  # gates passed: the reserved name is the record of that layer, not a new command.
  defp run_evidence(@reserved_evidence, _workspace, delivery) do
    %{name: @reserved_evidence, status: :passed, command: delivery.gates}
  end

  defp run_evidence(name, workspace, delivery) do
    case Map.get(delivery.evidence, name) do
      nil -> %{name: name, status: :missing_provider, command: nil}
      command -> run_evidence_command(name, workspace, command, delivery)
    end
  end

  defp run_evidence_command(name, workspace, command, delivery) do
    case Gates.run(workspace, command, delivery.gates_timeout_ms) do
      {:ok, _output} ->
        Logger.info("Delivery evidence passed name=#{name} command=#{inspect(command)}")
        %{name: name, status: :passed, command: command}

      {:error, {:command_failed, status, output}} ->
        Logger.warning("Delivery evidence failed name=#{name} status=#{status} output=#{inspect(Git.sanitize(output))}")
        %{name: name, status: :failed, command: command}

      {:error, {:command_timeout, timeout_ms}} ->
        Logger.warning("Delivery evidence timed out name=#{name} timeout_ms=#{timeout_ms}")
        %{name: name, status: :timeout, command: command}
    end
  end

  defp violation_of(%{name: name, status: :missing_provider}) do
    %{kind: :missing_evidence_provider, detail: "required evidence `#{name}` has no provider in `delivery.evidence`"}
  end

  defp violation_of(%{name: name, status: status, command: command}) do
    %{kind: :evidence_not_passed, detail: "required evidence `#{name}` (`#{command}`) reported #{status}"}
  end

  defp status([]), do: :passed
  defp status(_violations), do: :diverged

  defp worst_status(left, right) do
    if Map.fetch!(@severity, left) >= Map.fetch!(@severity, right), do: left, else: right
  end

  # The findings end up in a log line and in a GitHub comment: the details carry a
  # snippet of the candidate's own lines, so they are masked the same way the git
  # output is.
  defp sanitize(violations), do: Enum.map(violations, &%{&1 | detail: Git.sanitize(&1.detail)})

  defp findings_summary(violations) do
    details = violations |> Enum.take(@max_summary_findings) |> Enum.map_join("; ", & &1.detail)
    extra = length(violations) - @max_summary_findings

    if extra > 0, do: details <> " (+#{extra} more)", else: details
  end

  defp absent_report do
    %{mode: :absent, status: :absent, paths: empty_paths(), evidence: [], violations: [], truncated: false}
  end

  defp not_applicable_report(contract) do
    %{
      mode: contract.scope_mode,
      status: :not_applicable,
      paths: empty_paths(),
      evidence: [],
      violations: [],
      truncated: false
    }
  end

  defp empty_paths, do: %{expected: [], delivered: [], changed: [], unauthorized: []}
end

defmodule SymphonyElixir.Delivery.AcceptanceTest do
  @moduledoc """
  The acceptance gate over a real (and disposable) git workspace: the change set
  is read from git, the evidence commands really run and the verdict of each mode
  is asserted without network, GitHub or credential.
  """

  # Sync, like the delivery suite: real git and shell commands are heavy and the
  # orchestrator retry assertions of `core_test.exs` are timing-sensitive.
  use ExUnit.Case

  alias SymphonyElixir.Delivery.Acceptance
  alias SymphonyElixir.PipelineContract
  alias SymphonyElixir.Tracker.Issue

  @issue %Issue{
    id: "7",
    identifier: "SMOKE-7",
    title: "Change answer.sh so it prints exactly 42",
    description: "Deterministic disposable task.",
    state: "open",
    labels: []
  }

  @delivery %{gates: "true", gates_timeout_ms: 5_000, evidence: %{}}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-acceptance-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-q", "-b", "main"])
    write!(workspace, "README.md", "base\n")
    git!(workspace, ["add", "-A"])
    git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-q", "-m", "base"])

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace}
  end

  describe "contract/1" do
    test "an issue without a contract is not enforced" do
      assert Acceptance.contract(@issue) == {:ok, :absent}
      assert Acceptance.contract(%{@issue | description: nil}) == {:ok, :absent}
    end

    test "the contract is read from the issue body" do
      assert {:ok, %PipelineContract{scope_mode: :strict}} = Acceptance.contract(issue(contract_body([])))
    end

    test "a contract that cannot be enforced is an error, not a guess" do
      assert {:error, {:pipeline_contract_invalid, {:unsupported_version, 9}}} =
               Acceptance.contract(issue(contract_body(version: 9)))
    end
  end

  describe "scope/2" do
    test "no contract means no acceptance layer to apply", %{workspace: workspace} do
      assert {:ok, report} = Acceptance.scope(workspace, :absent)
      assert report.status == :absent
      assert report.mode == :absent
      assert Acceptance.describe(report) == "not declared in the issue body"
    end

    test "a candidate that delivers every expected path passes", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)

      assert report.status == :passed
      assert report.mode == :strict
      assert report.violations == []
      assert report.paths.delivered == ["README.md"]
      assert report.paths.unauthorized == []
      refute report.truncated

      assert Acceptance.describe(report) == "`strict` passed (1/1 expected path(s) delivered, 0 evidence)"
    end

    test "a scope divergence blocks a strict candidate before anything is published", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "notes.md", "extra\n")

      {:ok, contract} = pipeline_contract(contract_body(expected_paths: ["docs/changes/smoke.md", "tests/run-tests.sh"]))

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.scope(workspace, contract)

      assert report.status == :diverged

      assert Enum.map(report.violations, & &1.kind) ==
               [:expected_path_untouched, :expected_path_untouched, :unauthorized_path, :unauthorized_path]

      assert report.paths.changed == ["README.md", "notes.md"]
      assert report.paths.unauthorized == ["README.md", "notes.md"]

      # The gate never writes: no commit, no branch, no push.
      assert {" M README.md\n?? notes.md\n", 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace)
      assert {"1\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: workspace)
    end

    test "the same divergence is reported, not blocking, in advisory mode", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      {:ok, contract} =
        pipeline_contract(contract_body(scope_mode: "advisory", expected_paths: ["docs/x.md"], allowed_extra_paths: ["README.md"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)

      assert report.status == :diverged
      assert report.mode == :advisory
      assert [%{kind: :expected_path_untouched}] = report.violations
      assert Acceptance.describe(report) =~ "advisory` diverged (1 finding(s))"
    end

    test "an expected path inside a directory the agent created is delivered", %{workspace: workspace} do
      write!(workspace, "docs/changes/2026-09-30-x.md", "smoke\n")
      {:ok, contract} = pipeline_contract(contract_body(expected_paths: ["docs/changes/2026-09-30-x.md"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
    end

    test "a rename is the destination path, not the origin", %{workspace: workspace} do
      git!(workspace, ["mv", "README.md", "docs.md"])
      {:ok, contract} = pipeline_contract(contract_body(expected_paths: ["docs.md"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
      assert report.paths.changed == ["docs.md"]
    end

    test "a deleted file is delivered by its removal and adds no line", %{workspace: workspace} do
      File.rm!(Path.join(workspace, "README.md"))
      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
      assert report.paths.changed == ["README.md"]
    end

    test "a path with a space is matched as it is", %{workspace: workspace} do
      write!(workspace, "docs/with space.md", "smoke\n")
      {:ok, contract} = pipeline_contract(contract_body(expected_paths: ["docs/with space.md"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
    end

    test "no candidate change set is not a failure", %{workspace: workspace} do
      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)

      assert report.status == :not_applicable
      assert report.mode == :strict
      assert report.violations == []
      assert Acceptance.describe(report) =~ "not applicable"
    end

    test "a deploy command added by the candidate is a prohibition finding", %{workspace: workspace} do
      write!(workspace, "scripts/deploy.sh", "#!/bin/sh\nkubectl apply -f k8s/site.yml\n")
      {:ok, contract} = pipeline_contract(contract_body(expected_paths: ["scripts/deploy.sh"]))

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.scope(workspace, contract)

      assert [%{kind: :deploy, detail: detail}] = report.violations
      assert detail =~ "kubectl change in scripts/deploy.sh"
    end

    test "remote access added to a tracked file is found in the diff", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nDeploy instructions: ssh prod.example.com\n")
      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.scope(workspace, contract)

      assert [%{kind: :remote_access, detail: detail}] = report.violations
      assert detail =~ "ssh/scp/sftp invocation in README.md"
    end

    test "an authorization in the contract turns the prohibition off", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nssh prod.example.com\n")
      {:ok, contract} = pipeline_contract(contract_body(remote_access: true, deploy: true))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
    end

    test "a credential in a finding is masked, never published", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nssh host -o gho_secretvalue12345\n")
      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.scope(workspace, contract)
      assert [%{detail: detail}] = report.violations
      refute detail =~ "secretvalue12345"
      assert detail =~ "gho_***"
    end

    test "an untracked binary is skipped instead of crashing the scan", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      File.write!(Path.join(workspace, "logo.bin"), <<0xFF, 0xFE, 0x00, 0x01>>)
      File.write!(Path.join(workspace, "empty.txt"), "")
      {:ok, contract} = pipeline_contract(contract_body(allowed_extra_paths: ["logo.bin", "empty.txt"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
    end

    test "an unreadable untracked file is skipped instead of crashing the scan", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      path = Path.join(workspace, "secret.txt")
      File.write!(path, "ssh prod\n")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)
      {:ok, contract} = pipeline_contract(contract_body(allowed_extra_paths: ["secret.txt"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
    end

    test "a candidate bigger than the scan limit says so", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "big.md", String.duplicate("line\n", 2_100))
      {:ok, contract} = pipeline_contract(contract_body(allowed_extra_paths: ["big.md"]))

      assert {:ok, report} = Acceptance.scope(workspace, contract)
      assert report.status == :passed
      assert report.truncated
    end

    test "a broken workspace is reported instead of guessed" do
      not_a_repo = Path.join(System.tmp_dir!(), "symphony-acceptance-not-a-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:error, {:git_command_failed, _args, _status, _output}} = Acceptance.scope(not_a_repo, contract)
    end
  end

  describe "evidence/3" do
    test "no contract means no evidence is demanded", %{workspace: workspace} do
      assert {:ok, report} = Acceptance.evidence(workspace, :absent, @delivery)
      assert report.status == :absent
    end

    test "no candidate change set runs no evidence command", %{workspace: workspace} do
      {:ok, contract} = pipeline_contract(contract_body(required_evidence: ["side-effect"]))

      delivery = %{@delivery | evidence: %{"side-effect" => "echo ran > side-effect.txt"}}

      assert {:ok, report} = Acceptance.evidence(workspace, contract, delivery)
      assert report.status == :not_applicable
      assert report.evidence == []
      refute File.exists?(Path.join(workspace, "side-effect.txt"))
    end

    test "the reserved `repository-gates` evidence is the gates stage itself", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      {:ok, contract} = pipeline_contract(contract_body(required_evidence: ["repository-gates"]))

      assert {:ok, report} = Acceptance.evidence(workspace, contract, @delivery)

      assert report.status == :passed
      assert [%{name: "repository-gates", status: :passed, command: "true"}] = report.evidence
    end

    test "an evidence provider really runs, inside the workspace", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      {:ok, contract} = pipeline_contract(contract_body(required_evidence: ["agent-tests"]))

      delivery = %{@delivery | evidence: %{"agent-tests" => "test -f README.md && echo ran > evidence.txt"}}

      assert {:ok, report} = Acceptance.evidence(workspace, contract, delivery)

      assert report.status == :passed
      assert [%{name: "agent-tests", status: :passed}] = report.evidence
      assert File.read!(Path.join(workspace, "evidence.txt")) == "ran\n"
      assert Acceptance.describe(report) =~ "1 evidence"
    end

    test "a red evidence blocks a strict candidate and is only reported in advisory", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      delivery = %{@delivery | evidence: %{"agent-tests" => "echo boom >&2 && exit 3"}}

      {:ok, strict} = pipeline_contract(contract_body(required_evidence: ["agent-tests"]))

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.evidence(workspace, strict, delivery)

      assert [%{kind: :evidence_not_passed, detail: detail}] = report.violations
      assert detail == "required evidence `agent-tests` (`echo boom >&2 && exit 3`) reported failed"

      {:ok, advisory} =
        pipeline_contract(contract_body(scope_mode: "advisory", required_evidence: ["agent-tests"]))

      assert {:ok, report} = Acceptance.evidence(workspace, advisory, delivery)
      assert report.status == :diverged
      assert [%{status: :failed}] = report.evidence
    end

    test "an evidence without a provider is a finding, never a silent pass", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      {:ok, contract} = pipeline_contract(contract_body(required_evidence: ["wordpress-tests"]))

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.evidence(workspace, contract, @delivery)

      assert [%{kind: :missing_evidence_provider, detail: detail}] = report.violations
      assert detail == "required evidence `wordpress-tests` has no provider in `delivery.evidence`"
      assert [%{status: :missing_provider, command: nil}] = report.evidence
    end

    test "an evidence that never finishes is a timeout, not a hang", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      {:ok, contract} = pipeline_contract(contract_body(required_evidence: ["slow-tests"]))

      delivery = %{@delivery | gates_timeout_ms: 50, evidence: %{"slow-tests" => "sleep 5"}}

      assert {:error, {:delivery_acceptance_failed, report}} = Acceptance.evidence(workspace, contract, delivery)

      assert [%{kind: :evidence_not_passed, detail: detail}] = report.violations
      assert detail =~ "reported timeout"
      assert [%{status: :timeout}] = report.evidence
    end

    test "a broken workspace is reported instead of guessed" do
      not_a_repo = Path.join(System.tmp_dir!(), "symphony-acceptance-evidence-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      {:ok, contract} = pipeline_contract(contract_body([]))

      assert {:error, {:git_command_failed, _args, _status, _output}} =
               Acceptance.evidence(not_a_repo, contract, @delivery)
    end
  end

  describe "summarize/2 and describe/1" do
    test "the worst status wins and both phases are reported together" do
      scope = report(:strict, :passed, [], [])
      evidence = report(:strict, :passed, [], [%{name: "agent-tests", status: :passed, command: "true"}])

      summary = Acceptance.summarize(scope, evidence)

      assert summary.status == :passed
      assert [%{name: "agent-tests"}] = summary.evidence
      assert Acceptance.describe(summary) == "`strict` passed (1/1 expected path(s) delivered, 1 evidence)"

      diverged = %{scope | status: :diverged, violations: [%{kind: :unauthorized_path, detail: "outside"}]}

      assert Acceptance.summarize(diverged, evidence).status == :diverged
      assert Acceptance.summarize(scope, %{evidence | status: :diverged}).status == :diverged

      assert Acceptance.summarize(%{scope | truncated: true}, evidence).truncated
    end

    test "a long list of findings is summarized instead of dumped" do
      violations = Enum.map(1..5, &%{kind: :unauthorized_path, detail: "finding #{&1}"})

      described = Acceptance.describe(%{report(:advisory, :diverged, violations, []) | violations: violations})

      assert described =~ "advisory` diverged (5 finding(s)): finding 1; finding 2; finding 3 (+2 more)"
    end

    test "an absent or not applicable layer says so" do
      assert Acceptance.describe(report(:absent, :absent, [], [])) == "not declared in the issue body"
      assert Acceptance.describe(report(:strict, :not_applicable, [], [])) =~ "not applicable"
    end
  end

  defp report(mode, status, violations, evidence) do
    %{
      mode: mode,
      status: status,
      paths: %{expected: ["docs/x.md"], delivered: ["docs/x.md"], changed: ["docs/x.md"], unauthorized: []},
      evidence: evidence,
      violations: violations,
      truncated: false
    }
  end

  defp issue(description), do: %{@issue | description: description}

  defp pipeline_contract(body), do: PipelineContract.parse(body)

  defp contract_body(options) do
    [
      "```yaml",
      "pipeline_contract:",
      "  version: #{Keyword.get(options, :version, 1)}",
      "  scope_mode: #{Keyword.get(options, :scope_mode, "strict")}",
      "  expected_paths: #{yaml_list(Keyword.get(options, :expected_paths, ["README.md"]))}",
      "  allowed_extra_paths: #{yaml_list(Keyword.get(options, :allowed_extra_paths, []))}",
      "  required_evidence: #{yaml_list(Keyword.get(options, :required_evidence, []))}",
      "  remote_access: #{Keyword.get(options, :remote_access, false)}",
      "  deploy: #{Keyword.get(options, :deploy, false)}",
      "```"
    ]
    |> Enum.join("\n")
  end

  defp yaml_list(values), do: "[" <> Enum.map_join(values, ", ", &"\"#{&1}\"") <> "]"

  defp write!(workspace, path, content) do
    absolute = Path.join(workspace, path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end

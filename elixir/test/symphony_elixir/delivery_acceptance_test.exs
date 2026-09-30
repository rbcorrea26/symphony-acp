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
  alias SymphonyElixir.Delivery.Acceptance.Result
  alias SymphonyElixir.Delivery.Git
  alias SymphonyElixir.PipelineContract.Finding
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

  describe "scope/2" do
    test "an issue without a contract is not configured, not implicitly strict", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      assert {:ok, result} = Acceptance.scope(workspace, @issue)

      assert %Result{status: :not_configured, mode: nil, contract_version: nil, findings: []} = result
      refute Result.blocking?(result)
      assert Acceptance.describe(result) =~ "acceptance not configured"
    end

    test "a candidate that delivers every expected path passes", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      assert {:ok, result} = Acceptance.scope(workspace, issue(contract_body([])))

      assert %Result{status: :pass, mode: :strict, contract_version: 1, findings: []} = result
      assert result.change_set.delivered == ["README.md"]
      assert result.change_set.unexpected == []
      assert result.limits == [:prohibition_scan_is_heuristic, :content_not_verified]

      assert Acceptance.describe(result) ==
               "`strict` passed (1/1 expected path(s) delivered, 0 evidence) [limits: prohibition scan is heuristic, " <>
                 "not a proof of absence, content/quality not verified by this layer]"
    end

    test "a strict divergence blocks before anything is published", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "notes.md", "extra\n")

      issue = issue(contract_body(expected_paths: ["docs/changes/smoke.md", "tests/run-tests.sh"]))

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue)

      assert %Result{status: :fail, mode: :strict} = result

      assert Enum.map(result.findings, & &1.code) == [
               :expected_path_missing,
               :expected_path_missing,
               :unexpected_path_changed,
               :unexpected_path_changed
             ]

      assert result.change_set.changed == ["README.md", "notes.md"]
      assert result.change_set.unexpected == ["README.md", "notes.md"]

      # The gate never writes: no commit, no branch, no push.
      assert {" M README.md\n?? notes.md\n", 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace)
      assert {"1\n", 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: workspace)
    end

    test "the same divergence is reported, not blocking, in advisory mode", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      issue =
        issue(contract_body(scope_mode: "advisory", expected_paths: ["docs/x.md"], allowed_extra_paths: ["README.md"]))

      assert {:ok, result} = Acceptance.scope(workspace, issue)

      assert %Result{status: :advisory, mode: :advisory} = result
      assert [%Finding{code: :expected_path_missing, category: :scope, path: "docs/x.md"}] = result.findings
      refute Result.blocking?(result)
      assert Acceptance.describe(result) =~ "advisory` diverged (1 finding(s))"
    end

    test "an expected path inside a directory the agent created is delivered", %{workspace: workspace} do
      write!(workspace, "docs/changes/2026-09-30-x.md", "smoke\n")
      issue = issue(contract_body(expected_paths: ["docs/changes/2026-09-30-x.md"]))

      assert {:ok, %Result{status: :pass}} = Acceptance.scope(workspace, issue)
    end

    test "an expected path that exists in the base but is not delivered is a finding", %{workspace: workspace} do
      write!(workspace, "docs.md", "new file\n")
      issue = issue(contract_body(expected_paths: ["README.md", "docs.md"]))

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue)

      assert Enum.map(result.findings, &{&1.code, &1.path}) == [{:expected_path_missing, "README.md"}]
      assert result.change_set.delivered == ["docs.md"]
    end

    test "a rename delivers the destination and reports the origin as a deletion", %{workspace: workspace} do
      git!(workspace, ["mv", "README.md", "docs.md"])

      # Only the destination is authorized: the rename **removed** README.md, so
      # authorizing the new path is not authorizing the deletion of the old one.
      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body(expected_paths: ["docs.md"])))

      assert Enum.map(result.findings, &{&1.code, &1.path}) == [{:unexpected_path_changed, "README.md"}]
      assert result.change_set.changed == ["docs.md", "README.md"]
      assert result.change_set.unexpected == ["README.md"]

      # Both ends authorized: the rename is the delivery.
      issue = issue(contract_body(expected_paths: ["docs.md", "README.md"]))

      assert {:ok, result} = Acceptance.scope(workspace, issue)
      assert result.status == :pass
      assert result.change_set.delivered == ["docs.md", "README.md"]
    end

    test "an added line with invalid UTF-8 in the diff is skipped, not crashed", %{workspace: workspace} do
      # No NUL byte, so git treats the file as text and the added line arrives raw.
      write!(workspace, "latin.txt", <<"a", 0xE9, "\n">>)
      git!(workspace, ["add", "-A"])
      git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-q", "-m", "text"])
      write!(workspace, "latin.txt", <<"b", 0xE9, "\n">>)
      write!(workspace, "README.md", "base\nmore\n")

      issue = issue(contract_body(allowed_extra_paths: ["latin.txt"]))

      assert {:ok, result} = Acceptance.scope(workspace, issue)
      assert result.status == :pass
      assert result.findings == []
    end

    test "an added line that looks like a diff header is content, not a header", %{workspace: workspace} do
      write!(workspace, "docs/run.sh", "#!/bin/sh\n")
      git!(workspace, ["add", "-A"])

      git!(workspace, [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.org",
        "commit",
        "-q",
        "-m",
        "add script"
      ])

      # The added line `++ b/decoy.sh` arrives in the diff as `+++ b/decoy.sh`: read as
      # a file header it would be dropped from the scan and would steal the path of
      # every line after it.
      write!(workspace, "docs/run.sh", "#!/bin/sh\n++ b/decoy.sh\nssh prod.example.com\n")

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body(expected_paths: ["docs/run.sh"])))

      assert [%Finding{code: :forbidden_remote_access_detected, path: "docs/run.sh"}] = result.findings
    end

    test "a deletion is delivered by its removal and adds no line", %{workspace: workspace} do
      File.rm!(Path.join(workspace, "README.md"))

      assert {:ok, result} = Acceptance.scope(workspace, issue(contract_body([])))
      assert result.status == :pass
      assert result.change_set.changed == ["README.md"]
    end

    test "a path with a space is matched as it is", %{workspace: workspace} do
      write!(workspace, "docs/with space.md", "smoke\n")
      issue = issue(contract_body(expected_paths: ["docs/with space.md"]))

      assert {:ok, %Result{status: :pass}} = Acceptance.scope(workspace, issue)
    end

    test "no candidate change set is not a failure", %{workspace: workspace} do
      assert {:ok, result} = Acceptance.scope(workspace, issue(contract_body([])))

      assert %Result{status: :not_applicable, mode: :strict, findings: []} = result
      refute Result.blocking?(result)
      assert Acceptance.describe(result) =~ "not applicable"
    end

    test "an unenforceable contract fails as a structured finding", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body(version: 9)))

      assert %Result{status: :fail, mode: nil, contract_version: nil} = result
      assert [%Finding{code: :invalid_contract, category: :contract}] = result.findings
      assert hd(result.findings).message =~ "unsupported_version"
      assert Acceptance.describe(result) =~ "failed (1 finding(s))"
    end

    test "a deploy command added by the candidate is a prohibition finding", %{workspace: workspace} do
      write!(workspace, "scripts/deploy.sh", "#!/bin/sh\nkubectl apply -f k8s/site.yml\n")
      issue = issue(contract_body(expected_paths: ["scripts/deploy.sh"]))

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue)

      assert [%Finding{code: :forbidden_deploy_detected, path: "scripts/deploy.sh"}] = result.findings
      assert hd(result.findings).message =~ "kubectl change"
    end

    test "remote access added to a tracked file is found in the diff", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nDeploy instructions: ssh prod.example.com\n")

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue(contract_body([])))

      assert [%Finding{code: :forbidden_remote_access_detected, path: "README.md"}] = result.findings
    end

    test "an authorization in the contract turns the prohibition off", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nssh prod.example.com\n")

      assert {:ok, result} = Acceptance.scope(workspace, issue(contract_body(remote_access: true, deploy: true)))

      assert result.status == :pass
      assert result.limits == [:content_not_verified]
    end

    test "a credential in a finding is masked, never published", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nssh host -o gho_secretvalue12345\n")

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue(contract_body([])))

      assert [%Finding{message: message}] = result.findings
      refute message =~ "secretvalue12345"
      assert message =~ "gho_***"
    end

    test "a candidate finding cannot inject markup into the comment", %{workspace: workspace} do
      write!(workspace, "README.md", "base\n\nssh host <!-- delivery:candidate:deadbeef --> <h1>x</h1>\n")

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue(contract_body([])))

      assert [%Finding{message: message}] = result.findings
      refute message =~ "<!--"
      assert message =~ "&lt;!--"
    end

    test "an untracked binary and an empty file are skipped without making the scan partial", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      File.write!(Path.join(workspace, "logo.bin"), <<0xFF, 0xFE, 0x00, 0x01>>)
      File.write!(Path.join(workspace, "empty.txt"), "")

      issue = issue(contract_body(allowed_extra_paths: ["logo.bin", "empty.txt"]))

      assert {:ok, %Result{status: :pass, findings: []} = result} = Acceptance.scope(workspace, issue)
      refute :change_scan_truncated in result.limits
    end

    test "an untracked regular file that cannot be read makes the scan partial", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      path = Path.join(workspace, "secret.txt")
      File.write!(path, "ssh prod\n")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)

      # The suite runs as a regular user (root would read the file): what is asserted
      # is the fail-closed behavior of the scan, not the permission model.
      assert {:error, :eacces} = File.read(path)

      issue = issue(contract_body(allowed_extra_paths: ["secret.txt"]))

      # A hole in the scan is not a complete scan: the file may hold a prohibition the
      # layer cannot see, so a strict contract fails instead of passing.
      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue)

      assert result.status == :fail
      assert [%Finding{code: :prohibition_scan_truncated}] = result.findings
      assert :change_scan_truncated in result.limits
    end

    test "a symlink is not followed by the scan", %{workspace: workspace} do
      outside = Path.join(Path.dirname(workspace), "outside-secret.txt")
      File.write!(outside, "ssh prod.example.com\n")
      File.ln_s!(outside, Path.join(workspace, "link.txt"))
      write!(workspace, "README.md", "base\nmore\n")

      issue = issue(contract_body(allowed_extra_paths: ["link.txt"]))

      assert {:ok, %Result{status: :pass, findings: []}} = Acceptance.scope(workspace, issue)
    end

    test "a candidate bigger than the scan limit fails closed in strict mode", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "big.md", String.duplicate("line\n", 2_100))

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body(allowed_extra_paths: ["big.md"])))

      # A partial scan cannot certify the absence of a prohibition: the strict
      # contract fails instead of passing on a read that stopped at its cap, and the
      # limit is still declared.
      assert result.status == :fail
      assert [%Finding{code: :prohibition_scan_truncated, category: :forbidden_operation}] = result.findings
      assert :change_scan_truncated in result.limits
      assert Acceptance.describe(result) =~ "change scan truncated"
      assert Acceptance.describe(result) =~ "cannot be certified over a partial scan"
    end

    test "the same truncated scan diverges in advisory mode instead of blocking", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "big.md", String.duplicate("line\n", 2_100))

      issue =
        issue(contract_body(scope_mode: "advisory", allowed_extra_paths: ["big.md"]))

      assert {:ok, result} = Acceptance.scope(workspace, issue)

      assert result.status == :advisory
      assert [%Finding{code: :prohibition_scan_truncated}] = result.findings
      assert :change_scan_truncated in result.limits
      refute Result.blocking?(result)
    end

    test "a truncated scan with both prohibitions authorized is a limit, not a finding", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "big.md", String.duplicate("line\n", 2_100))

      issue = issue(contract_body(allowed_extra_paths: ["big.md"], remote_access: true, deploy: true))

      assert {:ok, result} = Acceptance.scope(workspace, issue)

      assert result.status == :pass
      assert result.findings == []
      assert :change_scan_truncated in result.limits
    end

    test "more untracked files than the scan limit fails closed in strict mode", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      Enum.each(1..201, fn index -> write!(workspace, "many/file-#{index}.js", "x\n") end)

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body(allowed_extra_paths: ["many/**"])))

      assert result.status == :fail
      assert [%Finding{code: :prohibition_scan_truncated}] = result.findings
      assert :change_scan_truncated in result.limits
    end

    test "an untracked file bigger than the per-file limit fails closed in strict mode", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "big.md", String.duplicate("y\n", 200_000))

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body(allowed_extra_paths: ["big.md"])))

      assert result.status == :fail
      assert [%Finding{code: :prohibition_scan_truncated}] = result.findings
      assert :change_scan_truncated in result.limits
    end

    test "a tracked diff bigger than the parse limit fails closed in strict mode", %{workspace: workspace} do
      write!(workspace, "README.md", String.duplicate("x\n", 600_000))

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.scope(workspace, issue(contract_body([])))

      assert result.status == :fail
      assert Enum.map(result.findings, & &1.code) == [:prohibition_scan_truncated]
      assert :change_scan_truncated in result.limits
    end

    test "a tracked diff above the byte budget is read bounded, not captured whole", %{workspace: workspace} do
      write!(workspace, "big.txt", "base\n")
      git!(workspace, ["add", "-A"])

      git!(workspace, [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.org",
        "commit",
        "-q",
        "-m",
        "base big"
      ])

      # ~1.5 MiB of diff in 500 added lines: above the byte budget of the read and
      # below the line budget of the parse, so the truncation can only come from the
      # read that stops at the cap (and kills the child).
      write!(workspace, "big.txt", Enum.map_join(1..500, "\n", &("line #{&1} " <> String.duplicate("x", 3_000))) <> "\n")

      assert {:ok, %{lines: lines, truncated: true}} = Git.added_lines(workspace)

      assert length(lines) < 500
      assert Enum.all?(lines, &(&1.path == "big.txt"))
    end

    test "markup in a path is escaped in the prose and kept literal for machines", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      write!(workspace, "ev<il>.md", "x\n")

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.scope(workspace, issue(contract_body([])))

      assert [%Finding{code: :unexpected_path_changed, path: "ev<il>.md"}] = result.findings
      assert result.findings |> hd() |> Map.fetch!(:path) == "ev<il>.md"

      described = Acceptance.describe(result)
      refute described =~ "ev<il>.md"
      assert described =~ "ev&lt;il>.md"
      assert Acceptance.summary_json(result) =~ "ev<il>.md"
    end

    test "the same candidate always produces the same verdict", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      issue = issue(contract_body([]))

      assert {:ok, first} = Acceptance.scope(workspace, issue)
      assert {:ok, second} = Acceptance.scope(workspace, issue)

      assert first == second
    end

    test "a broken workspace is reported instead of guessed" do
      not_a_repo = Path.join(System.tmp_dir!(), "symphony-acceptance-not-a-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      assert {:error, {:git_command_failed, _args, _status, _output}} =
               Acceptance.scope(not_a_repo, issue(contract_body([])))
    end

    test "a change set with a non-UTF-8 path fails closed instead of crashing", %{workspace: workspace} do
      File.write!(Path.join(workspace, <<"bad", 0xFF, ".txt">>), "x\n")

      assert {:error, {:change_set_not_utf8, :rejected}} = Acceptance.scope(workspace, issue(contract_body([])))
    end

    test "a change set above the cap fails closed instead of being partially accepted", %{workspace: workspace} do
      Enum.each(1..5_001, fn index -> write!(workspace, "many/file-#{index}.txt", "x\n") end)

      assert {:error, {:change_set_too_large, 5_000}} = Acceptance.scope(workspace, issue(contract_body([])))
    end
  end

  describe "evidence/3" do
    test "an issue without a contract demands no evidence", %{workspace: workspace} do
      assert {:ok, %Result{status: :not_configured}} = Acceptance.evidence(workspace, @issue, @delivery)
    end

    test "an unenforceable contract fails the evidence phase too", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      assert {:error, {:delivery_acceptance_failed, result}} =
               Acceptance.evidence(workspace, issue(contract_body(version: 9)), @delivery)

      assert [%Finding{code: :invalid_contract}] = result.findings
    end

    test "no candidate change set runs no evidence command", %{workspace: workspace} do
      issue = issue(contract_body(required_evidence: ["side-effect"]))
      delivery = %{@delivery | evidence: %{"side-effect" => "echo ran > side-effect.txt"}}

      assert {:ok, result} = Acceptance.evidence(workspace, issue, delivery)
      assert result.status == :not_applicable
      assert result.evidence == []
      refute File.exists?(Path.join(workspace, "side-effect.txt"))
    end

    test "the reserved `repository-gates` evidence is the gates stage itself", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      issue = issue(contract_body(required_evidence: ["repository-gates"]))

      assert {:ok, result} = Acceptance.evidence(workspace, issue, @delivery)

      assert result.status == :pass
      assert [%{name: "repository-gates", status: :passed, command: "true"}] = result.evidence
    end

    test "an evidence provider really runs, inside the workspace", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      issue = issue(contract_body(required_evidence: ["agent-tests"]))

      delivery = %{@delivery | evidence: %{"agent-tests" => "test -f README.md && echo ran > evidence.txt"}}

      assert {:ok, result} = Acceptance.evidence(workspace, issue, delivery)

      assert result.status == :pass
      assert [%{name: "agent-tests", status: :passed}] = result.evidence
      assert File.read!(Path.join(workspace, "evidence.txt")) == "ran\n"
      assert Acceptance.describe(result) =~ "1 evidence"
    end

    test "a red evidence blocks a strict candidate and is only reported in advisory", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      delivery = %{@delivery | evidence: %{"agent-tests" => "echo boom >&2 && exit 3"}}

      strict = issue(contract_body(required_evidence: ["agent-tests"]))

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.evidence(workspace, strict, delivery)

      assert [%Finding{code: :required_evidence_failed, category: :evidence, path: nil}] = result.findings

      assert hd(result.findings).message ==
               "required evidence `agent-tests` (`echo boom >&2 && exit 3`) reported failed"

      advisory = issue(contract_body(scope_mode: "advisory", required_evidence: ["agent-tests"]))

      assert {:ok, result} = Acceptance.evidence(workspace, advisory, delivery)
      assert result.status == :advisory
      assert [%{status: :failed}] = result.evidence
    end

    test "an evidence without a provider is a finding, never a silent pass", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      issue = issue(contract_body(required_evidence: ["wordpress-tests"]))

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.evidence(workspace, issue, @delivery)

      assert [%Finding{code: :required_evidence_missing, category: :evidence}] = result.findings
      assert hd(result.findings).message =~ "has no provider in `delivery.evidence`"
      assert [%{status: :missing_provider, command: nil}] = result.evidence
    end

    test "an evidence that never finishes is a timeout, not a hang", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      issue = issue(contract_body(required_evidence: ["slow-tests"]))

      delivery = %{@delivery | gates_timeout_ms: 50, evidence: %{"slow-tests" => "sleep 5"}}

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.evidence(workspace, issue, delivery)

      assert [%Finding{code: :required_evidence_failed, message: message}] = result.findings
      assert message =~ "reported timeout"
      assert [%{status: :timeout}] = result.evidence
    end

    test "the evidence phase has one budget, not one budget per command", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")

      # The issue is untrusted input: 256 evidences multiplied by the per-command
      # timeout would occupy the worker for hours, so the phase has one deadline.
      issue = issue(contract_body(required_evidence: ["slow-tests", "agent-tests"]))

      delivery = %{
        @delivery
        | gates_timeout_ms: 50,
          evidence: %{"slow-tests" => "sleep 5", "agent-tests" => "true"}
      }

      assert {:error, {:delivery_acceptance_failed, result}} = Acceptance.evidence(workspace, issue, delivery)

      assert [%{name: "slow-tests", status: :timeout}, %{name: "agent-tests", status: :deadline_exceeded}] =
               result.evidence

      assert Enum.map(result.findings, & &1.message) == [
               "required evidence `slow-tests` (`sleep 5`) reported timeout",
               "required evidence `agent-tests` was not executed: the evidence phase budget was already spent"
             ]
    end

    test "the same candidate always produces the same evidence verdict", %{workspace: workspace} do
      write!(workspace, "README.md", "base\nmore\n")
      issue = issue(contract_body(required_evidence: ["repository-gates"]))

      assert {:ok, first} = Acceptance.evidence(workspace, issue, @delivery)
      assert {:ok, second} = Acceptance.evidence(workspace, issue, @delivery)
      assert first == second
    end

    test "a broken workspace is reported instead of guessed" do
      not_a_repo = Path.join(System.tmp_dir!(), "symphony-acceptance-evidence-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      assert {:error, {:git_command_failed, _args, _status, _output}} =
               Acceptance.evidence(not_a_repo, issue(contract_body([])), @delivery)
    end
  end

  describe "the verdict as data" do
    test "the worst status wins and the phases are reported together" do
      scope = Result.evaluated(mode: :strict, contract_version: 1, limits: [:prohibition_scan_is_heuristic])

      evidence =
        Result.evaluated(
          mode: :strict,
          contract_version: 1,
          evidence: [%{name: "agent-tests", status: :passed, command: "true"}],
          limits: [:content_not_verified]
        )

      summary = Result.merge(scope, evidence)

      assert summary.status == :pass
      assert summary.limits == [:prohibition_scan_is_heuristic, :content_not_verified]
      assert [%{name: "agent-tests"}] = summary.evidence

      assert Acceptance.describe(summary) ==
               "`strict` passed (0/0 expected path(s) delivered, 1 evidence) [limits: prohibition scan is heuristic, " <>
                 "not a proof of absence, content/quality not verified by this layer]"

      diverged = %{scope | status: :advisory, findings: [finding(:expected_path_missing)]}

      assert Result.merge(diverged, evidence).status == :advisory
      assert Result.merge(scope, %{evidence | status: :advisory}).status == :advisory

      failed = %{scope | status: :fail}
      assert Result.merge(failed, evidence).status == :fail
      assert Result.worst(:fail, :advisory) == :fail
      assert Result.worst(:advisory, :pass) == :advisory
      assert Result.worst(:pass, :not_applicable) == :pass
      assert Result.severity(:fail) == 4
      assert Result.severity(:not_configured) == 0
    end

    test "a long list of findings is summarized instead of dumped" do
      findings = Enum.map(1..5, &finding(:unexpected_path_changed, "finding #{&1}"))

      described = Acceptance.describe(Result.evaluated(mode: :advisory, contract_version: 1, findings: findings))

      assert described =~ "advisory` diverged (5 finding(s)): finding 1; finding 2; finding 3 (+2 more)"
    end

    test "a finding with a path shows the path, without one it does not" do
      with_path = finding(:unexpected_path_changed, "changed path", "notes.md")
      without_path = finding(:required_evidence_missing, "no provider")

      described =
        Acceptance.describe(Result.evaluated(mode: :advisory, contract_version: 1, findings: [with_path, without_path]))

      assert described =~ "changed path [notes.md]"
      assert described =~ "no provider"
      refute described =~ "no provider []"
    end

    test "an absent or not applicable layer says so" do
      assert Acceptance.describe(Result.not_configured()) == "not declared in the issue body (acceptance not configured)"
      assert Acceptance.describe(Result.not_applicable(mode: :strict, contract_version: 1)) =~ "not applicable"
    end

    test "the verdict serializes to a stable, machine-readable block" do
      result =
        Result.evaluated(
          mode: :advisory,
          contract_version: 1,
          findings: [finding(:expected_path_missing, "expected path `docs/x.md` is missing", "docs/x.md")],
          limits: [:prohibition_scan_is_heuristic]
        )

      assert Acceptance.comment_marker("abc123") == "<!-- acceptance:result:abc123 -->"

      block = Acceptance.comment_block(result, "abc123")

      assert block =~ "<!-- acceptance:result:abc123 -->"
      assert block =~ "```json\n"

      json = block |> String.split("```json\n") |> List.last() |> String.replace_suffix("\n```", "")
      decoded = Jason.decode!(json)

      assert decoded["status"] == "advisory"
      assert decoded["contract_version"] == 1
      assert decoded["mode"] == "advisory"
      assert decoded["limits"] == ["prohibition_scan_is_heuristic"]

      assert [%{"code" => "expected_path_missing", "category" => "scope", "path" => "docs/x.md"}] =
               decoded["findings"]

      assert decoded["findings"] |> hd() |> Map.has_key?("message")
      refute Map.has_key?(decoded, "change_set")

      assert Acceptance.summary_json(result) == json
    end

    test "an oversized verdict is persisted compacted instead of being lost" do
      result =
        Result.evaluated(
          mode: :strict,
          contract_version: 1,
          evidence: [
            %{name: "huge", status: :passed, command: String.duplicate("x", 20_000)},
            %{name: "small", status: :passed, command: "true"}
          ]
        )

      decoded = Jason.decode!(Acceptance.summary_json(result))

      assert decoded["persisted"] =~ "compact"
      assert decoded["status"] == "pass"
      assert [%{"name" => "huge", "status" => "passed"}, %{"name" => "small"}] = decoded["evidence"]
      assert Enum.all?(decoded["evidence"], &(not Map.has_key?(&1, "command")))
    end

    test "the compacted verdict is bounded even with findings and evidences at the limits" do
      findings =
        Enum.map(1..300, fn index ->
          finding(:unexpected_path_changed, "changed path `f#{index}.md` is not authorized", "f#{index}.md")
        end)

      evidence =
        Enum.map(1..256, fn index ->
          %{name: "evidence-#{index}", status: :failed, command: String.duplicate("c", 300)}
        end)

      result =
        Result.evaluated(
          mode: :strict,
          contract_version: 1,
          findings: findings,
          evidence: evidence,
          limits: [:change_scan_truncated, :content_not_verified]
        )

      json = Acceptance.summary_json(result)
      decoded = Jason.decode!(json)

      # The payload goes into a GitHub comment: it is capped by construction, and it
      # says how much was left out instead of losing the verdict.
      assert byte_size(json) <= 16_384
      assert decoded["persisted"] =~ "compact"
      assert decoded["status"] == "fail"
      assert decoded["limits"] == ["change_scan_truncated", "content_not_verified"]
      assert length(decoded["findings"]) + decoded["omitted"]["findings"] == 300
      assert decoded["omitted"]["findings"] > 0
      assert length(decoded["evidence"]) + decoded["omitted"]["evidence"] == 256
      assert decoded["omitted"]["evidence"] > 0
      assert Enum.all?(decoded["evidence"], &(not Map.has_key?(&1, "command")))
    end
  end

  defp finding(code, message \\ "message", path \\ nil) do
    %Finding{code: code, category: :scope, message: message, path: path}
  end

  defp issue(description), do: %{@issue | description: description}

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

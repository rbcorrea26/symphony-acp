defmodule SymphonyElixir.PipelineContractTest do
  @moduledoc """
  The acceptance contract as a parser and as pure rules: schema validation,
  scope findings and the prohibition scan.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.PipelineContract, as: Contract

  @strict """
  pipeline_contract:
    version: 1
    scope_mode: strict
    expected_paths:
      - docs/changes/2026-09-30-pipeline-e2e-smoke.md
      - tests/agent/run-tests.sh
    allowed_extra_paths: []
    required_evidence:
      - agent-tests
      - repository-gates
    remote_access: false
    deploy: false
  """

  @advisory """
  pipeline_contract:
    version: 1
    scope_mode: advisory
    expected_paths:
      - docs/x.md
  """

  describe "parse/1" do
    test "reads a fenced contract with every field of version 1" do
      assert {:ok, contract} = Contract.parse(issue_body(@strict))

      assert contract.version == 1
      assert contract.scope_mode == :strict
      assert contract.expected_paths == ["docs/changes/2026-09-30-pipeline-e2e-smoke.md", "tests/agent/run-tests.sh"]
      assert contract.allowed_extra_paths == []
      assert contract.required_evidence == ["agent-tests", "repository-gates"]
      assert contract.remote_access == false
      assert contract.deploy == false
      assert Contract.strict?(contract)
    end

    test "defaults are conservative: absent lists are empty and prohibitions are on" do
      assert {:ok, contract} = Contract.parse(issue_body(@advisory))

      assert contract.scope_mode == :advisory
      assert contract.allowed_extra_paths == []
      assert contract.required_evidence == []
      assert contract.remote_access == false
      assert contract.deploy == false
      refute Contract.strict?(contract)
    end

    test "repeated evidence names are deduplicated" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        required_evidence:
          - agent-tests
          - agent-tests
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.required_evidence == ["agent-tests"]
    end

    test "a trailing slash in a pattern means the whole directory" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - docs/changes/
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.expected_paths == ["docs/changes/**"]
    end

    test "an unfenced body that starts with the contract is accepted" do
      assert {:ok, contract} = Contract.parse(@advisory)
      assert contract.scope_mode == :advisory
    end

    test "a body without a contract is not enforced" do
      assert Contract.parse(nil) == :absent
      assert Contract.parse("") == :absent
      assert Contract.parse("## Objective\n\nDeliver the change.\n") == :absent

      # The key must open the block: a late mention is not a contract.
      assert Contract.parse("# Notes\n\npipeline_contract: 1\n") == :absent
    end

    test "a code block without the key is not a contract" do
      body = """
      ```yaml
      other:
        version: 1
      ```
      """

      assert Contract.parse(body) == :absent
    end

    test "an unclosed fence still counts as a block" do
      body = "```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n  expected_paths:\n    - a.md\n"

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
    end

    test "a different fence delimiter inside a block does not close it" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - docs/x.md
      notes: |
        ~~~
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
    end

    test "two contracts in the same issue are ambiguous instead of guessed" do
      assert {:error, {:pipeline_contract_invalid, {:ambiguous_contracts, 2}}} =
               Contract.parse(issue_body(@strict) <> issue_body(@advisory))
    end

    test "an unsupported version is refused instead of interpreted" do
      assert {:error, {:pipeline_contract_invalid, {:unsupported_version, 2}}} = Contract.parse(contract("version: 2\nscope_mode: advisory"))
    end

    test "an unknown field is refused" do
      assert {:error, {:pipeline_contract_invalid, {:unknown_fields, ["timeout_minutes"]}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nrequired_evidence: [a]\ntimeout_minutes: 5"))
    end

    test "scope_mode is required and must be strict or advisory" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_scope_mode, nil}}} = Contract.parse(contract("version: 1"))
      assert {:error, {:pipeline_contract_invalid, {:invalid_scope_mode, "Strict"}}} = Contract.parse(contract("version: 1\nscope_mode: Strict"))
    end

    test "strict needs at least one expected path; advisory does not" do
      assert {:error, {:pipeline_contract_invalid, :strict_requires_expected_paths}} =
               Contract.parse(contract("version: 1\nscope_mode: strict\nexpected_paths: []"))

      assert {:ok, _contract} = Contract.parse(contract("version: 1\nscope_mode: advisory"))
    end

    test "a pattern must be a relative, non-escaping, single path" do
      invalid = [
        {"\" \"", :empty_pattern},
        {"\"docs/#{String.duplicate("x", 600)}\"", :pattern_too_long},
        {"\"docs\\\\x.md\"", :invalid_path_separator},
        {"\"/etc/passwd\"", :absolute_pattern},
        {"\"../outside.md\"", :escaping_pattern},
        {"1", :not_a_string}
      ]

      for {pattern, reason} <- invalid do
        assert {:error, {:pipeline_contract_invalid, {:invalid_pattern, "expected_paths", ^reason}}} =
                 Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: [#{pattern}]"))
      end
    end

    test "a field that is not a list is refused" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_field, "expected_paths", "\"docs/x.md\""}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: \"docs/x.md\""))

      assert {:error, {:pipeline_contract_invalid, {:invalid_field, "required_evidence", "3"}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nrequired_evidence: 3"))
    end

    test "a contract with too many items is refused" do
      patterns = Enum.map_join(1..257, ", ", &"\"a#{&1}.md\"")
      evidence = Enum.map_join(1..257, ", ", &"\"e#{&1}\"")

      assert {:error, {:pipeline_contract_invalid, {:too_many_items, "expected_paths", 257}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: [#{patterns}]"))

      assert {:error, {:pipeline_contract_invalid, {:too_many_items, "required_evidence", 257}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nrequired_evidence: [#{evidence}]"))
    end

    test "an evidence name must be a machine-readable slug" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_evidence, ["Agent Tests", 3]}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nrequired_evidence: [\"Agent Tests\", 3]"))
    end

    test "a prohibition flag must be a boolean" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_flag, "deploy", "\"no\""}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: \"no\""))
    end

    test "broken YAML is refused, never interpreted" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_yaml, _reason}}} =
               Contract.parse("```yaml\npipeline_contract: [1, 2\n```")

      assert {:error, {:pipeline_contract_invalid, {:not_a_mapping, "3"}}} =
               Contract.parse(contract("3"))

      assert {:error, {:pipeline_contract_invalid, :missing_pipeline_contract_key}} =
               Contract.parse("```yaml\nnotes: |\n  pipeline_contract: 1\n```")
    end

    test "an oversized contract is refused before decoding" do
      huge = contract("version: 1\nscope_mode: advisory\n# " <> String.duplicate("x", 70_000))

      assert {:error, {:pipeline_contract_invalid, {:contract_too_large, size}}} = Contract.parse(huge)
      assert size > 65_536
    end
  end

  describe "path_match?/2" do
    test "a pattern spans segments only with **" do
      assert Contract.path_match?("docs/changes/*.md", "docs/changes/2026-09-30-x.md")
      refute Contract.path_match?("docs/*.md", "docs/changes/2026-09-30-x.md")
      assert Contract.path_match?("docs/**/*.md", "docs/changes/2026-09-30-x.md")
      assert Contract.path_match?("**/run-tests.sh", "tests/agent/run-tests.sh")
      assert Contract.path_match?("**/run-tests.sh", "run-tests.sh")
      assert Contract.path_match?("tests/agent/run-tests.s?", "tests/agent/run-tests.sh")
      refute Contract.path_match?("tests/agent/run-tests.s", "tests/agent/run-tests.sh")
      assert Contract.path_match?("docs/changes/**", "docs/changes/2026-09-30-x.md")
    end
  end

  describe "path_findings/2" do
    test "reports the delivered, the missing and the unauthorized" do
      {:ok, contract} = Contract.parse(issue_body(@strict))
      changed = ["docs/changes/2026-09-30-pipeline-e2e-smoke.md", "README.md"]

      findings = Contract.path_findings(contract, changed)

      assert findings.expected == contract.expected_paths
      assert findings.delivered == ["docs/changes/2026-09-30-pipeline-e2e-smoke.md"]
      assert findings.changed == changed
      assert findings.unauthorized == ["README.md"]
      refute findings.truncated

      assert Enum.map(findings.violations, & &1.kind) == [:expected_path_untouched, :unauthorized_path]

      assert Enum.map(findings.violations, & &1.detail) == [
               "expected path `tests/agent/run-tests.sh` was not delivered by the candidate",
               "changed path `README.md` is outside the contract scope"
             ]
    end

    test "a path inside the allowed set is not a finding" do
      {:ok, contract} = Contract.parse(issue_body(@strict))
      contract = %{contract | allowed_extra_paths: ["docs/evidence/**", "CHANGELOG.md"]}

      changed = [
        "docs/changes/2026-09-30-pipeline-e2e-smoke.md",
        "tests/agent/run-tests.sh",
        "docs/evidence/ci.txt",
        "CHANGELOG.md"
      ]

      findings = Contract.path_findings(contract, changed)

      assert findings.violations == []
      assert findings.unauthorized == []
      assert length(findings.delivered) == 2
    end

    test "a glob expected path is delivered by any match, and `./` is not a path" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: [\"docs/changes/**\"]"))

      findings = Contract.path_findings(contract, ["./docs/changes/a.md", "docs/changes/a.md", "notes.md"])

      assert findings.changed == ["docs/changes/a.md", "notes.md"]
      assert findings.delivered == ["docs/changes/**"]
      assert findings.unauthorized == ["notes.md"]
    end

    test "a scope that diverges everywhere is reported as truncated, not as a wall of text" do
      {:ok, contract} = Contract.parse(issue_body(@strict))
      changed = Enum.map(1..9, &"extra/#{&1}.md")

      findings = Contract.path_findings(contract, changed)

      assert length(findings.violations) == 7
      assert findings.truncated
    end
  end

  describe "prohibition_findings/2" do
    test "reports deploy and remote access additions of the candidate" do
      {:ok, contract} = Contract.parse(issue_body(@advisory))

      findings =
        Contract.prohibition_findings(contract, [
          %{path: "scripts/deploy.sh", text: "kubectl apply -f k8s/"},
          %{path: "docs/x.md", text: "the docs describe the layers of the pipeline"},
          %{path: "docs/x.md", text: "this is a nested quote:      ssh prod.example.com"}
        ])

      assert findings.total == 2
      refute findings.truncated

      assert Enum.map(findings.violations, & &1.kind) == [:remote_access, :deploy]

      assert Enum.map(findings.violations, & &1.detail) == [
               "ssh/scp/sftp invocation in docs/x.md: this is a nested quote:      ssh prod.example.com",
               "kubectl change in scripts/deploy.sh: kubectl apply -f k8s/"
             ]
    end

    test "reports the first matching rule of a line only, and truncates the snippet" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory"))

      findings =
        Contract.prohibition_findings(contract, [
          %{path: "run.sh", text: "kubectl apply -f x && helm upgrade y " <> String.duplicate("z", 200)}
        ])

      assert [%{kind: :deploy, detail: detail}] = findings.violations
      assert detail =~ "kubectl change in run.sh: kubectl apply -f x"
      refute detail =~ String.duplicate("z", 100)
    end

    test "a candidate with a deploy/remote_access authorization has no prohibition finding" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: true\nremote_access: true"))

      assert Contract.prohibition_findings(contract, [%{path: "s.sh", text: "ssh host && helm upgrade x"}]) ==
               %{violations: [], total: 0, truncated: false}
    end

    test "an authorization of one kind does not authorize the other" do
      {:ok, only_remote} = Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: true"))

      assert [%{kind: :remote_access}] =
               Contract.prohibition_findings(only_remote, [%{path: "s.sh", text: "ssh host"}]).violations

      {:ok, only_deploy} = Contract.parse(contract("version: 1\nscope_mode: advisory\nremote_access: true"))

      assert [%{kind: :deploy}] =
               Contract.prohibition_findings(only_deploy, [%{path: "s.sh", text: "helm upgrade x"}]).violations
    end

    test "a noisy candidate is capped and declared truncated" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory"))
      lines = Enum.map(1..6, &%{path: "s#{&1}.sh", text: "scp file host:/tmp"})

      findings = Contract.prohibition_findings(contract, lines)

      assert findings.total == 6
      assert length(findings.violations) == 5
      assert findings.truncated
    end

    test "rules cover the commands that publish or reach a remote host" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory"))

      detected = fn text -> Contract.prohibition_findings(contract, [%{path: "x", text: text}]).total > 0 end

      assert detected.("terraform apply")
      assert detected.("npm publish")
      assert detected.("gh release create v1")
      assert detected.("docker push registry/x")
      assert detected.("ansible-playbook site.yml")
      assert detected.("aws s3 sync ./dist s3://bucket")
      assert detected.("git clone git@github.com:o/r.git")
      assert detected.("wp @production plugin update")
      assert detected.("mysqldump -h db.example.com app > dump.sql")
      assert detected.("see ssh://prod.example.com/repo")
      refute detected.("npm run test")
      refute detected.("git clone https://github.com/o/r.git")
      refute detected.("rsync -a ./dist/ ./public/")
      refute detected.("terraform plan")
    end
  end

  defp issue_body(yaml) do
    "## Objective\n\nDeliver the change described below.\n\n```yaml\n" <> yaml <> "```\n\n## Out of scope\n"
  end

  defp contract(yaml) do
    "```yaml\npipeline_contract:\n" <> indent(yaml) <> "\n```"
  end

  defp indent(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end
end

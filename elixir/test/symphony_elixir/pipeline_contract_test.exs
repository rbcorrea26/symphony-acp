defmodule SymphonyElixir.PipelineContractTest do
  @moduledoc """
  The acceptance contract as a parser and as pure rules: schema validation,
  scope findings and the prohibition scan.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.PipelineContract, as: Contract
  alias SymphonyElixir.PipelineContract.Finding

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
      assert Contract.prohibition_scan?(contract)
    end

    test "defaults are conservative: absent lists are empty and prohibitions are on" do
      assert {:ok, contract} = Contract.parse(issue_body(@advisory))

      assert contract.scope_mode == :advisory
      assert contract.allowed_extra_paths == []
      assert contract.required_evidence == []
      assert contract.remote_access == false
      assert contract.deploy == false
      refute Contract.strict?(contract)
      assert Contract.prohibition_scan?(contract)
    end

    test "an authorization of one kind leaves the other prohibition in force" do
      {:ok, only_deploy_authorized} = Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: true"))
      {:ok, only_remote_authorized} = Contract.parse(contract("version: 1\nscope_mode: advisory\nremote_access: true"))
      {:ok, both_authorized} = Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: true\nremote_access: true"))

      assert Contract.prohibition_scan?(only_deploy_authorized)
      assert Contract.prohibition_scan?(only_remote_authorized)
      refute Contract.prohibition_scan?(both_authorized)
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

    test "glob patterns are not mistaken for anchors or aliases" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - "*.md"
          - "**/run-tests.sh"
          - docs/*.md
        allowed_extra_paths: []
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.expected_paths == ["*.md", "**/run-tests.sh", "docs/*.md"]
    end

    test "an unfenced body that starts with the contract is accepted" do
      assert {:ok, contract} = Contract.parse(@advisory)
      assert contract.scope_mode == :advisory
    end

    test "a body without a contract is not enforced" do
      assert Contract.parse(nil) == :absent
      assert Contract.parse("") == :absent
      assert Contract.parse("## Objective\n\nDeliver the change.\n") == :absent
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

    test "a closing fence may carry trailing whitespace" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - docs/x.md
      ```   \t
      The prose after the block is not YAML.
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
    end

    test "a fence line with text after the marker is content, never a close" do
      # The pseudo-close used to truncate the block here: the valid prefix was read
      # and the field after it (`unknown_field`) was never observed.
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: strict
        expected_paths: [docs/a.md]
        ```not-a-close
        unknown_field: 1
      ```
      """

      assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(body)
    end

    test "an info string inside the block does not close it either" do
      # ` ```yaml ` is an opening fence; inside a block it is content, so the fields
      # after it are still read (and here the trailing marker is not a valid document).
      body = "```yaml\npipeline_contract:\n  version: 1\n  scope_mode: strict\n  expected_paths: [docs/a.md]\n```yaml\n```\n"

      assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(body)
    end

    test "a fence shorter than the opening one does not close the block" do
      body = """
      ````yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths: [docs/a.md]
      ```
      ````
      """

      assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(body)
    end

    test "a declaration after a pseudo-close is observed as a second contract" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: strict
        expected_paths: [docs/a.md]
      ```not-a-close
      ```

      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:ambiguous_contracts, 2}}} = Contract.parse(body)
    end

    test "a fence is structural only up to three spaces of indentation" do
      # CommonMark: four spaces make an indented code block, so such a line can neither
      # open nor close the block that carries the contract.
      for indent <- 0..3 do
        opening = String.duplicate(" ", indent)

        body = "#{opening}```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n#{opening}```\n"

        assert {:ok, contract} = Contract.parse(body), "opening fence indented by #{indent}"
        assert contract.scope_mode == :advisory
      end

      indented = "    ```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n    ```\n"

      # The block is never opened, so its text is prose of the body and declares nothing.
      assert Contract.parse(indented) == :absent
    end

    test "an indentation of four spaces does not close the block" do
      # Inside a block a line indented by four spaces is content (CommonMark), so it does
      # not end the block: both keys stay in one block — a duplicate — instead of the
      # second one becoming a block of its own.
      body =
        "```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n    ```\npipeline_contract:\n  version: 1\n  scope_mode: strict\n```\n"

      assert {:error, {:pipeline_contract_invalid, {:duplicate_contract_key, 2}}} = Contract.parse(body)

      # The same body with the marker indented by three spaces does close the block, and
      # the second key becomes a block of its own: the two declarations are ambiguous.
      split =
        "```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n   ```\n```yaml\npipeline_contract:\n  version: 1\n  scope_mode: strict\n```\n"

      assert {:error, {:pipeline_contract_invalid, {:ambiguous_contracts, 2}}} = Contract.parse(split)
    end

    test "a tab is not indentation: it cannot open or close the block" do
      # The column a tab reaches depends on the tab stop, so the conservative reading is
      # that a tab-indented marker is content: it cannot truncate the block either — the
      # second key stays inside it and the document is refused, never read as two blocks.
      tabbed =
        "```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n\t```\n```yaml\npipeline_contract:\n  version: 1\n  scope_mode: strict\n```\n"

      assert {:error, {:pipeline_contract_invalid, {:invalid_yaml, _reason}}} = Contract.parse(tabbed)

      # A tab-indented opener opens nothing either: the block is never read.
      tabbed_open = "## Notes\n\n\t```yaml\n\tpipeline_contract:\n\t  version: 1\n\t```\n"

      assert Contract.parse(tabbed_open) == :absent

      # Trailing whitespace after the marker is still allowed, tab included (CommonMark).
      assert {:ok, contract} =
               Contract.parse("```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n```\t\n")

      assert contract.scope_mode == :advisory
    end

    test "a valid contract with a normal close keeps being accepted" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: strict
        expected_paths: [docs/a.md]
      ```

      ```sh
      echo "the fence below is documentation, not a close"
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :strict
      assert contract.expected_paths == ["docs/a.md"]
    end

    test "two contract keys in one block are ambiguous, not silently one of them" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - a.md
      pipeline_contract:
        version: 1
        scope_mode: strict
        expected_paths:
          - b.md
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_contract_key, 2}}} = Contract.parse(body)
    end

    test "a field repeated inside the mapping is ambiguous, in block and flow form" do
      block = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: strict
        scope_mode: advisory
        expected_paths:
          - a.md
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_field, "scope_mode"}}} = Contract.parse(block)

      flow = "```yaml\npipeline_contract: {version: 1, version: 2, scope_mode: advisory}\n```"

      assert {:error, {:pipeline_contract_invalid, {:duplicate_field, "version"}}} = Contract.parse(flow)
    end

    test "a commented field example is not a duplicate" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory   # alternatively: strict
        expected_paths:
          - a.md
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
    end

    test "a quoted key is the same key: the contract is read, never reported as absent" do
      body = """
      ```yaml
      "pipeline_contract":
        "version": 1
        "scope_mode": "advisory"
        "expected_paths":
          - docs/x.md
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
      assert contract.expected_paths == ["docs/x.md"]
    end

    test "a quoted key in an unfenced body is read too" do
      assert {:ok, contract} = Contract.parse(~s["pipeline_contract":\n  version: 1\n  scope_mode: advisory])
      assert contract.scope_mode == :advisory
    end

    test "a quoted duplicate field is ambiguous, not silently collapsed by the decoder" do
      body = """
      ```yaml
      pipeline_contract:
        "version": 1
        "version": 2
        "scope_mode": advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_field, "version"}}} = Contract.parse(body)
    end

    test "two quoted contract keys are ambiguous: in one block and in two blocks" do
      one_block = """
      ```yaml
      "pipeline_contract":
        version: 1
        scope_mode: advisory
        expected_paths:
          - a.md
      'pipeline_contract':
        version: 1
        scope_mode: strict
        expected_paths:
          - b.md
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_contract_key, 2}}} = Contract.parse(one_block)

      quoted = """
      ```yaml
      "pipeline_contract":
        version: 1
        scope_mode: advisory
      ```

      ```yaml
      "pipeline_contract":
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:ambiguous_contracts, 2}}} = Contract.parse(quoted)
    end

    test "every style of the key is the same key: single quotes included" do
      body = """
      ```yaml
      'pipeline_contract':
        version: 1
        scope_mode: advisory
        expected_paths:
          - docs/x.md
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
      assert contract.expected_paths == ["docs/x.md"]
    end

    test "a duplicate written in mixed styles is still a duplicate" do
      # The count comes from the parser nodes, so `pipeline_contract:` and
      # `"pipeline_contract":` are two keys, not one the decoder would collapse.
      mixed = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
      "pipeline_contract":
        version: 1
        scope_mode: strict
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_contract_key, 2}}} = Contract.parse(mixed)

      tagged = """
      ```yaml
      !!str pipeline_contract:
        version: 1
        scope_mode: advisory
      "pipeline_contract":
        version: 1
        scope_mode: strict
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_contract_key, 2}}} = Contract.parse(tagged)
    end

    test "a repeated field is refused whatever its style, in block and explicit form" do
      mixed = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        "scope_mode": strict
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_field, "scope_mode"}}} = Contract.parse(mixed)

      listed = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths: [a.md]
        "expected_paths": [b.md]
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_field, "expected_paths"}}} = Contract.parse(listed)

      explicit = """
      ```yaml
      pipeline_contract:
        version: 1
        ? scope_mode
        : strict
        ? scope_mode
        : advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:duplicate_field, "scope_mode"}}} = Contract.parse(explicit)
    end

    test "a quoted unknown field is an unknown field" do
      assert {:error, {:pipeline_contract_invalid, {:unknown_fields, ["scope_mod"]}}} =
               Contract.parse(~s[```yaml\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n  "scope_mod": strict\n```])
    end

    test "an anchored key is refused instead of being read as absent" do
      # An anchor before the key is still a key the block claims, and refusing the
      # anchor is what keeps an alias graph from being expanded.
      key = """
      ```yaml
      &k pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&k"}}} = Contract.parse(key)

      explicit = """
      ```yaml
      ? &k pipeline_contract
      : {version: 1, scope_mode: advisory}
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&k"}}} = Contract.parse(explicit)
    end

    test "a block with more than one document is read as one contract, never as the wrong one" do
      # The key is counted across the documents of the block, while the decoder reads
      # one document: a contract that is not in the decoded document is refused
      # instead of being silently ignored (or read from the wrong document).
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
      ---
      notes: hi
      ```
      """

      assert {:error, {:pipeline_contract_invalid, :missing_pipeline_contract_key}} = Contract.parse(body)
    end

    test "an anchored block that is not the contract is left alone" do
      # The anchor is refused only where it would be a contract: an unrelated fenced
      # document that uses an anchor is not silently promoted to a declaration (and
      # it is not parsed either, so the alias graph is never expanded).
      body = """
      ```yaml
      defaults: &defaults
        timeout: 5
      ```

      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
    end

    test "a block scalar with the chomping indicator before the indentation is text too" do
      # YAML accepts both orders of the optional header indicators (`|2-` and `|-2`), and
      # the content of the scalar is text in either of them.
      for header <- ["|+2", "|-2", ">2+", ">+2"] do
        body = """
        ```yaml
        notes: #{header}
          pipeline_contract:
          &anchor
        ```
        """

        assert Contract.parse(body) == :absent
      end
    end

    test "an unrelated anchored block whose scalar mentions the key is not the contract" do
      # `&defaults` is structural, but the block claims nothing: the only mention of the
      # key is inside `notes: |`, which is text, so nothing is refused (and nothing is
      # read as a contract).
      body = """
      ```yaml
      defaults: &defaults
        timeout: 5
      notes: |
        pipeline_contract:
      ```
      """

      assert Contract.parse(body) == :absent
    end

    test "a quoted scalar that spans lines keeps its continuation out of the scan" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - "docs/a.md
            &notes.md"
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.expected_paths == ["docs/a.md &notes.md"]
    end

    test "a closing fence may be longer than the opening one" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
      ````
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.scope_mode == :advisory
    end

    test "the explicit key and the flow form with quotes are the same mapping" do
      explicit = """
      ```yaml
      ? pipeline_contract
      : {version: 1, scope_mode: advisory}
      ```
      """

      assert {:ok, explicit_contract} = Contract.parse(explicit)
      assert explicit_contract.scope_mode == :advisory

      flow = ~s[```yaml\n{"pipeline_contract": {"version": 1, "scope_mode": "advisory"}}\n```]

      assert {:ok, flow_contract} = Contract.parse(flow)
      assert flow_contract.scope_mode == :advisory
    end

    test "an ampersand inside a scalar or a comment is data, not an anchor" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - "docs/R&D &notes.md"
          - 'docs/Q&A &notes.md'
          - docs/a&b.md
        # see &notes for the schema
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.expected_paths == ["docs/R&D &notes.md", "docs/Q&A &notes.md", "docs/a&b.md"]
    end

    test "an anchor is refused before decoding" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths: &paths
          - a.md
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&paths"}}} = Contract.parse(body)
    end

    test "a block scalar hides its content from the hints and from the anchor scan" do
      # The content of `notes: |` (and of `>`, and of a sequence entry `- |`) is text:
      # an indented `pipeline_contract:` there is not a key and an `&anchor` there is
      # not an indicator, so the body is not a contract and nothing is refused.
      literal = """
      ```yaml
      notes: |
        pipeline_contract:
        version: 1
      ```
      """

      assert Contract.parse(literal) == :absent

      folded = """
      ```yaml
      example: >-
        &anchor pipeline_contract: 1
      ```
      """

      assert Contract.parse(folded) == :absent

      sequence = """
      ```yaml
      - |
        pipeline_contract:
          version: 1
          scope_mode: advisory
      ```
      """

      assert Contract.parse(sequence) == :absent

      # The scalar ends at the first line that is not more indented: the block *after*
      # it is read again (the state does not leak).
      after_scalar = """
      ```yaml
      notes: |
        pipeline_contract: 1
      pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:ok, contract} = Contract.parse(after_scalar)
      assert contract.scope_mode == :advisory
    end

    test "a doubled apostrophe stays inside the single-quoted scalar" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths:
          - 'docs/it''s &notes.md'
      ```
      """

      assert {:ok, contract} = Contract.parse(body)
      assert contract.expected_paths == ["docs/it's &notes.md"]

      # ...and a real anchor right after the escaped pair is still structure.
      anchored = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths: ['', &notes]
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&notes"}}} = Contract.parse(anchored)
    end

    test "an anchor whose name is not ASCII is refused too" do
      # YAML's anchor name is any run of characters that is not whitespace and not a
      # flow indicator, so `&çaminho` and `&ação` are anchors: an ASCII-only token
      # class would let the block reach the parser and expand an alias graph.
      value = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths: &çaminho
          - a.md
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&çaminho"}}} = Contract.parse(value)

      key = """
      ```yaml
      &ação pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&ação"}}} = Contract.parse(key)

      # An anchor name may even carry a `:` (it is not a flow indicator).
      colon = """
      ```yaml
      &a:b pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:anchors_not_supported, "&a:b"}}} = Contract.parse(colon)
    end

    test "a YAML tag is refused: the schema has explicit types, never constructors" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_yaml, %{type: :unrecognized_node}}}} =
               Contract.parse("```yaml\npipeline_contract: !ruby/object {}\n```")
    end

    test "an alias without an anchor is refused by the decoder" do
      body = """
      ```yaml
      pipeline_contract:
        version: 1
        scope_mode: advisory
        expected_paths: *paths
      ```
      """

      assert {:error, {:pipeline_contract_invalid, {:invalid_yaml, _reason}}} = Contract.parse(body)
    end

    test "an unsupported version is refused instead of interpreted" do
      assert {:error, {:pipeline_contract_invalid, {:unsupported_version, 2}}} =
               Contract.parse(contract("version: 2\nscope_mode: advisory"))
    end

    test "an unknown field is refused" do
      assert {:error, {:pipeline_contract_invalid, {:unknown_fields, ["timeout_minutes"]}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nrequired_evidence: [a]\ntimeout_minutes: 5"))
    end

    test "scope_mode is required and must be strict or advisory" do
      assert {:error, {:pipeline_contract_invalid, {:invalid_scope_mode, nil}}} = Contract.parse(contract("version: 1"))

      assert {:error, {:pipeline_contract_invalid, {:invalid_scope_mode, "Strict"}}} =
               Contract.parse(contract("version: 1\nscope_mode: Strict"))
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

    test "a pattern that is not valid UTF-8 is refused, never compiled" do
      # `!!binary` is how YAML hands raw bytes to a scalar: the glob comparison runs
      # over UTF-8 paths, so such a pattern is a schema error instead of a crash in
      # the middle of the scope comparison.
      assert {:error, {:pipeline_contract_invalid, {:invalid_pattern, "expected_paths", :not_utf8}}} =
               Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: [!!binary \"//4=\"]"))
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

      assert {:error, {:pipeline_contract_invalid, {:not_a_mapping, "3"}}} = Contract.parse(contract("3"))
    end

    test "a mention of the key inside a scalar is data, not a declaration" do
      # The parser is what tells a key from text: here `pipeline_contract:` is the
      # *value* of `notes`, so the body declares no contract at all.
      assert Contract.parse("```yaml\nnotes: |\n  pipeline_contract: 1\n```") == :absent

      # A block whose text claims the key but that cannot be decoded at all is an
      # error instead: the text fallback can only fail closed.
      assert {:error, {:pipeline_contract_invalid, {:invalid_yaml, _reason}}} =
               Contract.parse("```yaml\nnotes: [1, 2\npipeline_contract: 1\n```")
    end

    test "a comment that mentions the key is text, not a declaration" do
      body = """
      ```yaml
      # pipeline_contract: see docs/fork/acceptance-contract.md
      other: 1
      ```
      """

      assert Contract.parse(body) == :absent

      # The same inside a block that **is** the contract: the comment is not a second key.
      commented = """
      ```yaml
      # pipeline_contract: 1
      pipeline_contract:
        version: 1
        scope_mode: advisory
      ```
      """

      assert {:ok, contract} = Contract.parse(commented)
      assert contract.scope_mode == :advisory
    end

    test "a quoted scalar that mentions the key is text, not a declaration" do
      inline = """
      ```yaml
      notes: "the pipeline_contract: block is documented in docs/fork"
      ```
      """

      assert Contract.parse(inline) == :absent

      # A quoted scalar may span lines: its continuation is scalar content, so it cannot
      # be read as a key (the decoder reads one string, not a mapping).
      multiline = """
      ```yaml
      notes: "line one
        pipeline_contract: 1"
      ```
      """

      assert Contract.parse(multiline) == :absent
    end

    test "a malformed scalar cannot hide a declaration that follows it" do
      # `foo:'unterminated` does not open a quoted scalar (YAML needs separation after the
      # `:`, so the quote is plain content): the declaration below it is read as a key by
      # the parser, and it is the *text* that has to notice that the decoder absorbed the
      # line into a longer plain scalar key — fail closed, never absent.
      for quote <- ["'", "\""] do
        adjacent = "```yaml\nfoo:#{quote}unterminated\n#{@strict}```"

        assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(adjacent),
               "adjacent #{quote} did not fail closed"

        # With separation the quote *does* open a scalar, and since it never closes the
        # decoder cannot read the document: the declaration after it must still be seen.
        spaced = "```yaml\nfoo: #{quote}unterminated\n#{@strict}```"

        assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(spaced),
               "spaced #{quote} did not fail closed"
      end

      # The same shape inside a flow collection: the unterminated quote is not a scalar
      # the decoder accepts either, and the key after it is still observed.
      flow = "```yaml\nfoo: [1, 'unterminated\npipeline_contract: 1\n```"

      assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(flow)

      # A stray quote inside a plain value is not a scalar start, so it cannot blank the
      # line after it either: the declaration is still refused instead of being ignored.
      stray = "```yaml\na: b \"c\npipeline_contract: 1\n```"

      assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(stray)

      # The same shape with the stray quote closing further down: a possible declaration
      # between the two quotes is still observed (the text hint is judged on the raw text
      # when the document cannot be read, and on the keys the decoder read when it can).
      for closing <- ["x: \"y\n", "  notes: \"done\"\n"] do
        reopened = "```yaml\na: b \"c\npipeline_contract:\n  version: 1\n  scope_mode: advisory\n#{closing}```"

        assert {:error, {:pipeline_contract_invalid, _reason}} = Contract.parse(reopened),
               "a quote closing later hid the declaration"
      end
    end

    test "the decoder reads a declaration absorbed by a malformed scalar as an error" do
      # `YamlElixir` reads this block as one plain multi-line key that *contains* the
      # declaration, so it reports no contract key at all while the text declares one in
      # key position: the block is a contract candidate whose decode says the key is
      # missing, never a silent `absent`.
      body = "```yaml\nfoo:'unterminated\n#{@strict}```"

      assert {:error, {:pipeline_contract_invalid, :missing_pipeline_contract_key}} = Contract.parse(body)

      # The same with double quotes.
      double = "```yaml\nfoo:\"unterminated\n#{@strict}```"

      assert {:error, {:pipeline_contract_invalid, :missing_pipeline_contract_key}} = Contract.parse(double)
    end

    test "normal prose that mentions nothing is not a contract" do
      assert Contract.parse("## Objective\n\nDeliver the change and explain it.\n") == :absent

      prose = """
      ## Notes

      - `pipeline_contract` is documented in docs/fork/acceptance-contract.md
      - the YAML block has to be fenced
      """

      assert Contract.parse(prose) == :absent
    end

    test "a fenced block that is not the contract is not read as one" do
      # A block nobody can decode and that claims no key is unrelated: it does not
      # make the body a contract (nor an error).
      assert Contract.parse("## Notes\n\n```bash\nif [ -f x; then echo x\n```\n") == :absent
    end

    test "an oversized contract is refused before decoding" do
      huge = contract("version: 1\nscope_mode: advisory\n# " <> String.duplicate("x", 70_000))

      assert {:error, {:pipeline_contract_invalid, {:contract_too_large, size}}} = Contract.parse(huge)
      assert size > 65_536
    end
  end

  describe "path_match?/2" do
    test "a `?` matches one character, not one byte" do
      assert Contract.path_match?("docs/?.md", "docs/é.md")
      refute Contract.path_match?("docs/?.md", "docs/éé.md")
      assert Contract.path_match?("docs/*.md", "docs/é.md")
    end

    test "a pattern spans segments only with **" do
      assert Contract.path_match?("docs/changes/*.md", "docs/changes/2026-09-30-x.md")
      refute Contract.path_match?("docs/*.md", "docs/changes/2026-09-30-x.md")
      assert Contract.path_match?("docs/**/*.md", "docs/changes/2026-09-30-x.md")
      assert Contract.path_match?("**/run-tests.sh", "tests/agent/run-tests.sh")
      assert Contract.path_match?("**/run-tests.sh", "run-tests.sh")
      assert Contract.path_match?("tests/agent/run-tests.s?", "tests/agent/run-tests.sh")
      refute Contract.path_match?("tests/agent/run-tests.s", "tests/agent/run-tests.sh")
      assert Contract.path_match?("docs/changes/**", "docs/changes/2026-09-30-x.md")
      refute Contract.path_match?("docs/changes/**", "docs/other.md")
    end
  end

  describe "path_findings/2" do
    test "reports the delivered, the missing and the unexpected" do
      {:ok, contract} = Contract.parse(issue_body(@strict))
      changed = ["docs/changes/2026-09-30-pipeline-e2e-smoke.md", "README.md"]

      findings = Contract.path_findings(contract, changed)

      assert findings.expected == contract.expected_paths
      assert findings.delivered == ["docs/changes/2026-09-30-pipeline-e2e-smoke.md"]
      assert findings.changed == changed
      assert findings.unexpected == ["README.md"]
      refute findings.truncated

      assert Enum.map(findings.findings, & &1.code) == [:expected_path_missing, :unexpected_path_changed]
      assert Enum.map(findings.findings, & &1.category) == [:scope, :scope]

      assert Enum.map(findings.findings, & &1.message) == [
               "expected path `tests/agent/run-tests.sh` is not part of the candidate change set",
               "changed path `README.md` is not in expected_paths nor allowed_extra_paths"
             ]

      assert Enum.map(findings.findings, & &1.path) == ["tests/agent/run-tests.sh", "README.md"]
      assert Enum.all?(findings.findings, &match?(%Finding{}, &1))
    end

    test "an expected path that merely exists outside the change set is a finding" do
      {:ok, contract} = Contract.parse(issue_body(@strict))

      findings = Contract.path_findings(contract, ["docs/changes/2026-09-30-pipeline-e2e-smoke.md"])

      assert findings.delivered == ["docs/changes/2026-09-30-pipeline-e2e-smoke.md"]

      assert Enum.map(findings.findings, &{&1.code, &1.path}) == [
               {:expected_path_missing, "tests/agent/run-tests.sh"}
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

      assert findings.findings == []
      assert findings.unexpected == []
      assert length(findings.delivered) == 2
    end

    test "a glob expected path is delivered by any match, and `./` is not a path" do
      {:ok, contract} =
        Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: [\"docs/changes/**\"]"))

      findings = Contract.path_findings(contract, ["./docs/changes/a.md", "docs/changes/a.md", "notes.md"])

      assert findings.changed == ["docs/changes/a.md", "notes.md"]
      assert findings.delivered == ["docs/changes/**"]
      assert findings.unexpected == ["notes.md"]
    end

    test "a scope that diverges everywhere is reported as truncated, not as a wall of text" do
      {:ok, contract} = Contract.parse(issue_body(@strict))
      findings = Contract.path_findings(contract, Enum.map(1..9, &"extra/#{&1}.md"))

      assert length(findings.findings) == 7
      assert findings.truncated
    end

    test "the whole contract and a large change set are matched without recompiling per pair" do
      # 512 patterns (256 expected + 256 allowed) against 1,000 paths. Each pattern
      # is compiled **once per evaluation** and reused for the delivered and the
      # authorized comparison; compiling per combination would be half a million
      # compilations for this single call, which is why the invariant is stated in
      # the documentation of `path_findings/2` and covered here at the limits (the
      # change set itself is capped at 5,000 paths by the delivery stage).
      expected = Enum.map_join(1..256, ", ", &~s("expected/dir-#{&1}/*.md"))
      allowed = Enum.map_join(1..256, ", ", &~s("allowed/dir-#{&1}/*.md"))

      {:ok, contract} =
        Contract.parse(contract("version: 1\nscope_mode: advisory\nexpected_paths: [#{expected}]\nallowed_extra_paths: [#{allowed}]"))

      paths = Enum.map(1..1_000, &"allowed/dir-#{rem(&1, 256) + 1}/file-#{&1}.md")
      findings = Contract.path_findings(contract, paths)

      # Every path is authorized, and every expected pattern is missing: the verdict
      # is the same one a small candidate gets, only at the limits of the schema.
      assert findings.changed == paths
      assert findings.unexpected == []
      assert findings.delivered == []
      assert findings.findings |> Enum.map(& &1.code) |> Enum.uniq() == [:expected_path_missing]
      assert length(findings.findings) == 5
      assert findings.truncated
    end
  end

  describe "prohibition_findings/2" do
    test "reports deploy and remote access additions of the candidate as findings" do
      {:ok, contract} = Contract.parse(issue_body(@advisory))

      findings =
        Contract.prohibition_findings(contract, [
          %{path: "scripts/deploy.sh", text: "kubectl apply -f k8s/"},
          %{path: "docs/x.md", text: "the docs describe the layers of the pipeline"},
          %{path: "docs/x.md", text: "this is a nested quote:      ssh prod.example.com"}
        ])

      assert findings.total == 2
      refute findings.truncated

      assert Enum.map(findings.findings, &{&1.code, &1.category, &1.path}) == [
               {:forbidden_remote_access_detected, :forbidden_operation, "docs/x.md"},
               {:forbidden_deploy_detected, :forbidden_operation, "scripts/deploy.sh"}
             ]

      assert Enum.map(findings.findings, & &1.message) == [
               "ssh/scp/sftp invocation: this is a nested quote:      ssh prod.example.com",
               "kubectl change: kubectl apply -f k8s/"
             ]
    end

    test "reports the first matching rule of a line only, and truncates the snippet" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory"))

      findings =
        Contract.prohibition_findings(contract, [
          %{path: "run.sh", text: "kubectl apply -f x && helm upgrade y " <> String.duplicate("z", 200)}
        ])

      assert [%Finding{code: :forbidden_deploy_detected, message: message}] = findings.findings
      assert message =~ "kubectl apply -f x"
      refute message =~ String.duplicate("z", 100)
    end

    test "a candidate with a deploy/remote_access authorization has no prohibition finding" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: true\nremote_access: true"))

      assert Contract.prohibition_findings(contract, [%{path: "s.sh", text: "ssh host && helm upgrade x"}]) ==
               %{findings: [], total: 0, truncated: false}
    end

    test "an authorization of one kind does not authorize the other" do
      {:ok, only_remote} = Contract.parse(contract("version: 1\nscope_mode: advisory\ndeploy: true"))

      assert [%{code: :forbidden_remote_access_detected}] =
               Contract.prohibition_findings(only_remote, [%{path: "s.sh", text: "ssh host"}]).findings

      {:ok, only_deploy} = Contract.parse(contract("version: 1\nscope_mode: advisory\nremote_access: true"))

      assert [%{code: :forbidden_deploy_detected}] =
               Contract.prohibition_findings(only_deploy, [%{path: "s.sh", text: "helm upgrade x"}]).findings
    end

    test "a noisy candidate is capped and declared truncated" do
      {:ok, contract} = Contract.parse(contract("version: 1\nscope_mode: advisory"))
      lines = Enum.map(1..6, &%{path: "s#{&1}.sh", text: "scp file host:/tmp"})

      findings = Contract.prohibition_findings(contract, lines)

      assert findings.total == 6
      assert length(findings.findings) == 5
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
    yaml |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end
end

defmodule SymphonyElixir.PipelineContract do
  @moduledoc """
  Machine-readable acceptance contract of an issue (`pipeline_contract`).

  This is the layer that answers **"was the issue satisfied?"**. It is
  independent from the consumer gates (`delivery.gates`: "is the repository
  still valid?") and from the CI ("did the published candidate pass?"): green
  gates do not replace acceptance and a requested review is not a concluded one.

  The contract is **declarative data written in the issue body**, never code:

    * the parser extracts a fenced block that declares `pipeline_contract:` (or a
      body that starts with it) and validates version, types and field names — it
      never evaluates the issue content (`eval`/`source`/shell are prohibited by
      design and there is no path here that runs anything from the issue);
    * the schema is small and versioned (`version: 1`), so a pipeline that meets a
      contract it does not understand refuses it instead of guessing;
    * the scope rules are pure functions over the candidate change set, so they
      can be audited and reviewed without running the pipeline.

  Schema (v1):

  ```yaml
  pipeline_contract:
    version: 1
    scope_mode: strict          # strict | advisory (required)
    expected_paths:             # glob patterns; each one must be delivered
      - docs/changes/2026-09-30-pipeline-e2e-smoke.md
    allowed_extra_paths: []     # extra patterns the scope authorizes
    required_evidence:          # evidence names required for this candidate
      - agent-tests
      - repository-gates
    remote_access: false        # false (default) = explicit prohibition
    deploy: false               # false (default) = explicit prohibition
  ```

  Paths use `/` as separator; `*` matches inside a segment, `**` spans segments,
  `?` matches one character and a trailing `/` means `/**`. Patterns are relative
  to the repository root: an absolute pattern or a `..` segment is a schema
  error. Unknown fields, an unsupported `version`, an invalid `scope_mode` and a
  `strict` contract without `expected_paths` are schema errors too — the delivery
  fails without publishing, which is the auditable outcome for a contract that
  cannot be enforced.

  Prohibition detection (`remote_access`/`deploy` set to `false`) is a
  **heuristic over the added lines of the candidate**, with fixed and versioned
  rules (`@deploy_rules`/`@remote_access_rules`) bounded by `@max_findings`. A
  match is a finding for the human, never a claim about intent: the rules are
  documented in `docs/fork/adr/0006-acceptance-contract.md`.

  Safety of the extraction (the issue body is untrusted input):

    * YAML is **decoded, never executed**: there is no `eval`/`source`, no shell
      and no interpolation of contract data into a command anywhere in the fork;
    * YAML tags are refused: `YamlElixir` only knows the plain types used by the
      schema, so `!foo`, `!ruby/object` and `!!python/...` fail as unrecognized;
    * anchors and aliases are refused by this parser (`&name`/`*name`) because the
      schema needs no indirection and an alias graph can expand exponentially
      ("billion laughs") from a small document;
    * the block is bounded (`@max_contract_bytes`) and so are the lists
      (`@max_items`) and the patterns (`@max_pattern_length`);
    * a body that declares `pipeline_contract` twice is rejected as ambiguous
      instead of picking one (both two blocks and two keys in the same block), and a
      key repeated inside the mapping is rejected too: the keys are counted on the
      **parser nodes**, before the decoder collapses equal keys, so the style of
      the key (plain, `"quoted"`, `'quoted'`, tagged or the explicit `? key`) never
      changes the answer;
    * the *text* of the block is never the source of truth for that count: a regex
      hint only **widens** the failure set. A block that **cannot be read** is judged on
      its **raw** text — nothing is blanked, so no heuristic about scalars can hide a
      declaration: an unreadable block whose text declares the key is an error, never
      `absent` — and a **readable** block that reads no contract key is judged on what
      the **decoder read**: a key the decoder read that *contains* the token means a
      malformed scalar absorbed a declaration into a longer plain key (`foo:'unterminated`
      followed by a real `pipeline_contract:`) or that the declaration is nested in
      another mapping, and both are refused; a token inside a *value* (a block scalar, a
      quoted string, a comment) is not a key at all and leaves the body unconfigured.
      Scalar blanking is used only where the block must **not** be parsed: refusing a
      structural anchor (an alias graph is never expanded), refusing a block that still
      holds a fence delimiter (see the fence rule below) and reading the start of an
      unfenced body. A block above the size cap is judged on its **raw** text, like an
      unreadable one, and it is judged **first**: the cap has precedence, so a structural
      anchor or a leftover fence cannot turn an oversized declaration into `absent`;
    * the fences that delimit the block follow CommonMark's structural limit: a fence
      may be indented by **at most three spaces**, so a line with four or more is
      indented code and can neither open nor close the block. Indentation is counted in
      spaces only: a tab-indented marker is content (the conservative reading, since
      the column a tab reaches depends on the tab stop). The closing fence carries
      **spaces only** after the marker, so a trailing tab — or any other character — is
      content and cannot end the block either. A block that claims the contract and
      still holds a fence delimiter in its structure — the close the author wrote and
      the rule rejected (a tab, a text suffix, a shorter marker, another marker kind)
      or a nested fence — is **refused** instead of parsed: the YAML library ends the
      `pipeline_contract` mapping at that line and would move every field written after
      it out of the contract in silence, which is exactly the truncation the fence rule
      exists to prevent;
    * patterns are never resolved against the filesystem: an absolute path, a `..`
      segment or a `\` separator is a schema error, and the match is a pure,
      anchored comparison against the candidate change set — a symlink cannot
      move the scope.
  """

  defmodule Finding do
    @moduledoc """
    Stable, machine-readable finding of the acceptance layer.

    `code` is deterministic and is the field a consumer (for example the review
    state machine of the next increment) should switch on; `message` is for the
    human and carries the detail (path, matched rule, reason). There is no score
    and no ranking: the `mode` of the contract decides whether the findings block
    the delivery.
    """

    @type code ::
            :invalid_contract
            | :expected_path_missing
            | :unexpected_path_changed
            | :required_evidence_missing
            | :required_evidence_failed
            | :prohibition_scan_truncated
            | :forbidden_deploy_detected
            | :forbidden_remote_access_detected

    @type category :: :contract | :scope | :evidence | :forbidden_operation

    @type t :: %__MODULE__{
            code: code(),
            category: category(),
            message: String.t(),
            path: String.t() | nil
          }

    @derive {Jason.Encoder, only: [:code, :category, :message, :path]}
    defstruct [:code, :category, :message, :path]
  end

  @version 1
  @fields ~w(version scope_mode expected_paths allowed_extra_paths required_evidence remote_access deploy)
  @contract_field "pipeline_contract"
  # Text hint of the contract key, in the shapes a YAML writer produces: plain, a
  # quoted scalar (`"pipeline_contract":`, what a template or a JSON-ish generator
  # produces), a tag or an anchor before the key, the explicit-key indicator
  # (`? key`, with its `:` on the same line or on the next one) and the flow
  # separator. It is **not** what decides whether the body declares a contract —
  # that is read from the parser nodes (`observe/1`) —; it only *widens* the
  # failure set: a block whose text claims the key but that cannot be decoded is an
  # error instead of `absent`, and an anchored key is routed to the anchor refusal
  # instead of being parsed (an alias graph must never be expanded). A mention of
  # the key inside a scalar is data, not a declaration, and the parser is what
  # tells the two apart. The tag/anchor token excludes whitespace and `:`, so a
  # value is never read as a tag.
  @contract_key ~r/(?:^[ \t]*|[{,]\s*)(?:\?[ \t]*)?(?:&[^\s,\[\]{}]+[ \t]+)?(?:!!?[^\s:,]+[ \t]+)?["']?pipeline_contract["']?[ \t]*(?::|$)/m
  @contract_key_start ~r/^[ \t]*(?:\?[ \t]*)?(?:&[^\s,\[\]{}]+[ \t]+)?(?:!!?[^\s:,]+[ \t]+)?["']?pipeline_contract["']?[ \t]*(?::|$)/
  # A fence may be indented by **at most three spaces** (CommonMark): a line with four
  # or more is indented code, so it can neither open nor close the block that carries
  # the contract. Indentation is measured in spaces only — a tab is not accepted as
  # indentation, because the column a tab reaches depends on the tab stop and a wrong
  # answer here would truncate the block silently; a tab-indented marker is content
  # (the conservative reading, declared in `docs/fork/acceptance-contract.md`).
  @fence ~r/^ {0,3}(`{3,}|~{3,})/
  # The same shape **anywhere** in the block (multiline): a block that claims the contract
  # and still contains one of these lines was not closed by the line the author closed it
  # with, so its boundary is not the one that was written — see `classify_fenced/1`.
  @fence_line ~r/^ {0,3}(`{3,}|~{3,})/m
  # The closing fence, the same marker with **nothing but spaces** after it: an info string
  # is allowed on the opening line only, so ` ```not-a-close ` inside a block is content and
  # cannot end it (a pseudo-close would truncate the block to a readable prefix and hide
  # every field after it). The trailing whitespace is **spaces only**, for the same reason
  # the indentation is counted in spaces only: a trailing tab is invisible in most editors
  # and would close the block without being part of the documented contract, so it is
  # content like any other suffix (the declared divergence from CommonMark is deliberate
  # and fail-closed — a tab can only keep text inside the block, never truncate it).
  @closing_fence ~r/^ {0,3}(`{3,}|~{3,}) *$/
  @evidence_name ~r/^[a-z0-9][a-z0-9._-]*$/
  @max_pattern_length 512
  @max_items 256
  @max_evidence_name_length 64
  @max_contract_bytes 65_536
  @max_findings 5
  @max_snippet_length 80

  # An anchor token (`&name`) is refused: the schema needs no indirection, and an
  # alias graph can expand exponentially from a small document. The token class
  # matches an anchor *indicator* (start, whitespace or structural punctuation
  # before `&`) followed by YAML's anchor grammar for the name — any run of
  # characters that is not whitespace and not a flow indicator (`[`, `]`, `{`, `}`,
  # `,`), so `&é`, `&ção` and `&a:b` are refused too, not only ASCII names —, so a
  # glob pattern such as `docs/*.md` or `**/x.sh` and an `&` inside a value or a
  # quoted string are untouched.
  @anchor_token ~r/(?:^|[\s:,\[\]{}])&[^\s,\[\]{}]+/m
  # A block scalar indicator at the end of a line (`key: |`, `key: >-`, `- |2`), where
  # YAML reads the value as a literal/folded block: the lines under it are text. The
  # header accepts both orders of the optional indicators (`|2-` and `|-2` are both
  # valid), so a valid scalar is never scanned as structure.
  @block_indicator ~r/(?:^|[:\-])[ \t]*[|>](?:[0-9]+[+\-]?|[+\-][0-9]+|[+\-]|[0-9]+)?[ \t]*$/
  # A contract key written as a quoted scalar in **key position** (start of a line or
  # after a flow separator): it is a key, not a value, so it is unquoted before the
  # scalar scan and stays visible to the claim hint.
  @quoted_contract_key ~r/(^[ \t]*|[{,]\s*)(\?[ \t]*)?(&[^\s,\[\]{}]+[ \t]+)?(!!?[^\s:,]+[ \t]+)?["']pipeline_contract["']([ \t]*:)/

  # Fixed rules of `deploy: false`. They run over the *added* lines of the
  # candidate only, so a line that merely documents the pipeline (in an
  # unmodified file) is never a finding.
  @deploy_rules [
    {~r/(?:^|[\s;&|(])kubectl\s+(?:apply|create|delete|patch|replace|rollout)\b/, "kubectl change"},
    {~r/(?:^|[\s;&|(])terraform\s+(?:apply|destroy|import|taint)\b/, "terraform apply/destroy"},
    {~r/(?:^|[\s;&|(])helm\s+(?:upgrade|install|uninstall|rollback)\b/, "helm release"},
    {~r/(?:^|[\s;&|(])ansible-playbook\b/, "ansible playbook"},
    {~r/(?:^|[\s;&|(])docker\s+(?:push|deploy)\b/, "container publish"},
    {~r/(?:^|[\s;&|(])(?:npm|yarn|pnpm)\s+publish\b/, "package publish"},
    {~r/(?:^|[\s;&|(])gh\s+release\s+(?:create|upload)\b/, "release publish"},
    {~r/(?:^|[\s;&|(])aws\s+(?:deploy|cloudformation\s+deploy|s3\s+sync)\b/, "cloud deploy"}
  ]

  # Fixed rules of `remote_access: false`.
  @remote_access_rules [
    {~r/(?:^|[\s;&|(])(?:ssh|scp|sftp)\s+\S/, "ssh/scp/sftp invocation"},
    {~r/(?:^|[\s;&|(])rsync\b[^\n]*@[^\s@:]+:/, "rsync to a remote host"},
    {~r/(?:^|[\s;&|(])rsync\b[^\n]*\s[[:alnum:]_.-]+:/, "rsync to a remote host"},
    {~r/ssh:\/\/\S+/, "ssh:// URL"},
    {~r/(?:^|[\s;&|(])git\s+clone\s+git@\S+/, "clone over SSH"},
    {~r/(?:^|[\s;&|(])wp\s+(?:@[[:alnum:]_.-]+|--ssh=\S+)/, "remote wp-cli"},
    {~r/(?:^|[\s;&|(])(?:mysql|mysqladmin|mysqldump|psql)\b[^\n]*\s+-h\s+\S/, "remote database"}
  ]

  @type scope_mode :: :strict | :advisory

  @type t :: %__MODULE__{
          version: pos_integer(),
          scope_mode: scope_mode(),
          expected_paths: [String.t()],
          allowed_extra_paths: [String.t()],
          required_evidence: [String.t()],
          remote_access: boolean(),
          deploy: boolean()
        }

  @type violation :: Finding.t()

  @type path_findings :: %{
          expected: [String.t()],
          delivered: [String.t()],
          changed: [String.t()],
          unexpected: [String.t()],
          findings: [Finding.t()],
          truncated: boolean()
        }

  @type prohibition_findings :: %{
          findings: [Finding.t()],
          total: non_neg_integer(),
          truncated: boolean()
        }

  @enforce_keys [:scope_mode]
  defstruct version: @version,
            scope_mode: nil,
            expected_paths: [],
            allowed_extra_paths: [],
            required_evidence: [],
            remote_access: false,
            deploy: false

  @doc """
  Extracts and validates the contract carried by an issue body.

  Returns `:absent` when the body declares no contract (the layer does not apply
  and nothing is enforced), `{:ok, contract}` when the schema is valid and
  `{:error, {:pipeline_contract_invalid, reason}}` when the issue declares a
  contract that cannot be enforced — including an unsupported version, an
  unknown field, an ambiguous body with two contracts and invalid YAML.

  The declaration itself is read from the YAML parser nodes (every key style is
  the same key) and only a body the parser cannot read falls back to the text
  hint, which can only fail closed.
  """
  @spec parse(String.t() | nil) :: :absent | {:ok, t()} | {:error, {:pipeline_contract_invalid, term()}}
  def parse(nil), do: :absent

  def parse(body) when is_binary(body) do
    case candidate(body) do
      :absent -> :absent
      {:contract, found} -> decode_found(found)
      {:error, reason} -> {:error, {:pipeline_contract_invalid, reason}}
    end
  end

  @doc "Whether a violation of this contract fails the acceptance instead of only being reported."
  @spec strict?(t()) :: boolean()
  def strict?(%__MODULE__{scope_mode: scope_mode}), do: scope_mode == :strict

  @doc """
  Whether at least one prohibition is enforced (`remote_access` and/or `deploy`
  set to `false`), which is what makes the added-lines scan run.
  """
  @spec prohibition_scan?(t()) :: boolean()
  def prohibition_scan?(%__MODULE__{remote_access: false}), do: true
  def prohibition_scan?(%__MODULE__{deploy: false}), do: true
  def prohibition_scan?(%__MODULE__{}), do: false

  @doc """
  Scope findings of a candidate change set: expected patterns that were not
  delivered and changed paths nobody authorized.

  Pure: it only compares data, so the same change set always produces the same
  findings. The patterns are compiled **once per call** and reused for both the
  delivered and the authorized comparison: recompiling a pattern per path would let
  a contract (256 expected and 256 allowed patterns) and a large candidate (5,000
  paths) spend millions of compilations on a single no-match case.
  """
  @spec path_findings(t(), [String.t()]) :: path_findings()
  def path_findings(%__MODULE__{} = contract, changed_paths) when is_list(changed_paths) do
    changed = changed_paths |> Enum.map(&String.replace_prefix(&1, "./", "")) |> Enum.uniq()
    expected = Enum.map(contract.expected_paths, &{&1, glob_regex(&1)})
    allowed = Enum.map(contract.allowed_extra_paths, &glob_regex/1)
    authorized = Enum.map(expected, &elem(&1, 1)) ++ allowed

    delivered = expected |> Enum.filter(&delivered?(&1, changed)) |> Enum.map(&elem(&1, 0))
    unexpected = Enum.reject(changed, fn path -> Enum.any?(authorized, &Regex.match?(&1, path)) end)
    missing = contract.expected_paths -- delivered

    %{
      expected: contract.expected_paths,
      delivered: delivered,
      changed: changed,
      unexpected: unexpected,
      findings: missing_findings(missing) ++ unexpected_findings(unexpected),
      truncated: length(missing) > @max_findings or length(unexpected) > @max_findings
    }
  end

  defp delivered?({_pattern, regex}, changed), do: Enum.any?(changed, &Regex.match?(regex, &1))

  @doc """
  Prohibition findings (`remote_access: false` / `deploy: false`) over the added
  lines of the candidate.
  """
  @spec prohibition_findings(t(), [%{path: String.t(), text: String.t()}]) :: prohibition_findings()
  def prohibition_findings(%__MODULE__{} = contract, added_lines) when is_list(added_lines) do
    findings = contract |> forbidden_kinds() |> Enum.map(&kind_findings(&1, added_lines))

    %{
      findings: Enum.flat_map(findings, & &1.findings),
      total: Enum.sum(Enum.map(findings, & &1.total)),
      truncated: Enum.any?(findings, & &1.truncated)
    }
  end

  @doc """
  Whether a pattern matches a repository-relative path.

  `*` matches inside one segment, `**` spans segments, `?` matches one character
  and a trailing `/` means `/**`. A whole change set goes through `path_findings/2`,
  which compiles each pattern once; this is the single-comparison form.
  """
  @spec path_match?(String.t(), String.t()) :: boolean()
  def path_match?(pattern, path) when is_binary(pattern) and is_binary(path) do
    Regex.match?(glob_regex(pattern), path)
  end

  defp forbidden_kinds(%__MODULE__{remote_access: false, deploy: false}), do: [:remote_access, :deploy]
  defp forbidden_kinds(%__MODULE__{remote_access: false}), do: [:remote_access]
  defp forbidden_kinds(%__MODULE__{deploy: false}), do: [:deploy]
  defp forbidden_kinds(%__MODULE__{}), do: []

  defp kind_findings(kind, added_lines) do
    matches = added_lines |> Enum.map(&match_line(kind, &1)) |> Enum.reject(&is_nil/1)

    %{
      kind: kind,
      findings: Enum.take(matches, @max_findings),
      total: length(matches),
      truncated: length(matches) > @max_findings
    }
  end

  defp match_line(kind, %{path: path, text: text}) do
    Enum.find_value(rules(kind), fn {regex, label} ->
      if Regex.match?(regex, text) do
        %Finding{
          code: finding_code(kind),
          category: :forbidden_operation,
          path: path,
          message: "#{label}: #{snippet(text)}"
        }
      end
    end)
  end

  defp rules(:deploy), do: @deploy_rules
  defp rules(:remote_access), do: @remote_access_rules

  defp finding_code(:deploy), do: :forbidden_deploy_detected
  defp finding_code(:remote_access), do: :forbidden_remote_access_detected

  defp snippet(text) do
    text |> String.trim() |> String.slice(0, @max_snippet_length)
  end

  defp missing_findings(missing) do
    missing
    |> Enum.take(@max_findings)
    |> Enum.map(
      &%Finding{
        code: :expected_path_missing,
        category: :scope,
        path: &1,
        message: "expected path `#{&1}` is not part of the candidate change set"
      }
    )
  end

  defp unexpected_findings(unexpected) do
    unexpected
    |> Enum.take(@max_findings)
    |> Enum.map(
      &%Finding{
        code: :unexpected_path_changed,
        category: :scope,
        path: &1,
        message: "changed path `#{&1}` is not in expected_paths nor allowed_extra_paths"
      }
    )
  end

  # --- extraction ---------------------------------------------------------

  defp candidate(body) do
    case declared(fenced_blocks(body)) do
      {:ok, []} -> unfenced(body)
      {:ok, [only]} -> {:contract, only}
      {:ok, many} -> {:error, {:ambiguous_contracts, length(many)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Which fenced blocks declare the contract. For a block within the size cap the answer
  # comes from the YAML parser (see `observe/1`), so the style of the key cannot change it,
  # and two keys — in one block or in two — are ambiguity instead of a silent choice. A block
  # above the size cap is not parsed: `classify/1` decides it on the raw text before this.
  defp declared(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, acc} ->
      case classify(block) do
        :absent -> {:cont, {:ok, acc}}
        {:contract, found} -> {:cont, {:ok, acc ++ [found]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The **order of the policies is the contract of this function**: the size cap is decided
  # first, over the raw text, so no later scan can turn an oversized block into `:absent` —
  # an anchor or a pseudo-fence outside a scalar makes no difference once the block is above
  # the cap (the block is not parsed and the size error comes from `decode/1`). Below the
  # cap, a block that carries a structural anchor is classified on its text **before** it is
  # parsed, because parsing it would expand the alias graph: an anchored key is refused (the
  # hint says the block claims the key) and an anchored block that claims nothing is simply
  # not the contract, as before.
  defp classify(block) when byte_size(block) > @max_contract_bytes do
    if raw_claim?(block), do: {:contract, {block, nil}}, else: :absent
  end

  defp classify(block) do
    case anchor(block) do
      nil ->
        classify_fenced(block)

      anchor ->
        if claimed?(block), do: {:error, {:anchors_not_supported, anchor}}, else: :absent
    end
  end

  # A block that claims the contract key must not contain a fence delimiter in its
  # **structure**: the line the author closed the block with was either accepted (and is
  # not part of the block) or rejected by the documented rule (a tab after the marker, a
  # text suffix, a shorter marker, another marker kind), and in that second case the YAML
  # library ends the `pipeline_contract` mapping **at that line** and reads whatever comes
  # after it as an unrelated top-level node — every field written there leaves the contract
  # in silence. A nested fence (` ``` ` inside the block) lands in the same shape. The
  # boundary of such a block is not the one that was written, so it cannot be the contract:
  # the block is refused (fail closed) instead of being parsed as a valid prefix. A block
  # that claims nothing is left alone — an unrelated code block may contain any fence.
  #
  # The decision is taken over the structure only (scalars and comments blanked), so a
  # fence *inside a scalar* (`notes: |` with an indented ` ``` `) stays text and does not
  # refuse the block. The marker reported is bounded to three characters: the answer is the
  # kind of delimiter, and the reason travels to the finding message.
  defp classify_fenced(block) do
    case fence_inside?(block) do
      nil -> classify_parsed(block)
      delimiter -> if claimed?(block), do: {:error, {:fence_inside_block, delimiter}}, else: :absent
    end
  end

  defp fence_inside?(block) do
    case Regex.run(@fence_line, without_scalars(block)) do
      [_line, delimiter] -> binary_part(delimiter, 0, 3)
      _other -> nil
    end
  end

  # The block is below the size cap: the oversized case was decided by `classify/1` on the
  # raw text, before any scan that reads the block through the scalar-blanking heuristic.
  # Here the **parser is the source of truth** for what the block declares: its count of
  # `pipeline_contract` keys decides presence and duplication, and a mention inside a
  # scalar or a comment is data, not a declaration. The text only **widens the failure
  # set**, in the two directions where the parser alone would report absence:
  #
  #   * the document cannot be read at all (`:invalid`): the raw text decides between
  #     "unrelated block" (`:absent`) and "a possible declaration that must fail closed" —
  #     never a silent absence;
  #   * the document is readable but reads **no** contract key while its text declares one
  #     in key position: the token was absorbed by a malformed scalar
  #     (`foo:'unterminated` turns the following `pipeline_contract:` into part of a
  #     longer plain key) or it is a declaration nested in another mapping, and the block
  #     is a contract candidate whose decode reports the missing key instead of being
  #     reported as absent.
  defp classify_parsed(block) do
    case observe(block) do
      {:ok, %{contracts: 0} = observation} ->
        if unread_declaration?(block, observation), do: {:contract, {block, nil}}, else: :absent

      {:ok, %{contracts: 1} = observation} ->
        {:contract, {block, observation}}

      {:ok, %{contracts: many}} ->
        {:error, {:duplicate_contract_key, many}}

      :invalid ->
        if raw_claim?(block), do: {:contract, {block, nil}}, else: :absent
    end
  end

  # What the decoder read is what separates a declaration from data: a scalar (a block
  # scalar, a quoted value, a comment) holds no key at all, while an absorbed token — or a
  # `pipeline_contract:` nested inside another mapping — is a key the decoder **did** read.
  # Claiming needs both halves: the key position in the text (a key named
  # `pipeline_contract_notes` is not the contract) and the decoder's key (a token inside a
  # value is not a declaration).
  defp unread_declaration?(block, %{absorbed: true}), do: raw_claim?(block)
  defp unread_declaration?(_block, _observation), do: false

  # An unfenced body is a contract only when it starts with the key (the same shape
  # the YAML decoder reads): a mention of the key in the middle of the body is prose,
  # not a declaration.
  defp unfenced(body) do
    trimmed = String.trim_leading(body)

    if claimed_start?(trimmed), do: classify(trimmed), else: :absent
  end

  defp decode_found({block, observation}) do
    with :ok <- duplicate_field(observation), do: decode(block)
  end

  # The decoder keeps one of two equal keys *inside* the mapping silently, so a
  # repeated field is refused: the contract is data and ambiguity is not acceptable.
  # The count of `pipeline_contract` keys was already settled by `classify/1`, and a
  # `nil` observation means the block was above the size cap (which `decode/1`
  # reports as `contract_too_large`). The reported field follows the schema order,
  # so the finding is deterministic.
  defp duplicate_field(nil), do: :ok
  defp duplicate_field(%{fields: []}), do: :ok

  defp duplicate_field(%{fields: [field | _rest]}) do
    {:error, {:pipeline_contract_invalid, {:duplicate_field, field}}}
  end

  # What the YAML parser sees, before the decoder collapses duplicates: every
  # document of the block as a keyword list (`maps_as_keywords`), so the contract key
  # and the fields of its mapping are counted *semantically* — `"scope_mode"`,
  # `'scope_mode'`, `? scope_mode` and `scope_mode` are the same key, and two equal
  # keys are two keys. The parser is only asked what it reads; the value is decoded
  # by `decode/1`, which is what the schema validates. `YamlElixir` never raises on
  # the document: it converts a parser failure (including an internal error) into
  # `{:error, _}`, which is this function's `:invalid`.
  defp observe(block) do
    case YamlElixir.read_all_from_string(block, maps_as_keywords: true) do
      {:ok, documents} -> {:ok, observed(documents)}
      {:error, _reason} -> :invalid
    end
  end

  defp observed(documents) do
    keys =
      documents
      |> Enum.flat_map(&mapping_pairs/1)
      |> Enum.filter(fn {key, _value} -> key == @contract_field end)

    %{
      contracts: length(keys),
      fields: Enum.flat_map(keys, fn {_key, value} -> duplicated_fields(value) end),
      # A key the decoder read that *contains* the contract token instead of being it: the
      # shape a malformed scalar leaves behind when it absorbs a declaration into a longer
      # plain key. It is `false` for a block whose mention is inside a scalar, because a
      # value holds no key at all.
      absorbed: Enum.any?(documents, &key_containing(&1, @contract_field))
    }
  end

  # Walks every key the decoder read, at any depth: a nested mapping is structure too, so a
  # `pipeline_contract:` inside another mapping is accounted for like an absorbed token.
  # The decoder returns keyword lists for mappings (`maps_as_keywords: true`), which is also
  # all the rest of this module understands, so anything else is not a key carrier.
  defp key_containing(value, token) when is_list(value) do
    Enum.any?(value, fn
      {key, nested} when is_binary(key) -> String.contains?(key, token) or key_containing(nested, token)
      other -> key_containing(other, token)
    end)
  end

  defp key_containing(_value, _token), do: false

  defp duplicated_fields(value) do
    counts = value |> mapping_pairs() |> Enum.frequencies_by(&elem(&1, 0))

    Enum.filter(@fields, &(Map.get(counts, &1, 0) > 1))
  end

  defp mapping_pairs(pairs) when is_list(pairs) do
    Enum.filter(pairs, &(is_tuple(&1) and tuple_size(&1) == 2 and is_binary(elem(&1, 0))))
  end

  defp mapping_pairs(_other), do: []

  # The claim over the text with the **scalar content blanked** (comments, quoted values,
  # block scalars). It is only used where the block must not be parsed (a structural
  # anchor, a block that still holds a fence delimiter) and for the start of an unfenced
  # body, so a `pipeline_contract:` written inside a scalar cannot claim the contract or
  # route the block to the anchor refusal — while a quoted key in key position
  # (`"pipeline_contract":`) is unquoted first and stays visible. A block above the size
  # cap does **not** use this reading: it is judged on the raw text, like an unreadable
  # one, so a scalar cannot hide a declaration by making the block too big either.
  defp claimed?(block), do: Regex.match?(@contract_key, claim_text(block))

  defp claimed_start?(block), do: Regex.match?(@contract_key_start, claim_text(block))

  # The claim over the **raw** text, used for a block that cannot be read at all: nothing
  # is blanked, so no heuristic about scalars can hide a declaration. A comment line does
  # not match (the key shape is anchored at the start of a line or in a flow position), so
  # prose and comments alone still leave the body unconfigured; the cost of the
  # conservative reading is a scalar of an *unreadable* block that mentions the key in key
  # position — an error instead of a silent absence (declared in
  # `docs/fork/acceptance-contract.md`).
  defp raw_claim?(block) do
    block |> unquote_contract_key() |> then(&Regex.match?(@contract_key, &1))
  end

  defp claim_text(block) do
    block
    |> unquote_contract_key()
    |> without_scalars()
  end

  defp unquote_contract_key(block) do
    Regex.replace(@quoted_contract_key, block, "\\1\\2\\3\\4pipeline_contract\\5")
  end

  defp anchor(block) do
    case Regex.run(@anchor_token, without_scalars(block)) do
      nil -> nil
      [match | _rest] -> String.trim(match)
    end
  end

  # The block with every comment, quoted scalar and block-scalar content blanked out, so
  # the decisions that must not parse the block — refusing a structural anchor and the size
  # cap — only see what YAML reads as structure: inside a scalar or a comment an `&` or a
  # `pipeline_contract:` is data
  # (`- "docs/R&D &notes.md"`, `# see &notes`, `notes: |` with an indented example),
  # never an indicator or a key. A comment is only a comment where YAML allows one
  # (after a blank or at the start of a line) and a quoted scalar only begins where a
  # node may begin (after a blank or after `[`/`{`/`,`), so no state is entered that the
  # decoder would not enter — a state entered too eagerly is what could blank a line
  # that declares the contract. Blanking keeps the position of what is left, which is
  # what the token class of `@anchor_token` needs around the `&`; it works on bytes, so
  # a path that is not valid UTF-8 cannot make it crash either.
  defp without_scalars(block) do
    block
    |> :binary.bin_to_list()
    |> scan_scalars()
    |> :binary.list_to_bin()
    |> blank_block_scalars()
  end

  # The reach of a quoted scalar across physical lines (only a comment ends at the
  # newline, so the quote state survives it) is what keeps the continuation of a
  # **valid** scalar out of the scan — but it is only trusted while every quote of the
  # block closes. A quote that never closes is not a scalar the decoder could read, so
  # it may not blank the lines after it: the blanking is redone **line by line**, where
  # no state survives a newline, and a declaration written after a malformed scalar
  # stays visible. That is the fail-closed reading of `foo:'unterminated` (a plain
  # scalar, not a quoted one) or of `foo: 'unterminated` (an unterminated quoted one):
  # neither can hide a real `pipeline_contract:` in the same block.
  defp scan_scalars(characters) do
    case blank_scalars(characters, :document, :plain, ?\n, []) do
      {_text, :open} ->
        {text, _state} = blank_scalars(characters, :lines, :plain, ?\n, [])
        text

      {text, :closed} ->
        text
    end
  end

  defp blank_scalars([], _mode, state, _previous, acc), do: {Enum.reverse(acc), closed(state)}

  # In `:lines` mode nothing survives the end of the line: what comes before a line can
  # never hide what that line declares.
  defp blank_scalars([?\n | rest], :lines, _state, _previous, acc) do
    blank_scalars(rest, :lines, :plain, ?\n, [?\n | acc])
  end

  defp blank_scalars([?\n | rest], :document, :comment, _previous, acc) do
    blank_scalars(rest, :document, :plain, ?\n, [?\n | acc])
  end

  # A quoted scalar may span physical lines, so the quote state survives this one in
  # `:document` mode: the continuation of `key: "line one\n  line two"` is scalar
  # content, never structure.
  defp blank_scalars([?\n | rest], :document, state, _previous, acc) do
    blank_scalars(rest, :document, state, ?\n, [?\n | acc])
  end

  defp blank_scalars([?# | rest], mode, :plain, previous, acc) when previous in [?\s, ?\t, ?\n] do
    blank_scalars(rest, mode, :comment, ?#, [" " | acc])
  end

  defp blank_scalars([character | rest], mode, :plain, previous, acc)
       when previous in [?\s, ?\t, ?\n, ?[, ?,, ?{] do
    case character do
      ?" -> blank_scalars(rest, mode, :double, ?", [" " | acc])
      ?' -> blank_scalars(rest, mode, :single, ?', [" " | acc])
      other -> blank_scalars(rest, mode, :plain, other, [other | acc])
    end
  end

  defp blank_scalars([character | rest], mode, :plain, _previous, acc) do
    blank_scalars(rest, mode, :plain, character, [character | acc])
  end

  defp blank_scalars([?" | rest], mode, :double, _previous, acc), do: blank_scalars(rest, mode, :plain, ?", [" " | acc])
  defp blank_scalars([?\\, _escaped | rest], mode, :double, _previous, acc), do: blank_scalars(rest, mode, :double, ?x, ["  " | acc])
  defp blank_scalars([_character | rest], mode, :double, previous, acc), do: blank_scalars(rest, mode, :double, previous, [" " | acc])

  # In a single-quoted scalar the escaped quote is `''`, so a lone `'` is the only one
  # that closes it: `'docs/it''s &notes.md'` is one scalar, not a scalar plus a stray
  # `&notes`.
  defp blank_scalars([?', ?' | rest], mode, :single, _previous, acc), do: blank_scalars(rest, mode, :single, ?', ["  " | acc])
  defp blank_scalars([?' | rest], mode, :single, _previous, acc), do: blank_scalars(rest, mode, :plain, ?', [" " | acc])
  defp blank_scalars([_character | rest], mode, :single, previous, acc), do: blank_scalars(rest, mode, :single, previous, [" " | acc])

  defp blank_scalars([_character | rest], mode, :comment, previous, acc) do
    blank_scalars(rest, mode, :comment, previous, [" " | acc])
  end

  defp closed(:single), do: :open
  defp closed(:double), do: :open
  defp closed(_state), do: :closed

  # The content of a block scalar (`key: |`, `key: >-`, `- |2`) is text, not structure:
  # it is blanked too, so an indented `pipeline_contract:` or `&example` inside it can
  # neither claim the contract key nor be read as an anchor. `indent` is the
  # indentation of the line that opened the scalar: every following line that is blank
  # or more indented belongs to it (YAML ends the scalar at the first line that is
  # not), and an explicit indentation indicator (`|2`) makes the content narrower than
  # that bound, so the bound is what is used. Blanking preserves each line's length.
  defp blank_block_scalars(blanked) do
    {lines, _indent} =
      blanked
      |> String.split("\n")
      |> Enum.map_reduce(nil, fn line, indent ->
        if indent != nil and (blank_content?(line) or line_indent(line) > indent) do
          {String.duplicate(" ", byte_size(line)), indent}
        else
          {line, block_scalar_indent(line)}
        end
      end)

    Enum.join(lines, "\n")
  end

  defp blank_content?(line), do: String.trim(line) == ""

  defp block_scalar_indent(line) do
    if Regex.match?(@block_indicator, line), do: line_indent(line), else: nil
  end

  defp line_indent(line) do
    line |> :binary.bin_to_list() |> Enum.take_while(&(&1 in [?\s, ?\t])) |> length()
  end

  # A fence that never closes still counts as a block: a malformed code fence must
  # not be the way a contract silently stops being enforced.
  defp fenced_blocks(body) do
    {blocks, current, _open} =
      body
      |> String.split(~r/\R/)
      |> Enum.reduce({[], [], nil}, &fence_step/2)

    blocks = if current == [], do: blocks, else: [Enum.reverse(current) | blocks]

    blocks
    |> Enum.reverse()
    |> Enum.map(&Enum.join(&1, "\n"))
  end

  defp fence_step(line, {blocks, current, nil}) do
    case open_fence(line) do
      nil -> {blocks, current, nil}
      delimiter -> {blocks, [], delimiter}
    end
  end

  defp fence_step(line, {blocks, current, open}) do
    case close_fence(line) do
      nil ->
        {blocks, [line | current], open}

      delimiter ->
        if closes_fence?(delimiter, open) do
          {[Enum.reverse(current) | blocks], [], nil}
        else
          {blocks, [line | current], open}
        end
    end
  end

  # CommonMark: the closing fence is the same marker kind and is at least as long as the
  # opening one, so ` ``` ` opened with three backticks and closed with four closes the
  # block instead of leaving it open (which would feed the following prose to YAML).
  defp closes_fence?(delimiter, open) do
    :binary.first(delimiter) == :binary.first(open) and byte_size(delimiter) >= byte_size(open)
  end

  # The opening fence accepts an info string (` ```yaml `); the closing one carries
  # nothing after the marker but whitespace, so a line such as ` ```not-a-close ` is
  # **content** and cannot close the block: a pseudo-close would otherwise let the
  # parser read a valid prefix and ignore every field after it.
  defp open_fence(line) do
    case Regex.run(@fence, line) do
      [_match, delimiter] -> delimiter
      _other -> nil
    end
  end

  defp close_fence(line) do
    case Regex.run(@closing_fence, line) do
      [_match, delimiter] -> delimiter
      _other -> nil
    end
  end

  # --- schema -------------------------------------------------------------

  defp decode(yaml) when byte_size(yaml) > @max_contract_bytes do
    {:error, {:pipeline_contract_invalid, {:contract_too_large, byte_size(yaml)}}}
  end

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"pipeline_contract" => contract}} when is_map(contract) -> validate(contract)
      {:ok, %{"pipeline_contract" => other}} -> {:error, {:pipeline_contract_invalid, {:not_a_mapping, inspect(other)}}}
      {:ok, _other} -> {:error, {:pipeline_contract_invalid, :missing_pipeline_contract_key}}
      {:error, reason} -> {:error, {:pipeline_contract_invalid, {:invalid_yaml, reason}}}
    end
  end

  defp validate(raw) do
    with :ok <- reject_unknown_fields(raw),
         {:ok, version} <- fetch_version(raw),
         {:ok, scope_mode} <- fetch_scope_mode(raw),
         {:ok, expected} <- fetch_patterns(raw, "expected_paths"),
         :ok <- require_expected(expected, scope_mode),
         {:ok, allowed} <- fetch_patterns(raw, "allowed_extra_paths"),
         {:ok, evidence} <- fetch_evidence(raw),
         {:ok, remote_access} <- fetch_flag(raw, "remote_access"),
         {:ok, deploy} <- fetch_flag(raw, "deploy") do
      {:ok,
       %__MODULE__{
         version: version,
         scope_mode: scope_mode,
         expected_paths: expected,
         allowed_extra_paths: allowed,
         required_evidence: evidence,
         remote_access: remote_access,
         deploy: deploy
       }}
    end
  end

  defp reject_unknown_fields(raw) do
    case Enum.sort(Map.keys(raw) -- @fields) do
      [] -> :ok
      unknown -> {:error, {:pipeline_contract_invalid, {:unknown_fields, unknown}}}
    end
  end

  defp fetch_version(raw) do
    case Map.get(raw, "version") do
      @version -> {:ok, @version}
      other -> {:error, {:pipeline_contract_invalid, {:unsupported_version, other}}}
    end
  end

  defp fetch_scope_mode(raw) do
    case Map.get(raw, "scope_mode") do
      "strict" -> {:ok, :strict}
      "advisory" -> {:ok, :advisory}
      other -> {:error, {:pipeline_contract_invalid, {:invalid_scope_mode, other}}}
    end
  end

  defp require_expected([], :strict), do: {:error, {:pipeline_contract_invalid, :strict_requires_expected_paths}}
  defp require_expected(_expected, _scope_mode), do: :ok

  defp fetch_patterns(raw, key) do
    case Map.get(raw, key) do
      nil -> {:ok, []}
      patterns when is_list(patterns) -> normalize_patterns(patterns, key)
      other -> {:error, {:pipeline_contract_invalid, {:invalid_field, key, inspect(other)}}}
    end
  end

  defp normalize_patterns(patterns, key) when length(patterns) > @max_items do
    {:error, {:pipeline_contract_invalid, {:too_many_items, key, length(patterns)}}}
  end

  defp normalize_patterns(patterns, key) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case normalize_pattern(pattern) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, {:pipeline_contract_invalid, {:invalid_pattern, key, reason}}}}
      end
    end)
  end

  defp normalize_pattern(pattern) when is_binary(pattern) do
    cond do
      not String.valid?(pattern) -> {:error, :not_utf8}
      String.trim(pattern) == "" -> {:error, :empty_pattern}
      String.length(pattern) > @max_pattern_length -> {:error, :pattern_too_long}
      String.contains?(pattern, "\\") -> {:error, :invalid_path_separator}
      String.starts_with?(pattern, "/") -> {:error, :absolute_pattern}
      Enum.any?(Path.split(pattern), &(&1 == "..")) -> {:error, :escaping_pattern}
      true -> {:ok, String.replace_suffix(pattern, "/", "/**")}
    end
  end

  defp normalize_pattern(_pattern), do: {:error, :not_a_string}

  defp fetch_evidence(raw) do
    case Map.get(raw, "required_evidence") do
      nil -> {:ok, []}
      names when is_list(names) -> normalize_evidence(names)
      other -> {:error, {:pipeline_contract_invalid, {:invalid_field, "required_evidence", inspect(other)}}}
    end
  end

  defp normalize_evidence(names) when length(names) > @max_items do
    {:error, {:pipeline_contract_invalid, {:too_many_items, "required_evidence", length(names)}}}
  end

  defp normalize_evidence(names) do
    if Enum.all?(names, &valid_evidence_name?/1) do
      {:ok, Enum.uniq(names)}
    else
      {:error, {:pipeline_contract_invalid, {:invalid_evidence, Enum.reject(names, &valid_evidence_name?/1)}}}
    end
  end

  defp valid_evidence_name?(name) when is_binary(name) do
    String.length(name) <= @max_evidence_name_length and Regex.match?(@evidence_name, name)
  end

  defp valid_evidence_name?(_name), do: false

  defp fetch_flag(raw, key) do
    case Map.get(raw, key) do
      nil -> {:ok, false}
      flag when is_boolean(flag) -> {:ok, flag}
      other -> {:error, {:pipeline_contract_invalid, {:invalid_flag, key, inspect(other)}}}
    end
  end

  # --- glob matching ------------------------------------------------------

  # `u` (Unicode) is not optional: without it `?` would match one **byte** and a
  # documented "one character" would fail on a UTF-8 path (`docs/?.md` vs
  # `docs/é.md`), and both the patterns and the paths are UTF-8.
  defp glob_regex(pattern) do
    pattern
    |> String.replace_suffix("/", "/**")
    |> glob_source()
    |> Regex.compile!("u")
  end

  defp glob_source(pattern) do
    "^" <> do_glob_source(pattern, "") <> "$"
  end

  defp do_glob_source(<<>>, acc), do: acc
  defp do_glob_source(<<"**/", rest::binary>>, acc), do: do_glob_source(rest, acc <> "(?:[^/]+/)*")
  defp do_glob_source(<<"**", rest::binary>>, acc), do: do_glob_source(rest, acc <> ".*")
  defp do_glob_source(<<"*", rest::binary>>, acc), do: do_glob_source(rest, acc <> "[^/]*")
  defp do_glob_source(<<"?", rest::binary>>, acc), do: do_glob_source(rest, acc <> "[^/]")

  defp do_glob_source(<<character::utf8, rest::binary>>, acc) do
    do_glob_source(rest, acc <> Regex.escape(<<character::utf8>>))
  end
end

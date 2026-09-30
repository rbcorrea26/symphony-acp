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
  """

  @version 1
  @fields ~w(version scope_mode expected_paths allowed_extra_paths required_evidence remote_access deploy)
  @contract_key ~r/^[ \t]*pipeline_contract[ \t]*:/m
  @fence ~r/^[ \t]*(`{3,}|~{3,})/
  @evidence_name ~r/^[a-z0-9][a-z0-9._-]*$/

  @max_pattern_length 512
  @max_items 256
  @max_evidence_name_length 64
  @max_contract_bytes 65_536
  @max_findings 5
  @max_snippet_length 80

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

  @type violation :: %{kind: atom(), detail: String.t()}

  @type path_findings :: %{
          expected: [String.t()],
          delivered: [String.t()],
          changed: [String.t()],
          unauthorized: [String.t()],
          violations: [violation()],
          truncated: boolean()
        }

  @type prohibition_findings :: %{
          violations: [violation()],
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
  """
  @spec parse(String.t() | nil) :: :absent | {:ok, t()} | {:error, {:pipeline_contract_invalid, term()}}
  def parse(nil), do: :absent

  def parse(body) when is_binary(body) do
    case candidate(body) do
      :absent -> :absent
      {:ok, yaml} -> decode(yaml)
      {:error, reason} -> {:error, {:pipeline_contract_invalid, reason}}
    end
  end

  @doc "Whether a violation of this contract fails the acceptance instead of only being reported."
  @spec strict?(t()) :: boolean()
  def strict?(%__MODULE__{scope_mode: scope_mode}), do: scope_mode == :strict

  @doc """
  Scope findings of a candidate change set: expected patterns that were not
  delivered and changed paths nobody authorized.

  Pure: it only compares data, so the same change set always produces the same
  findings.
  """
  @spec path_findings(t(), [String.t()]) :: path_findings()
  def path_findings(%__MODULE__{} = contract, changed_paths) when is_list(changed_paths) do
    changed = changed_paths |> Enum.map(&String.replace_prefix(&1, "./", "")) |> Enum.uniq()

    delivered =
      Enum.filter(contract.expected_paths, fn pattern -> Enum.any?(changed, &path_match?(pattern, &1)) end)

    unauthorized = Enum.reject(changed, &authorized?(contract, &1))
    missing = contract.expected_paths -- delivered

    %{
      expected: contract.expected_paths,
      delivered: delivered,
      changed: changed,
      unauthorized: unauthorized,
      violations: missing_violations(missing) ++ unauthorized_violations(unauthorized),
      truncated: length(missing) > @max_findings or length(unauthorized) > @max_findings
    }
  end

  @doc """
  Prohibition findings (`remote_access: false` / `deploy: false`) over the added
  lines of the candidate.
  """
  @spec prohibition_findings(t(), [%{path: String.t(), text: String.t()}]) :: prohibition_findings()
  def prohibition_findings(%__MODULE__{} = contract, added_lines) when is_list(added_lines) do
    findings = contract |> forbidden_kinds() |> Enum.map(&kind_findings(&1, added_lines))

    %{
      violations: Enum.flat_map(findings, & &1.violations),
      total: Enum.sum(Enum.map(findings, & &1.total)),
      truncated: Enum.any?(findings, & &1.truncated)
    }
  end

  @doc """
  Whether a pattern matches a repository-relative path.

  `*` matches inside one segment, `**` spans segments, `?` matches one character
  and a trailing `/` means `/**`.
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
      violations: Enum.take(matches, @max_findings),
      total: length(matches),
      truncated: length(matches) > @max_findings
    }
  end

  defp match_line(kind, %{path: path, text: text}) do
    Enum.find_value(rules(kind), fn {regex, label} ->
      if Regex.match?(regex, text) do
        %{kind: kind, detail: "#{label} in #{path}: #{snippet(text)}"}
      end
    end)
  end

  defp rules(:deploy), do: @deploy_rules
  defp rules(:remote_access), do: @remote_access_rules

  defp snippet(text) do
    text |> String.trim() |> String.slice(0, @max_snippet_length)
  end

  defp missing_violations(missing) do
    missing
    |> Enum.take(@max_findings)
    |> Enum.map(&%{kind: :expected_path_untouched, detail: "expected path `#{&1}` was not delivered by the candidate"})
  end

  defp unauthorized_violations(unauthorized) do
    unauthorized
    |> Enum.take(@max_findings)
    |> Enum.map(&%{kind: :unauthorized_path, detail: "changed path `#{&1}` is outside the contract scope"})
  end

  defp authorized?(contract, path) do
    Enum.any?(contract.expected_paths ++ contract.allowed_extra_paths, fn pattern -> path_match?(pattern, path) end)
  end

  # --- extraction ---------------------------------------------------------

  defp candidate(body) do
    case body |> fenced_blocks() |> Enum.filter(&Regex.match?(@contract_key, &1)) do
      [only] -> {:ok, only}
      [] -> unfenced(body)
      many -> {:error, {:ambiguous_contracts, length(many)}}
    end
  end

  defp unfenced(body) do
    trimmed = String.trim_leading(body)
    if Regex.match?(~r/^[ \t]*pipeline_contract[ \t]*:/, trimmed), do: {:ok, trimmed}, else: :absent
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

  defp fence_step(line, {blocks, current, open}) do
    case {fence_delimiter(line), open} do
      {nil, nil} -> {blocks, current, nil}
      {nil, marker} -> {blocks, [line | current], marker}
      {delimiter, delimiter} -> {[Enum.reverse(current) | blocks], [], nil}
      {delimiter, nil} -> {blocks, [], delimiter}
      {_other, marker} -> {blocks, [line | current], marker}
    end
  end

  defp fence_delimiter(line) do
    case Regex.run(@fence, line) do
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

  defp glob_regex(pattern) do
    pattern
    |> String.replace_suffix("/", "/**")
    |> glob_source()
    |> Regex.compile!()
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

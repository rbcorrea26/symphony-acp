defmodule SymphonyElixir.Delivery.Acceptance.Result do
  @moduledoc """
  Structured verdict of the acceptance layer — never a boolean.

  The acceptance answers "was the issue satisfied?" and the answer needs to be
  auditable by a human and consumable by the next increment (the review state
  machine and the architect runner), so it comes as data:

    * `status` — what the layer decided: `:pass`, `:fail` (blocking, `strict`
      mode or an unenforceable contract), `:advisory` (findings reported without
      blocking), `:not_configured` (the issue declares no contract: the layer is
      not configured, which is the backward-compatible case) or
      `:not_applicable` (there is no candidate change set to accept);
    * `contract_version` / `mode` — which contract was in force (`nil` when there
      is none);
    * `findings` — deterministic `code`, `category`, human `message` and optional
      `path`; no score and no ranking;
    * `evidence` — the evidence records observed for this candidate (name,
      status, command; never output, duration or transient counts);
    * `change_set` — the candidate paths the scope was compared against;
    * `limits` — what the layer **did not** verify, so nobody reads a pass as a
      proof (see `docs/fork/acceptance-contract.md`).
  """

  alias SymphonyElixir.PipelineContract.Finding

  @type status :: :pass | :fail | :advisory | :not_configured | :not_applicable
  @type mode :: :strict | :advisory | nil

  @type limit ::
          :prohibition_scan_is_heuristic
          | :change_scan_truncated
          | :content_not_verified

  @type evidence_result :: %{name: String.t(), status: atom(), command: String.t() | nil}

  @type t :: %__MODULE__{
          status: status(),
          contract_version: pos_integer() | nil,
          mode: mode(),
          findings: [Finding.t()],
          evidence: [evidence_result()],
          change_set: %{
            expected: [String.t()],
            delivered: [String.t()],
            changed: [String.t()],
            unexpected: [String.t()]
          },
          limits: [limit()]
        }

  @derive {Jason.Encoder, only: [:status, :contract_version, :mode, :findings, :evidence, :limits]}
  defstruct status: :not_configured,
            contract_version: nil,
            mode: nil,
            findings: [],
            evidence: [],
            change_set: %{expected: [], delivered: [], changed: [], unexpected: []},
            limits: []

  @severity %{not_configured: 0, not_applicable: 1, pass: 2, advisory: 3, fail: 4}

  @doc "The issue declares no contract: the acceptance layer is not configured."
  @spec not_configured() :: t()
  def not_configured, do: %__MODULE__{}

  @doc "There is no candidate change set to accept (nothing new to publish)."
  @spec not_applicable(keyword()) :: t()
  def not_applicable(opts) do
    %__MODULE__{
      status: :not_applicable,
      contract_version: Keyword.get(opts, :contract_version),
      mode: Keyword.get(opts, :mode),
      limits: Keyword.get(opts, :limits, [])
    }
  end

  @doc """
  A contract that cannot be enforced fails the acceptance: the pipeline refuses
  what it does not understand instead of guessing (`mode` is unknown, so nothing
  is reported as advisory).
  """
  @spec invalid_contract(term()) :: t()
  def invalid_contract(reason) do
    %__MODULE__{
      status: :fail,
      findings: [
        %Finding{
          code: :invalid_contract,
          category: :contract,
          message: "pipeline_contract is not enforceable: #{inspect(reason)}"
        }
      ]
    }
  end

  @doc """
  The verdict of one phase: no findings is a pass, findings are a failure in
  `strict` and a reported divergence in `advisory`.
  """
  @spec evaluated(keyword()) :: t()
  def evaluated(opts) do
    mode = Keyword.fetch!(opts, :mode)
    findings = Keyword.get(opts, :findings, [])

    %__MODULE__{
      status: status_for(mode, findings),
      contract_version: Keyword.fetch!(opts, :contract_version),
      mode: mode,
      findings: findings,
      evidence: Keyword.get(opts, :evidence, []),
      change_set: Keyword.get(opts, :change_set, %__MODULE__{}.change_set),
      limits: Keyword.get(opts, :limits, [])
    }
  end

  @doc "Severity order used to merge the phases: `:fail` wins over `:advisory`, which wins over `:pass`."
  @spec worst(status(), status()) :: status()
  def worst(left, right) do
    if severity(left) >= severity(right), do: left, else: right
  end

  @doc "Numeric severity of a status (total order, no score of the findings)."
  @spec severity(status()) :: non_neg_integer()
  def severity(status), do: Map.fetch!(@severity, status)

  @doc "Joins the two phases of a run into the single verdict of the delivery."
  @spec merge(t(), t()) :: t()
  def merge(scope, evidence) do
    %__MODULE__{
      status: worst(scope.status, evidence.status),
      contract_version: scope.contract_version || evidence.contract_version,
      mode: scope.mode || evidence.mode,
      findings: scope.findings ++ evidence.findings,
      evidence: evidence.evidence,
      change_set: scope.change_set,
      limits: Enum.uniq(scope.limits ++ evidence.limits)
    }
  end

  @doc "Whether the verdict blocks the delivery."
  @spec blocking?(t()) :: boolean()
  def blocking?(%__MODULE__{status: :fail}), do: true
  def blocking?(%__MODULE__{}), do: false

  defp status_for(_mode, []), do: :pass
  defp status_for(:strict, _findings), do: :fail
  defp status_for(:advisory, _findings), do: :advisory
end

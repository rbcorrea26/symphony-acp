defmodule SymphonyElixir.Delivery do
  @moduledoc """
  Delivery stage of the agent run: gates, draft pull request, CI, candidate and handoff.

  It is the boundary between "the agent finished its turns" and "a human has a
  candidate to review". It is opt-in (`delivery.enabled`, default `false`), so an
  upstream workflow keeps the upstream behavior.

  Properties this stage must keep:

    * the **project** owns its gates: the command comes from the workflow
      (`delivery.gates`), never from the platform, and a non-zero exit fails the
      run instead of publishing a "almost ready" pull request;
    * **three independent layers** run before a candidate is promoted: the
      acceptance contract of the issue (`SymphonyElixir.Delivery.Acceptance`:
      "was the issue satisfied?"), the repository gates ("is the repository still
      valid?") and the CI ("did the published candidate pass?"). Green gates do
      not replace acceptance;
    * the only write the pipeline makes towards the consumer repository is a
      branch plus a **draft** pull request on top of `delivery.base_branch`;
      never a push to the base branch, never a force push, never a merge;
    * **candidate stable** is derived, never invented: it is the head SHA of the
      delivery branch whose local gates passed, whose CI check runs all concluded
      successfully and which was still the branch head when the observation
      finished. A push that lands during the observation invalidates the candidate:
      the new head is not the commit the acceptance and the local gates validated,
      so the run fails (`delivery_candidate_replaced`) instead of attaching the
      verdict of one candidate to another;
    * state is recovered from GitHub, which is what makes retry and
      reconciliation idempotent: a delivery that finds the open pull request of
      the branch reconciles it instead of creating a second one, and a second
      run over the same candidate does not repeat the push or the handoff. That
      resumed candidate is **accepted again**, though: the acceptance reads it from
      git (the branch head against the base branch) and executes the evidence of the
      contract in force, so a contract that changed after the publication is
      re-evaluated instead of being reused;
    * the one-shot review is requested **after** the candidate is stable and its
      unavailability is recorded, never fabricated and never a reason to block
      the handoff;
    * `ready-for-human` removes the tracker entry label, so the next poll cycle
      stops dispatching the issue, and posts the handoff comment only once per
      candidate.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Delivery.Acceptance
  alias SymphonyElixir.Delivery.Acceptance.Result
  alias SymphonyElixir.Delivery.Gates
  alias SymphonyElixir.Delivery.Git
  alias SymphonyElixir.Delivery.GitHub
  alias SymphonyElixir.Tracker.Issue

  @type result :: %{
          status: :ready_for_human,
          branch: String.t(),
          candidate_sha: String.t(),
          pull: GitHub.pull(),
          checks: map(),
          review: :requested | :unavailable | :disabled | :reconciled,
          issue_number: integer(),
          contract: Result.t()
        }

  @spec run(Path.t(), Issue.t(), keyword()) :: :disabled | {:ok, result()} | {:error, term()}
  def run(workspace, %Issue{} = issue, opts \\ []) do
    delivery = Config.settings!().delivery

    if delivery.enabled do
      deliver(workspace, issue, delivery, Keyword.get(opts, :worker_host), Keyword.get(opts, :github, []))
    else
      :disabled
    end
  end

  @doc """
  Dispatch preflight for the `delivery` config block.

  A delivery stage publishes to GitHub from the local workspace, so enabling it
  with a GitHub tracker and without remote workers is required; the combination
  fails preflight instead of dispatching a worker that cannot deliver.
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{delivery: %{enabled: true}} = settings) do
    with :ok <- require_github_tracker(settings),
         :ok <- require_local_worker(settings) do
      require_gates(settings)
    end
  end

  def validate_config(_settings), do: :ok

  defp require_gates(%{delivery: %{gates: gates}}) when is_binary(gates) do
    if String.trim(gates) == "", do: {:error, :missing_delivery_gates}, else: :ok
  end

  defp require_gates(_settings), do: {:error, :missing_delivery_gates}

  @spec issue_number(Issue.t()) :: {:ok, integer()} | {:error, term()}
  def issue_number(%Issue{id: id}) do
    case Integer.parse(to_string(id)) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> {:error, :delivery_requires_github_issue_id}
    end
  end

  @spec branch_name(Issue.t(), map()) :: String.t()
  def branch_name(%Issue{identifier: identifier}, delivery) do
    suffix =
      identifier
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim("-")

    delivery.branch_prefix <> suffix
  end

  defp require_github_tracker(%{tracker: %{kind: "github"}}), do: :ok
  defp require_github_tracker(_settings), do: {:error, :delivery_requires_github_tracker}

  defp require_local_worker(%{worker: %{ssh_hosts: []}}), do: :ok
  defp require_local_worker(%{worker: %{ssh_hosts: _hosts}}), do: {:error, :delivery_requires_local_worker}

  defp deliver(_workspace, _issue, _delivery, worker_host, _github_opts) when is_binary(worker_host) do
    {:error, {:delivery_requires_local_worker, worker_host}}
  end

  defp deliver(workspace, issue, delivery, nil, github_opts) do
    settings = Config.settings!()

    # Order matters and is deliberate: the acceptance contract decides scope over
    # the candidate (cheap, and a blocking finding must not spend a gates run), the
    # gates then say whether the repository is still valid, and only then the
    # evidence required by the issue is executed (it uses the gates timeout).
    # Green gates never rescue a failed acceptance: the failure comes from here.
    #
    # The scope is evaluated again at the end because the gates and the evidence
    # commands run *inside* the workspace and may create or change files: what
    # gets published is the final change set, so it is the final one that is
    # accepted (a gate artifact has to be authorized in allowed_extra_paths, or
    # the run fails).
    #
    # `delivery.base_branch` is what the acceptance uses to find the candidate of a
    # **clean** workspace (a resume): it reads the published candidate from git
    # instead of reading the empty worktree, and it still executes the evidence the
    # contract in force requires.
    with {:ok, issue_number} <- issue_number(issue),
         {:ok, github} <- GitHub.context(settings.tracker, github_opts),
         {:ok, _early} <- Acceptance.scope(workspace, issue, delivery.base_branch),
         :ok <- run_gates(workspace, delivery),
         {:ok, evidence} <- Acceptance.evidence(workspace, issue, delivery, delivery.base_branch),
         {:ok, scope} <- Acceptance.scope(workspace, issue, delivery.base_branch) do
      publish(
        workspace,
        issue,
        delivery,
        github,
        issue_number,
        settings,
        Result.merge(scope, evidence)
      )
    end
  end

  # The candidate that gets promoted must be the commit this run accepted: the one
  # `prepare/4` committed and pushed (`mode: :created`) or the local HEAD a reconciled
  # run is resuming (`mode: :reconciled`). A branch head that moved — a push that landed
  # before or during the observation, so nobody here accepted it — is never promoted
  # with this verdict, and never labeled.
  defp require_accepted_candidate(%{sha: sha}, %{sha: sha}), do: :ok

  defp require_accepted_candidate(%{mode: mode, sha: accepted}, %{sha: observed}) do
    Logger.error("Delivery candidate replaced mode=#{mode} accepted=#{accepted} observed=#{observed}")

    {:error, {:delivery_candidate_replaced, accepted, observed}}
  end

  defp publish(workspace, issue, delivery, github, issue_number, settings, acceptance) do
    with {:ok, prepared} <- prepare(workspace, issue, delivery, github),
         {:ok, candidate} <- GitHub.await_candidate(github, prepared.branch, delivery),
         :ok <- require_accepted_candidate(prepared, candidate),
         {:ok, review} <- maybe_request_review(github, prepared, delivery),
         :ok <- handoff(github, prepared, candidate, review, delivery, issue_number, settings, acceptance) do
      result = %{
        status: :ready_for_human,
        branch: prepared.branch,
        candidate_sha: candidate.sha,
        pull: prepared.pull,
        checks: candidate.checks,
        review: review,
        issue_number: issue_number,
        contract: acceptance
      }

      Logger.info(
        "Delivery ready-for-human branch=#{prepared.branch} candidate=#{candidate.sha} " <>
          "pull=#{prepared.pull.number} mode=#{prepared.mode} review=#{review} " <>
          "contract=#{Acceptance.describe(acceptance)}"
      )

      {:ok, result}
    end
  end

  # The consumer's gates. A non-zero exit means "the execution failed": nothing is
  # published and the issue goes back to the work cycle through the normal retry.
  defp run_gates(workspace, delivery) do
    case Gates.run(workspace, delivery.gates, delivery.gates_timeout_ms) do
      {:ok, output} ->
        Logger.info("Delivery gates passed command=#{inspect(delivery.gates)} output=#{inspect(Git.sanitize(output))}")
        :ok

      {:error, {:command_failed, status, output}} ->
        {:error, {:delivery_gates_failed, status, Git.sanitize(output)}}

      {:error, {:command_timeout, timeout_ms}} ->
        {:error, {:delivery_gates_timeout, timeout_ms}}
    end
  end

  # Nothing to publish locally: the open pull request of the branch is the record of a
  # previous cycle. The candidate of a reconciled run is the **local HEAD** — the
  # content this workspace holds and this run accepts —, so a branch that moved (a push
  # nobody accepted here) is refused by `require_accepted_candidate/2` instead of being
  # promoted with this run's verdict.
  defp reconcile(workspace, branch, github) do
    with {:ok, head} <- Git.head_sha(workspace) do
      case GitHub.open_pull(github, branch) do
        {:ok, nil} -> {:error, :delivery_no_changes}
        {:ok, pull} -> {:ok, %{branch: branch, mode: :reconciled, pull: pull, sha: head}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp prepare(workspace, issue, delivery, github) do
    branch = branch_name(issue, delivery)

    case Git.status(workspace) do
      {:ok, []} -> reconcile(workspace, branch, github)
      {:ok, _changed} -> create(workspace, issue, branch, delivery, github)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(workspace, issue, branch, delivery, github) do
    with {:ok, sha} <- create_candidate(workspace, issue, branch, delivery, github),
         {:ok, pull} <- ensure_pull(github, branch, delivery, issue) do
      {:ok, %{branch: branch, mode: :created, pull: pull, sha: sha}}
    end
  end

  defp create_candidate(workspace, issue, branch, delivery, github) do
    identity = %{name: delivery.commit_name, email: delivery.commit_email}

    with :ok <- Git.checkout_branch(workspace, branch),
         :ok <- Git.add_all(workspace),
         :ok <- Git.commit(workspace, commit_message(issue), identity),
         :ok <- Git.push(workspace, branch, github.token) do
      Git.head_sha(workspace)
    end
  end

  defp ensure_pull(github, branch, delivery, issue) do
    case GitHub.open_pull(github, branch) do
      {:ok, nil} ->
        GitHub.create_draft_pull(github, %{
          branch: branch,
          base: delivery.base_branch,
          title: issue.title,
          body: pull_body(issue, delivery)
        })

      {:ok, pull} ->
        {:ok, pull}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The review is one-shot and optional: it is requested only after the candidate
  # is stable, and unavailability is recorded instead of faked. A reconciled
  # candidate (nothing new was published) never triggers a new request, so retries
  # cannot turn the review into a loop.
  defp maybe_request_review(github, %{mode: :created, pull: pull}, delivery) do
    request_review(github, pull, delivery)
  end

  defp maybe_request_review(_github, _prepared, _delivery), do: {:ok, :reconciled}

  defp request_review(github, pull, delivery) do
    cond do
      not delivery.request_review -> {:ok, :disabled}
      is_integer(pull.number) -> GitHub.request_one_shot_review(github, pull.number)
      true -> {:ok, :unavailable}
    end
  end

  # The verdict is persisted *before* the promotion state changes: if writing the
  # comment fails, the issue must not look promoted without its machine-readable
  # verdict (the labels are the state the next poll cycle reads).
  defp handoff(github, prepared, candidate, review, delivery, issue_number, settings, acceptance) do
    with :ok <-
           GitHub.ensure_comment(
             github,
             issue_number,
             marker(candidate.sha),
             comment_body(prepared, candidate, review, delivery, acceptance)
           ),
         :ok <- GitHub.add_labels(github, issue_number, [delivery.handoff_label]) do
      remove_entry_labels(github, issue_number, delivery, settings)
    end
  end

  # Removing the tracker entry label is what stops the next poll cycle from
  # dispatching an issue that already reached the handoff.
  defp remove_entry_labels(_github, _issue_number, %{remove_entry_labels: false}, _settings), do: :ok

  defp remove_entry_labels(github, issue_number, _delivery, settings) do
    Enum.reduce_while(settings.tracker.required_labels, :ok, fn label, :ok ->
      case GitHub.remove_label(github, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp marker(sha), do: "<!-- delivery:candidate:#{sha} -->"

  defp commit_message(%Issue{identifier: identifier, title: title}) do
    "#{identifier}: #{title}"
  end

  defp pull_body(%Issue{} = issue, delivery) do
    """
    ## What changes

    Delivered by the agent pipeline for issue `#{issue.identifier}`: #{issue.title}.

    Issue: #{issue.url}

    ## Gates

    The project's own gates (`#{delivery.gates}`) returned exit 0 in the issue
    workspace before this branch was pushed.

    ## Limits

    - Draft on purpose: the merge is a human decision, never automatic.
    - The deterministic gates belong to this project (`WORKFLOW.md`), not to the
      orchestrator.
    """
  end

  defp comment_body(prepared, candidate, review, delivery, acceptance) do
    """
    #{marker(candidate.sha)}
    ## ready-for-human

    - branch: `#{prepared.branch}` (mode: #{prepared.mode})
    - draft pull request: #{prepared.pull.url}
    - candidate stable: `#{candidate.sha}`
    - acceptance contract: #{Acceptance.describe(acceptance)}
    - local gates: `#{delivery.gates}` exit 0
    - CI: #{candidate.checks.total} check run(s) concluded successfully
    - one-shot review: #{review}
    - merge: human decision (the pipeline never merges)

    #{Acceptance.comment_block(acceptance, candidate.sha)}
    """
  end
end

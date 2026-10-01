defmodule SymphonyElixir.Delivery.GitHub do
  @moduledoc """
  GitHub REST surface used by the delivery stage.

  It is deliberately thin: every call goes through `SymphonyElixir.GitHub.Client`,
  so delivery and issue polling share one authentication path, one API version
  and one repo setting. The repository coordinates and the credential come from
  the tracker settings of the workflow, never from a second source.

  State is **derived** from GitHub instead of being stored locally: an open pull
  request of the delivery branch is the record that the work was published, and
  the check runs of its head SHA are the record of the CI result. That is what
  makes retry and reconciliation idempotent.
  """

  require Logger
  alias SymphonyElixir.GitHub.Client

  @pull_title_prefix "Pipeline: "
  @copilot_reviewer "copilot-pull-request-reviewer[bot]"
  @page_size 100

  @type context :: %{
          repo: String.t(),
          owner: String.t(),
          api_url: String.t(),
          token: String.t(),
          request: function(),
          sleep: function(),
          monotonic_time: function(),
          tracker_settings: map()
        }

  @type pull :: %{
          number: integer() | nil,
          url: String.t() | nil,
          sha: String.t() | nil,
          draft: boolean()
        }

  @doc """
  Builds the GitHub context (repository coordinates and credential) from tracker
  settings.
  """
  @spec context(map(), keyword()) :: {:ok, context()} | {:error, term()}
  def context(tracker_settings, opts \\ []) do
    with {:ok, connection} <- Client.connection(tracker_settings) do
      {:ok,
       %{
         repo: connection.repo,
         owner: owner(connection.repo),
         api_url: connection.api_url,
         token: connection.token,
         request: Keyword.get(opts, :request, &Client.request/5),
         sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
         monotonic_time: Keyword.get(opts, :monotonic_time, &System.monotonic_time/1),
         tracker_settings: tracker_settings
       }}
    end
  end

  @doc """
  Returns the open pull request of `branch`, or `nil` when there is none.

  This is the idempotency gate of the stage: a delivery that finds an open pull
  request never opens a second one.
  """
  @spec open_pull(context(), String.t()) :: {:ok, pull() | nil} | {:error, term()}
  def open_pull(context, branch) do
    params = %{"state" => "open", "head" => "#{context.owner}:#{branch}", "per_page" => @page_size}

    case get(context, "/repos/#{context.repo}/pulls", params) do
      {:ok, pulls} when is_list(pulls) -> {:ok, open_pull_of(pulls, branch)}
      {:ok, _other} -> {:error, :invalid_pull_list_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_pull_of(pulls, branch) do
    case Enum.find(pulls, &(get_in(&1, ["head", "ref"]) == branch)) do
      nil -> nil
      pull -> normalize_pull(pull)
    end
  end

  @spec create_draft_pull(context(), map()) :: {:ok, pull()} | {:error, term()}
  def create_draft_pull(context, %{branch: branch, base: base, title: title, body: body}) do
    payload = %{
      "title" => @pull_title_prefix <> title,
      "head" => branch,
      "base" => base,
      "body" => body,
      "draft" => true
    }

    case post(context, "/repos/#{context.repo}/pulls", payload) do
      {:ok, pull} when is_map(pull) -> {:ok, normalize_pull(pull)}
      {:ok, other} -> {:error, {:unexpected_pull_payload, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves the SHA the delivery branch points at right now.
  """
  @spec branch_sha(context(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def branch_sha(context, branch) do
    case get(context, "/repos/#{context.repo}/git/ref/heads/#{branch}", %{}) do
      {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) -> {:ok, sha}
      {:ok, _body} -> {:ok, nil}
      {:error, {:github_request_failed, 404, _body}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the check runs of `sha` as `%{total: n, pending: n, failed: [names]}`.
  """
  @spec check_runs(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def check_runs(context, sha) do
    params = %{"per_page" => @page_size}

    with {:ok, body} <- get(context, "/repos/#{context.repo}/commits/#{sha}/check-runs", params),
         runs when is_list(runs) <- Map.get(body || %{}, "check_runs", []) do
      {:ok, summarize_checks(runs)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_check_runs_payload}
    end
  end

  @doc """
  Observes the check runs of the delivery branch until they conclude.

  While observing, the branch SHA is re-read: a push that lands after the
  observation started **invalidates** the candidate, and the observation restarts
  on the new SHA instead of promoting a SHA that is no longer the head. Promotion
  only happens for a SHA whose checks are all successful and which is still the
  head of the branch.
  """
  @spec await_candidate(context(), String.t(), map()) ::
          {:ok, %{sha: String.t(), checks: map()}} | {:error, term()}
  def await_candidate(context, branch, delivery) do
    with {:ok, sha} <- branch_sha(context, branch),
         :ok <- require_sha(sha) do
      observe(context, branch, sha, delivery, deadline(context, delivery))
    end
  end

  @spec request_one_shot_review(context(), integer()) ::
          {:ok, :requested | :unavailable} | {:error, term()}
  def request_one_shot_review(context, pull_number) do
    payload = %{"reviewers" => [@copilot_reviewer]}

    case post(context, "/repos/#{context.repo}/pulls/#{pull_number}/requested_reviewers", payload) do
      {:ok, _body} ->
        {:ok, :requested}

      {:error, reason} ->
        # The optional step never blocks or fakes the handoff: the reason is
        # recorded as unavailability and the delivery continues.
        Logger.info("Delivery review request unavailable: #{inspect(reason)}")
        {:ok, :unavailable}
    end
  end

  @spec add_labels(context(), integer(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(context, issue_number, labels) do
    with {:ok, _body} <-
           post(context, "/repos/#{context.repo}/issues/#{issue_number}/labels", %{"labels" => labels}) do
      :ok
    end
  end

  @spec remove_label(context(), integer(), String.t()) :: :ok | {:error, term()}
  def remove_label(context, issue_number, label) do
    path = "/repos/#{context.repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

    case request_body(context, "DELETE", path, %{}, nil) do
      {:ok, _body} -> :ok
      {:error, {:github_request_failed, 404, _body}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec comments(context(), integer()) :: {:ok, [map()]} | {:error, term()}
  def comments(context, issue_number) do
    case get(context, "/repos/#{context.repo}/issues/#{issue_number}/comments", %{"per_page" => @page_size}) do
      {:ok, body} when is_list(body) -> {:ok, body}
      {:ok, _other} -> {:error, :invalid_comments_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec comment(context(), integer(), String.t()) :: :ok | {:error, term()}
  def comment(context, issue_number, body) do
    with {:ok, _body} <- post(context, "/repos/#{context.repo}/issues/#{issue_number}/comments", %{"body" => body}) do
      :ok
    end
  end

  @doc """
  Writes the authoritative comment of an artifact, or updates it when its payload
  changed.

  `identity` is the opaque marker that tells which artifact a comment is (the handoff
  uses `<!-- delivery:candidate:<sha> -->`, so a corrected candidate gets its own record
  and a retry over the same candidate does not create a second one) and `marker` is the
  marker of the **current payload** (`<!-- acceptance:result:<sha>:<fingerprint> -->`): a
  comment that already carries it is this verdict, so nothing is written.

  A stored artifact whose body does **not** carry the current `marker` is replaced: the
  same candidate re-evaluated with another verdict (a contract that changed, an evidence
  that now fails, a mode that flipped from passing to advisory) must have one
  authoritative record, never an old one that the next reader would take as current. A
  payload without an `id` is not an artifact that can be updated, so the verdict is
  written as a new comment — the current verdict is never left unpersisted.
  """
  @spec upsert_comment(context(), integer(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def upsert_comment(context, issue_number, identity, marker, body) do
    with {:ok, comments} <- comments(context, issue_number) do
      case artifact(comments, identity) do
        nil -> comment(context, issue_number, body)
        %{id: nil} -> comment(context, issue_number, body)
        %{id: id} = stored -> reconcile(context, id, stored, marker, body)
      end
    end
  end

  @spec update_comment(context(), integer(), String.t()) :: :ok | {:error, term()}
  def update_comment(context, comment_id, body) do
    with {:ok, _body} <-
           request_body(context, "PATCH", "/repos/#{context.repo}/issues/comments/#{comment_id}", %{}, %{
             "body" => body
           }) do
      :ok
    end
  end

  defp artifact(comments, identity) do
    Enum.find_value(comments, fn comment ->
      body = Map.get(comment, "body")

      if is_binary(body) and String.contains?(body, identity) do
        %{id: Map.get(comment, "id"), body: body}
      end
    end)
  end

  defp reconcile(context, id, %{body: stored}, marker, body) do
    if String.contains?(stored, marker), do: :ok, else: update_comment(context, id, body)
  end

  @spec summarize_checks([map()]) :: map()
  def summarize_checks(runs) do
    pending = Enum.count(runs, &(Map.get(&1, "status") != "completed"))

    failed =
      runs
      |> Enum.filter(&(Map.get(&1, "status") == "completed"))
      |> Enum.reject(&(Map.get(&1, "conclusion") in ["success", "neutral", "skipped"]))
      |> Enum.map(&to_string(Map.get(&1, "name") || "check"))

    %{total: length(runs), pending: pending, failed: failed}
  end

  defp observe(context, branch, sha, delivery, deadline) do
    with {:ok, current_sha} <- branch_sha(context, branch),
         :ok <- require_sha(current_sha) do
      observe_current(context, branch, sha, current_sha, delivery, deadline)
    end
  end

  defp observe_current(context, branch, sha, current_sha, delivery, deadline) when current_sha != sha do
    Logger.info("Delivery candidate invalidated: branch #{branch} moved to #{String.slice(current_sha, 0, 12)}")
    observe(context, branch, current_sha, delivery, deadline)
  end

  defp observe_current(context, branch, sha, _current_sha, delivery, deadline) do
    with {:ok, checks} <- check_runs(context, sha) do
      cond do
        checks.failed != [] ->
          {:error, {:delivery_ci_failed, sha, checks.failed}}

        checks.total > 0 and checks.pending == 0 ->
          {:ok, %{sha: sha, checks: checks}}

        expired?(context, deadline) ->
          {:error, {:delivery_ci_pending, sha, checks}}

        true ->
          context.sleep.(delivery.ci_poll_interval_ms)
          observe(context, branch, sha, delivery, deadline)
      end
    end
  end

  defp deadline(context, delivery), do: context.monotonic_time.(:millisecond) + delivery.ci_timeout_ms

  defp expired?(context, deadline), do: context.monotonic_time.(:millisecond) >= deadline

  defp require_sha(nil), do: {:error, :delivery_branch_missing}
  defp require_sha(_sha), do: :ok

  defp normalize_pull(pull) do
    %{
      number: Map.get(pull, "number"),
      url: Map.get(pull, "html_url"),
      sha: get_in(pull, ["head", "sha"]),
      draft: Map.get(pull, "draft") == true
    }
  end

  defp owner(repo) do
    # `Client.connection/1` already validated `owner/name`, so splitting cannot fail here.
    repo |> String.split("/", parts: 2) |> List.first()
  end

  defp get(context, path, params), do: request_body(context, "GET", path, params, nil)

  defp post(context, path, body), do: request_body(context, "POST", path, %{}, body)

  # The tracker client answers `{:ok, %{status: ..., body: ...}}`; the delivery
  # surface converts a non-2xx status into an error carrying the status, so callers
  # can tell "not found" (a legitimate absence) from a real failure.
  defp request_body(context, method, path, params, body) do
    case request(context, method, path, params, body) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:github_request_failed, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(context, method, path, params, body) do
    context.request.(method, path, params, body, tracker_settings: context.tracker_settings)
  end
end

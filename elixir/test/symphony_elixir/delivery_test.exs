defmodule SymphonyElixir.DeliveryTest do
  @moduledoc """
  Delivery stage: gates, draft pull request, CI, candidate and handoff.

  The suite is offline. Git is real (a bare repository acts as `origin`), so a
  push performed by production code is what the API stand-in reads back, while
  the GitHub surface is a deterministic stand-in with an injectable answer per
  route.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Delivery
  alias SymphonyElixir.Delivery.Acceptance.Result
  alias SymphonyElixir.Delivery.Git
  alias SymphonyElixir.Delivery.GitHub, as: DeliveryGitHub
  alias SymphonyElixir.Tracker.Issue

  @issue %Issue{
    id: "7",
    identifier: "SMOKE-7",
    title: "Change answer.sh so it prints exactly 42",
    description: "Deterministic disposable task.",
    state: "open",
    url: "https://github.test/octo/smoke/issues/7",
    labels: []
  }

  @repo "octo/smoke"

  defmodule FakeGitHub do
    @moduledoc false

    @repo "octo/smoke"
    @owner "octo"
    @name "smoke"

    # Deterministic GitHub REST stand-in for the delivery stage. The branch SHA is
    # read from the real local `origin` repository, so what the API stand-in
    # reports is what the push of the production code actually published.
    @spec start!(keyword()) :: pid()
    def start!(attrs \\ []) do
      {:ok, pid} =
        Agent.start_link(fn ->
          %{
            remote: attrs[:remote],
            pulls: attrs[:pulls] || [],
            pull_number: attrs[:pull_number],
            requests: [],
            labels: attrs[:labels] || [],
            fail_label_delete: attrs[:fail_label_delete] || false,
            comments: [],
            review: attrs[:review] || :created
          }
        end)

      pid
    end

    @spec request(pid(), function()) :: function()
    def request(pid, checks_fun \\ fn _sha, _index -> {:ok, %{status: 200, body: %{"check_runs" => []}}} end) do
      fn method, path, params, body, _opts ->
        Agent.get_and_update(pid, &handle(&1, method, path, params, body, checks_fun))
      end
    end

    @spec state(pid()) :: map()
    def state(pid), do: Agent.get(pid, & &1)

    @spec sha(pid(), String.t()) :: String.t() | nil
    def sha(pid, branch), do: remote_sha(Agent.get(pid, & &1.remote), branch)

    defp handle(state, method, path, params, body, checks) do
      segments = path |> String.split("?") |> List.first() |> String.split("/", trim: true)
      dispatch(state, method, segments, params, body, checks)
    end

    defp dispatch_repo(state, "GET", ["pulls"], params, _body, _checks) do
      branch = params |> Map.get("head", "") |> String.split(":") |> List.last()

      pulls = Enum.filter(state.pulls, &(&1["head"]["ref"] == branch and &1["state"] == "open"))
      {{:ok, %{status: 200, body: pulls}}, track(state, {:get_pulls, branch})}
    end

    defp dispatch_repo(state, "POST", ["pulls"], _params, body, _checks) do
      number = if state.pull_number == :missing, do: nil, else: length(state.pulls) + 1

      pull = %{
        "html_url" => "https://github.test/#{@repo}/pull/#{length(state.pulls) + 1}",
        "state" => "open",
        "draft" => body["draft"],
        "head" => %{"ref" => body["head"], "sha" => remote_sha(state.remote, body["head"])},
        "base" => %{"ref" => body["base"]}
      }

      pull = if is_integer(number), do: Map.put(pull, "number", number), else: pull

      event = {:create_pull, body["head"]}
      {{:ok, %{status: 201, body: pull}}, %{track(state, event) | pulls: state.pulls ++ [pull]}}
    end

    defp dispatch_repo(state, "GET", ["git", "ref", "heads" | rest], _params, _body, _checks) do
      branch = Enum.join(rest, "/")

      case remote_sha(state.remote, branch) do
        nil -> {{:ok, %{status: 404, body: %{"message" => "Not Found"}}}, track(state, {:ref_missing, branch})}
        sha -> {{:ok, %{status: 200, body: %{"object" => %{"sha" => sha}}}}, track(state, {:ref, branch, sha})}
      end
    end

    defp dispatch_repo(state, "GET", ["commits", sha, "check-runs"], _params, _body, checks) do
      index = Enum.count(state.requests, &match?({:checks, _, _}, &1)) + 1
      {:ok, %{status: 200, body: %{"check_runs" => runs}}} = checks.(sha, index)

      {{:ok, %{status: 200, body: %{"check_runs" => runs}}}, track(state, {:checks, sha, index})}
    end

    defp dispatch_repo(state, "POST", ["pulls", number, "requested_reviewers"], _params, _body, _checks) do
      case state.review do
        :created ->
          {{:ok, %{status: 201, body: %{}}}, track(state, {:review_requested, number})}

        {:failed, status, body} ->
          {{:error, {:github_request_failed, status, body}}, track(state, {:review_failed, number})}
      end
    end

    defp dispatch_repo(state, "POST", ["issues", _number, "labels"], _params, body, _checks) do
      labels = Enum.uniq(state.labels ++ body["labels"])
      {{:ok, %{status: 200, body: %{"labels" => labels}}}, %{track(state, {:labels, body["labels"]}) | labels: labels}}
    end

    defp dispatch_repo(state, "DELETE", ["issues", _number, "labels" | rest], _params, _body, _checks) do
      decoded = rest |> Enum.join("/") |> URI.decode_www_form()

      cond do
        state.fail_label_delete ->
          missing = track(state, {:label_delete_failed, decoded})
          {{:error, {:github_request_failed, 500, %{"message" => "boom"}}}, missing}

        decoded in state.labels ->
          removed = List.delete(state.labels, decoded)
          {{:ok, %{status: 200, body: %{}}}, %{track(state, {:label_removed, decoded}) | labels: removed}}

        true ->
          missing = track(state, {:label_missing, decoded})
          {{:error, {:github_request_failed, 404, %{"message" => "Label does not exist"}}}, missing}
      end
    end

    defp dispatch_repo(state, "GET", ["issues", _number, "comments"], _params, _body, _checks) do
      {{:ok, %{status: 200, body: state.comments}}, track(state, :comments_read)}
    end

    defp dispatch_repo(state, "POST", ["issues", _number, "comments"], _params, body, _checks) do
      comment = %{"body" => body["body"]}
      {{:ok, %{status: 201, body: comment}}, %{track(state, :comment_created) | comments: state.comments ++ [comment]}}
    end

    defp dispatch(state, method, ["repos", @owner, @name | rest], params, body, checks) do
      dispatch_repo(state, method, rest, params, body, checks)
    end

    defp dispatch(state, method, segments, _params, _body, _checks) do
      body = %{"message" => "unexpected #{method} #{Enum.join(segments, "/")}"}
      {{:error, {:github_request_failed, 404, body}}, track(state, {:unexpected, method, segments})}
    end

    defp track(state, event), do: %{state | requests: state.requests ++ [event]}

    defp remote_sha(nil, _branch), do: nil

    defp remote_sha(remote, branch) do
      case System.cmd("git", ["-C", remote, "rev-parse", "refs/heads/#{branch}"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _other -> nil
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-delivery-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    workspace = Path.join(root, "workspace")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    git!(nil, ["init", "--bare", "-q", "-b", "main", origin])
    git!(nil, ["clone", "-q", origin, workspace])
    change_answer!(workspace, "1")
    git!(workspace, ["add", "-A"])
    git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-q", "-m", "answer"])
    git!(workspace, ["push", "-q", "origin", "main"])

    on_exit(fn -> File.rm_rf(root) end)
    Process.put(:delivery_origin, origin)
    %{origin: origin, workspace: workspace}
  end

  test "delivery is opt-in: a workflow without it keeps the upstream behavior", %{workspace: workspace} do
    configure!(enabled: false)

    assert Delivery.run(workspace, @issue) == :disabled
  end

  test "the project gates define done: a failing gate publishes nothing", %{workspace: workspace} do
    configure!(gates: "false")
    fake = fake!()

    assert {:error, {:delivery_gates_failed, 1, _output}} = Delivery.run(workspace, @issue, github_opts(fake))

    assert FakeGitHub.state(fake).requests == []
    assert FakeGitHub.sha(fake, delivery_branch()) == nil
  end

  test "a gate that never finishes fails the run instead of publishing", %{workspace: workspace} do
    configure!(gates: "sleep 5", gates_timeout_ms: 100)

    assert {:error, {:delivery_gates_timeout, 100}} = Delivery.run(workspace, @issue)
  end

  test "a successful delivery publishes one branch, one draft pull request and reaches ready-for-human", %{
    workspace: workspace
  } do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, @issue, github_opts(fake))
    state = FakeGitHub.state(fake)

    assert result.status == :ready_for_human
    assert result.branch == delivery_branch()
    assert result.candidate_sha == FakeGitHub.sha(fake, delivery_branch())
    assert result.pull.draft
    assert result.review == :requested

    assert length(state.pulls) == 1
    assert state.labels == ["pipeline:ready-for-human"]
    assert length(state.comments) == 1
    assert hd(state.comments)["body"] =~ "<!-- delivery:candidate:#{result.candidate_sha} -->"
    assert hd(state.comments)["body"] =~ "candidate stable"
    assert hd(state.comments)["body"] =~ "merge: human decision"

    # The work happened inside the workspace and the workspace is clean afterwards,
    # because the published commit is what carried the change.
    assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace)
    assert {output, 0} = System.cmd("bash", ["answer.sh"], cd: workspace)
    assert String.trim(output) == "42"
  end

  test "the base branch is never pushed and the published branch matches the candidate", %{
    origin: origin,
    workspace: workspace
  } do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    {:ok, result} = Delivery.run(workspace, @issue, github_opts(fake))

    {remote_main, 0} = System.cmd("git", ["-C", origin, "rev-parse", "refs/heads/main"])
    {local_main, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: workspace)

    assert String.trim(remote_main) == String.trim(local_main)
    assert result.pull.sha == FakeGitHub.sha(fake, delivery_branch())
  end

  test "a failing CI blocks promotion and the handoff", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:error, {:delivery_ci_failed, _sha, ["gates"]}} =
             Delivery.run(workspace, @issue, github_opts(fake, checks_failed()))

    state = FakeGitHub.state(fake)
    assert length(state.pulls) == 1
    assert state.labels == []
    assert state.comments == []
  end

  test "a pending CI never promotes before it concludes", %{workspace: workspace} do
    configure!(ci_timeout_ms: 50, ci_poll_interval_ms: 1)
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:error, {:delivery_ci_pending, _sha, %{pending: 1}}} =
             Delivery.run(workspace, @issue, github_opts(fake, checks_pending()))

    assert FakeGitHub.state(fake).comments == []
  end

  test "no CI at all is not a promotion", %{workspace: workspace} do
    configure!(ci_timeout_ms: 50, ci_poll_interval_ms: 1)
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:error, {:delivery_ci_pending, _sha, %{total: 0}}} =
             Delivery.run(workspace, @issue, github_opts(fake, checks_none()))

    assert FakeGitHub.state(fake).comments == []
  end

  test "a push during the observation invalidates the candidate and the new head is verified", %{
    workspace: workspace
  } do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")
    test_pid = self()

    checks =
      fn sha, index ->
        if index == 1 do
          # A new push lands while the checks of the first SHA have not concluded.
          send(test_pid, {:first_checked_sha, sha})
          change_answer!(workspace, "42\n# corrected")
          git!(workspace, ["add", "-A"])

          git!(workspace, [
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.org",
            "commit",
            "-q",
            "-m",
            "second push"
          ])

          git!(workspace, ["push", "-q", "origin", "HEAD:refs/heads/#{delivery_branch()}"])

          checks_pending().(sha, index)
        else
          checks_ok().(sha, index)
        end
      end

    # The first check of the first push can only be observed after the delivery
    # published the branch, so the SHA captured here is the published one.
    assert {:ok, result} = Delivery.run(workspace, @issue, github_opts(fake, checks))
    assert_received {:first_checked_sha, observed_sha}

    moved_sha = FakeGitHub.sha(fake, delivery_branch())

    assert observed_sha != moved_sha
    assert result.candidate_sha == moved_sha, "the candidate must be the verified head, not the invalidated one"
    assert Enum.count(FakeGitHub.state(fake).requests, &match?({:checks, _, _}, &1)) >= 2
  end

  test "a retry reconciles the published candidate instead of duplicating it", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:ok, first} = Delivery.run(workspace, @issue, github_opts(fake))
    assert {:ok, second} = Delivery.run(workspace, @issue, github_opts(fake))

    state = FakeGitHub.state(fake)

    assert second.candidate_sha == first.candidate_sha
    assert Enum.count(state.requests, &match?({:create_pull, _}, &1)) == 1
    assert Enum.count(state.requests, &(&1 == :comment_created)) == 1
    assert length(state.pulls) == 1
    assert length(state.comments) == 1
    assert FakeGitHub.sha(fake, delivery_branch()) == first.candidate_sha
  end

  test "a clean workspace with nothing published is not a delivery", %{workspace: workspace} do
    configure!([])
    fake = fake!()

    assert {:error, :delivery_no_changes} = Delivery.run(workspace, @issue, github_opts(fake))
    assert FakeGitHub.state(fake).pulls == []
  end

  test "a corrected candidate after review gets its own comment", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:ok, first} = Delivery.run(workspace, @issue, github_opts(fake))

    change_answer!(workspace, "42\n# reviewed")
    assert {:ok, second} = Delivery.run(workspace, @issue, github_opts(fake))

    state = FakeGitHub.state(fake)

    assert second.candidate_sha != first.candidate_sha
    assert Enum.count(state.requests, &(&1 == :comment_created)) == 2
    assert length(state.pulls) == 1
  end

  test "an unavailable review is recorded and does not block the handoff", %{workspace: workspace} do
    configure!([])
    fake = fake!(review: {:failed, 422, %{"message" => "Reviews are not available"}})
    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, @issue, github_opts(fake))

    assert result.review == :unavailable
    assert FakeGitHub.state(fake).comments != []
    assert FakeGitHub.state(fake).labels == ["pipeline:ready-for-human"]
  end

  test "the one-shot review can be disabled by configuration", %{workspace: workspace} do
    configure!(request_review: false)
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:ok, %{review: :disabled}} = Delivery.run(workspace, @issue, github_opts(fake))
    refute Enum.any?(FakeGitHub.state(fake).requests, &match?({:review_requested, _}, &1))
  end

  test "keeping the entry label is possible, and then the issue stays dispatchable", %{workspace: workspace} do
    configure!(remove_entry_labels: false)
    fake = fake!(labels: ["pipeline:ready"])
    change_answer!(workspace, "42")

    assert {:ok, _result} = Delivery.run(workspace, @issue, github_opts(fake))

    state = FakeGitHub.state(fake)
    assert state.labels == ["pipeline:ready", "pipeline:ready-for-human"]
    refute Enum.any?(state.requests, &match?({:label_removed, _}, &1))
  end

  test "delivery refuses to run on a remote worker host", %{workspace: workspace} do
    configure!([])

    assert {:error, {:delivery_requires_local_worker, "build-1"}} =
             Delivery.run(workspace, @issue, worker_host: "build-1")
  end

  test "preflight refuses a delivery that could not be published" do
    assert :ok = Delivery.validate_config(delivery_settings("github", []))

    assert {:error, :delivery_requires_github_tracker} =
             Delivery.validate_config(delivery_settings("linear", []))

    assert {:error, :delivery_requires_local_worker} =
             Delivery.validate_config(delivery_settings("github", ["build-1"]))

    disabled = %{delivery: %{enabled: false}, tracker: %{kind: "linear"}, worker: %{ssh_hosts: []}}
    assert :ok = Delivery.validate_config(disabled)
  end

  test "the issue id, the branch name and the sanitized output are deterministic" do
    assert {:ok, 7} = Delivery.issue_number(@issue)
    assert {:error, :delivery_requires_github_issue_id} = Delivery.issue_number(%{@issue | id: "SMOKE-7"})

    assert Delivery.branch_name(%{@issue | identifier: "SMOKE 7/x"}, %{branch_prefix: "pipeline/"}) ==
             "pipeline/smoke-7-x"

    assert Git.sanitize("token gho_abc123 and x-access-token:secret@github.com") ==
             "token gho_*** and x-access-token:***@github.com"

    assert Git.changed_paths(" M answer.sh\n?? tests/test_answer.sh\n") == ["answer.sh", "tests/test_answer.sh"]
  end

  test "the change set parser reports the destination of a rename and every untracked file" do
    output = "R  docs.md" <> <<0>> <> "README.md" <> <<0>> <> " M answer.sh" <> <<0>> <> "?? notes/new.md" <> <<0>>

    assert Git.change_entries(output) ==
             {:ok,
              [
                %{path: "docs.md", status: "R"},
                %{path: "answer.sh", status: "M"},
                %{path: "notes/new.md", status: "??"}
              ]}

    assert Git.change_entries("") == {:ok, []}

    # A path that is not valid UTF-8 cannot be matched or persisted safely.
    assert Git.change_entries(<<"?? bad", 0xFF, ".md", 0>>) == :invalid_encoding

    # The change set is bounded: above the cap the read fails closed instead of
    # producing a partial (and therefore accepted-by-accident) verdict.
    many = Enum.map_join(1..5_001, <<0>>, &"?? f#{&1}")
    assert Git.change_entries(many) == :overflow
  end

  test "git refuses to publish without a credential", %{workspace: workspace} do
    assert {:error, :missing_delivery_credential} = Git.push(workspace, delivery_branch(), "")
  end

  test "the check-runs summary ignores neutral and skipped conclusions" do
    runs = [
      %{"name" => "gates", "status" => "completed", "conclusion" => "success"},
      %{"name" => "lint", "status" => "completed", "conclusion" => "neutral"},
      %{"name" => "audit", "status" => "completed", "conclusion" => "skipped"},
      %{"name" => "docs", "status" => "in_progress", "conclusion" => nil},
      %{"name" => "tests", "status" => "completed", "conclusion" => "failure"}
    ]

    assert DeliveryGitHub.summarize_checks(runs) == %{total: 5, pending: 1, failed: ["tests"]}
  end

  test "the GitHub surface reports invalid payloads instead of guessing" do
    invalid = fn body, _method, _path, _params, _opts -> {:ok, %{status: 200, body: body}} end

    check_runs_context = %{
      repo: @repo,
      owner: "octo",
      tracker_settings: %{},
      request: fn _method, _path, _params, _body, _opts ->
        invalid.(%{"check_runs" => "nope"}, nil, nil, nil, nil)
      end
    }

    empty_context = %{
      repo: @repo,
      owner: "octo",
      tracker_settings: %{},
      request: fn _method, _path, _params, _body, _opts -> {:ok, %{status: 200, body: %{}}} end
    }

    assert {:error, :invalid_check_runs_payload} =
             DeliveryGitHub.check_runs(check_runs_context, "abc")

    assert {:error, :invalid_comments_payload} = DeliveryGitHub.comments(empty_context, 7)

    assert {:error, :invalid_pull_list_payload} =
             DeliveryGitHub.open_pull(empty_context, delivery_branch())
  end

  test "the Git surface reports a broken workspace instead of guessing" do
    not_a_repo = Path.join(System.tmp_dir!(), "symphony-delivery-not-a-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(not_a_repo)
    on_exit(fn -> File.rm_rf(not_a_repo) end)

    assert {:error, {:git_command_failed, _args, _status, _output}} = Git.status(not_a_repo)
  end

  test "a delivery without gates fails preflight" do
    assert :ok = Delivery.validate_config(delivery_settings("github", []))

    assert {:error, :missing_delivery_gates} =
             Delivery.validate_config(%{
               delivery: %{enabled: true, gates: "  "},
               tracker: %{kind: "github"},
               worker: %{ssh_hosts: []}
             })

    assert {:error, :missing_delivery_gates} =
             Delivery.validate_config(%{
               delivery: %{enabled: true},
               tracker: %{kind: "github"},
               worker: %{ssh_hosts: []}
             })
  end

  test "the delivery config block validates its own boundaries" do
    assert {:ok, _settings} = Schema.parse(%{"delivery" => %{"enabled" => false}})
    assert {:ok, _settings} = Schema.parse(%{"delivery" => %{"enabled" => true, "gates" => "true"}})

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"delivery" => %{"enabled" => true, "gates" => "  "}})

    assert message =~ "gates"

    for invalid <- [
          %{"base_branch" => " "},
          %{"handoff_label" => ""},
          %{"gates_timeout_ms" => 0},
          %{"ci_timeout_ms" => 0},
          %{"ci_poll_interval_ms" => 0},
          %{"evidence" => "not-a-map"},
          %{"evidence" => %{"agent-tests" => " "}},
          %{"evidence" => %{"" => "true"}},
          %{"evidence" => %{"agent-tests" => 5}}
        ] do
      assert {:error, {:invalid_workflow_config, _message}} = Schema.parse(%{"delivery" => invalid})
    end
  end

  test "the delivery config carries the named evidences of the acceptance contract" do
    assert {:ok, settings} =
             Schema.parse(%{
               "delivery" => %{"enabled" => true, "gates" => "true", "evidence" => %{"agent-tests" => "bash tests/agent.sh"}}
             })

    assert settings.delivery.evidence == %{"agent-tests" => "bash tests/agent.sh"}

    assert {:ok, default} = Schema.parse(%{"delivery" => %{"enabled" => true, "gates" => "true"}})
    assert default.delivery.evidence == %{}
  end

  test "the GitHub surface propagates failures instead of inventing state" do
    failing = fn _, _, _, _, _ -> {:error, :network_down} end
    context = %{repo: @repo, owner: "octo", tracker_settings: %{}, request: failing}
    delivery = %{ci_timeout_ms: 10, ci_poll_interval_ms: 1}

    assert {:error, :network_down} = DeliveryGitHub.open_pull(context, "pipeline/x")
    assert {:error, :network_down} = DeliveryGitHub.branch_sha(context, "pipeline/x")
    assert {:error, :network_down} = DeliveryGitHub.check_runs(context, "abc")
    assert {:error, :network_down} = DeliveryGitHub.add_labels(context, 7, ["a"])
    assert {:error, :network_down} = DeliveryGitHub.remove_label(context, 7, "a")
    assert {:error, :network_down} = DeliveryGitHub.comments(context, 7)
    assert {:error, :network_down} = DeliveryGitHub.comment(context, 7, "x")
    assert {:error, :network_down} = DeliveryGitHub.await_candidate(context, "pipeline/x", delivery)

    assert {:error, :network_down} =
             DeliveryGitHub.create_draft_pull(context, %{branch: "b", base: "main", title: "t", body: "b"})
  end

  test "the GitHub surface tolerates an absent pull request and a missing label" do
    not_found = fn _, _, _, _, _ -> {:ok, %{status: 404, body: %{}}} end
    context = %{repo: @repo, owner: "octo", tracker_settings: %{}, request: not_found}

    assert {:ok, nil} = DeliveryGitHub.branch_sha(context, "pipeline/x")
    assert :ok = DeliveryGitHub.remove_label(context, 7, "pipeline:ready")
  end

  test "a review request that cannot be automated is recorded as unavailable" do
    unavailable = fn _, _, _, _, _ -> {:error, :no_copilot} end
    context = %{repo: @repo, owner: "octo", tracker_settings: %{}, request: unavailable}

    assert {:ok, :unavailable} = DeliveryGitHub.request_one_shot_review(context, 1)
  end

  test "an unexpected pull payload is not treated as a published candidate" do
    unexpected = fn _, _, _, _, _ -> {:ok, %{status: 201, body: "nope"}} end
    context = %{repo: @repo, owner: "octo", tracker_settings: %{}, request: unexpected}

    assert {:error, {:unexpected_pull_payload, "nope"}} =
             DeliveryGitHub.create_draft_pull(context, %{branch: "b", base: "main", title: "t", body: "x"})
  end

  test "a retry never requests a second review for the same candidate", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:ok, first} = Delivery.run(workspace, @issue, github_opts(fake))
    assert {:ok, second} = Delivery.run(workspace, @issue, github_opts(fake))

    assert first.review == :requested
    assert second.review == :reconciled
    assert Enum.count(FakeGitHub.state(fake).requests, &match?({:review_requested, _}, &1)) == 1
  end

  test "a pull payload without a number is not faked and does not block the handoff", %{workspace: workspace} do
    configure!([])
    fake = fake!(pull_number: :missing)
    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, @issue, github_opts(fake))

    assert result.review == :unavailable
    assert result.pull.number == nil
    assert FakeGitHub.state(fake).comments != []
  end

  test "git reports a clean tree and a missing binary instead of crashing", %{workspace: workspace} do
    identity = %{name: "Test", email: "test@example.org"}

    assert {:error, {:git_command_failed, ["-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-q", "-m", "nothing"], 1, _output}} =
             Git.commit(workspace, "nothing", identity)

    path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> System.put_env("PATH", path) end)

    assert {:error, {:git_not_available, _message}} = Git.status(workspace)
  end

  test "an unavailable askpass helper fails the push instead of leaking the credential", %{workspace: workspace} do
    git!(workspace, ["checkout", "-q", "-b", delivery_branch()])

    assert {:error, {:askpass_unavailable, _reason}} =
             Git.push(workspace, delivery_branch(), "token-that-must-not-leak", askpass_root: "/proc/self/definitely-not-writable")
  end

  test "the GitHub context comes from the tracker settings", %{workspace: _workspace} do
    configure!([])

    assert {:ok, context} = DeliveryGitHub.context(SymphonyElixir.Config.settings!().tracker)
    assert context.repo == @repo
    assert context.owner == "octo"

    assert {:error, :missing_github_repo} = DeliveryGitHub.context(%{kind: "github", provider: %{}})

    assert {:error, :invalid_github_repo} =
             DeliveryGitHub.context(%{kind: "github", provider: %{"repo" => "octo", "token" => "t"}})
  end

  test "an anomalous ref payload is an absent branch, and an absent branch is not a candidate" do
    context = %{
      repo: @repo,
      owner: "octo",
      tracker_settings: %{},
      request: fn _, _, _, _, _ -> {:ok, %{status: 200, body: %{"message" => "weird"}}} end
    }

    assert {:ok, nil} = DeliveryGitHub.branch_sha(context, "pipeline/x")

    assert {:error, :delivery_branch_missing} =
             DeliveryGitHub.await_candidate(context, "pipeline/x", %{ci_timeout_ms: 10, ci_poll_interval_ms: 1})
  end

  test "a GitHub failure while preparing stops the delivery", %{workspace: workspace} do
    configure!([])
    failing = fn _, _, _, _, _ -> {:error, :network_down} end
    opts = [github: [request: failing, sleep: fn _ -> :ok end]]

    # Nothing published and no local change: reconciliation itself cannot be done.
    assert {:error, :network_down} = Delivery.run(workspace, @issue, opts)

    # With a local change the candidate is pushed, and the failure stops the PR.
    change_answer!(workspace, "42")
    assert {:error, :network_down} = Delivery.run(workspace, @issue, opts)
  end

  test "an unusable workspace fails the delivery before anything is published" do
    configure!([])
    not_a_repo = Path.join(System.tmp_dir!(), "symphony-delivery-unusable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(not_a_repo)
    on_exit(fn -> File.rm_rf(not_a_repo) end)

    assert {:error, {:git_command_failed, _args, _status, _output}} =
             Delivery.run(not_a_repo, @issue, github_opts(fake!()))
  end

  test "the entry label is removed when it exists", %{workspace: workspace} do
    configure!([])
    fake = fake!(labels: ["pipeline:ready"])
    change_answer!(workspace, "42")

    assert {:ok, _result} = Delivery.run(workspace, @issue, github_opts(fake))

    state = FakeGitHub.state(fake)
    assert state.labels == ["pipeline:ready-for-human"]

    # The verdict is persisted before the promotion state changes: a failure
    # between the two must not leave the issue promoted without its verdict.
    comment_at = Enum.find_index(state.requests, &(&1 == :comment_created))
    labels_at = Enum.find_index(state.requests, &match?({:labels, _}, &1))

    assert comment_at < labels_at
  end

  test "a label that cannot be removed fails the delivery instead of being ignored", %{workspace: workspace} do
    configure!([])
    fake = fake!(labels: ["pipeline:ready"], fail_label_delete: true)
    change_answer!(workspace, "42")

    assert {:error, {:github_request_failed, 500, _body}} = Delivery.run(workspace, @issue, github_opts(fake))
  end

  # --- acceptance contract (pipeline_contract) ------------------------------

  test "a strict contract the candidate does not satisfy blocks publishing", %{workspace: workspace} do
    # The gates are deliberately red: a strict scope finding has to stop the run
    # before the gates even execute (the error below is the acceptance one).
    configure!(gates: "exit 7", evidence: %{"repository-gates" => "true"})
    fake = fake!()

    issue = contract_issue(expected_paths: ["docs/changes/smoke.md"], required_evidence: ["repository-gates"])
    change_answer!(workspace, "42")

    assert {:error, {:delivery_acceptance_failed, result}} = Delivery.run(workspace, issue, github_opts(fake))

    assert result.status == :fail
    assert result.mode == :strict
    assert result.contract_version == 1
    assert Enum.map(result.findings, & &1.code) == [:expected_path_missing, :unexpected_path_changed]

    assert FakeGitHub.state(fake).requests == []
    assert FakeGitHub.sha(fake, delivery_branch()) == nil
  end

  test "green gates are not acceptance of the issue (the #64 regression)", %{workspace: workspace} do
    # The gates really run and really return 0 in this scenario; the acceptance
    # is what refuses the candidate, so nothing is published.
    configure!(gates: "echo green > gates-ran.txt")
    fake = fake!()

    issue =
      contract_issue(
        expected_paths: ["docs/changes/2026-09-30-pipeline-e2e-smoke.md", "tests/agent/run-tests.sh"],
        required_evidence: []
      )

    # The issue asked for two files; the candidate did not create one of them and
    # touched an unrelated one.
    File.mkdir_p!(Path.join(workspace, "docs/changes"))
    File.write!(Path.join(workspace, "docs/changes/2026-09-30-pipeline-e2e-smoke.md"), "smoke\n")
    change_answer!(workspace, "unrelated")

    # Nothing new is published, so the gates are not even executed (fail fast);
    # what matters is that the candidate is refused.
    assert {:error, {:delivery_acceptance_failed, result}} = Delivery.run(workspace, issue, github_opts(fake))

    assert result.status == :fail
    refute File.exists?(Path.join(workspace, "gates-ran.txt"))

    assert Enum.map(result.findings, & &1.code) == [:expected_path_missing, :unexpected_path_changed]

    assert Enum.map(result.findings, & &1.message) == [
             "expected path `tests/agent/run-tests.sh` is not part of the candidate change set",
             "changed path `answer.sh` is not in expected_paths nor allowed_extra_paths"
           ]

    state = FakeGitHub.state(fake)
    assert state.pulls == []
    assert state.labels == []
    assert state.comments == []
    assert FakeGitHub.sha(fake, delivery_branch()) == nil
  end

  test "an advisory divergence is reported and does not block the handoff", %{workspace: workspace} do
    configure!([])
    fake = fake!()

    issue = contract_issue(scope_mode: "advisory", expected_paths: ["docs/x.md"], allowed_extra_paths: ["answer.sh"])
    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, issue, github_opts(fake))

    assert result.contract.status == :advisory
    assert [%{code: :expected_path_missing, category: :scope, path: "docs/x.md"}] = result.contract.findings
    assert FakeGitHub.state(fake).labels == ["pipeline:ready-for-human"]

    [comment] = FakeGitHub.state(fake).comments
    assert comment["body"] =~ "- acceptance contract: `advisory` diverged"
    assert comment["body"] =~ "<!-- acceptance:result:#{result.candidate_sha} -->"

    # The findings survive the run: the persisted block is machine-readable.
    persisted = comment["body"] |> String.split("```json\n") |> List.last() |> String.replace_suffix("\n```\n", "")
    decoded = Jason.decode!(persisted)

    assert decoded["status"] == "advisory"
    assert decoded["mode"] == "advisory"
    assert decoded["contract_version"] == 1

    assert [
             %{
               "code" => "expected_path_missing",
               "category" => "scope",
               "message" => message,
               "path" => "docs/x.md"
             }
           ] = decoded["findings"]

    assert message =~ "is not part of the candidate change set"
  end

  test "an issue without a contract keeps the previous behavior and reports it as such", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, @issue, github_opts(fake))

    assert %Result{status: :not_configured, mode: nil, contract_version: nil, findings: []} = result.contract

    [comment] = FakeGitHub.state(fake).comments
    assert comment["body"] =~ "- acceptance contract: not declared in the issue body (acceptance not configured)"
  end

  test "a named evidence proves the required knowledge of the candidate", %{workspace: workspace} do
    configure!(evidence: %{"agent-tests" => "test -f answer.sh"})
    fake = fake!()

    issue = contract_issue(expected_paths: ["answer.sh"], required_evidence: ["repository-gates", "agent-tests"])
    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, issue, github_opts(fake))

    assert result.contract.status == :pass

    assert Enum.map(result.contract.evidence, &{&1.name, &1.status}) == [
             {"repository-gates", :passed},
             {"agent-tests", :passed}
           ]

    [comment] = FakeGitHub.state(fake).comments
    assert comment["body"] =~ "- acceptance contract: `strict` passed (1/1 expected path(s) delivered, 2 evidence)"
  end

  test "a required evidence without a provider blocks a strict candidate", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    issue = contract_issue(expected_paths: ["answer.sh"], required_evidence: ["wordpress-tests"])
    change_answer!(workspace, "42")

    assert {:error, {:delivery_acceptance_failed, result}} = Delivery.run(workspace, issue, github_opts(fake))

    assert [%{code: :required_evidence_missing}] = result.findings
    assert FakeGitHub.state(fake).pulls == []
    assert FakeGitHub.sha(fake, delivery_branch()) == nil
  end

  test "a red evidence blocks a candidate whose gates are green", %{workspace: workspace} do
    configure!(gates: "echo green > gates-ran.txt", evidence: %{"agent-tests" => "exit 4"})
    fake = fake!()
    issue = contract_issue(expected_paths: ["answer.sh"], required_evidence: ["agent-tests"])
    change_answer!(workspace, "42")

    assert {:error, {:delivery_acceptance_failed, result}} = Delivery.run(workspace, issue, github_opts(fake))

    # The gates executed and returned 0, and the candidate is still refused.
    assert File.read!(Path.join(workspace, "gates-ran.txt")) == "green\n"
    assert [%{code: :required_evidence_failed}] = result.findings
    assert FakeGitHub.state(fake).pulls == []
    assert FakeGitHub.sha(fake, delivery_branch()) == nil
  end

  test "multiple findings of both phases are reported together", %{workspace: workspace} do
    configure!(gates: "true", evidence: %{"agent-tests" => "exit 4"})
    fake = fake!()

    issue =
      contract_issue(
        scope_mode: "advisory",
        expected_paths: ["docs/x.md"],
        required_evidence: ["agent-tests"],
        allowed_extra_paths: ["answer.sh"]
      )

    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, issue, github_opts(fake))

    assert result.contract.status == :advisory

    assert Enum.map(result.contract.findings, & &1.code) == [
             :expected_path_missing,
             :required_evidence_failed
           ]

    assert Enum.map(result.contract.findings, & &1.category) == [:scope, :evidence]

    [comment] = FakeGitHub.state(fake).comments
    assert comment["body"] =~ "`advisory` diverged (2 finding(s))"
  end

  test "an unenforceable contract fails the run as an invalid_contract finding", %{workspace: workspace} do
    configure!([])
    fake = fake!()

    issue = %{@issue | description: "```yaml\npipeline_contract:\n  version: 2\n  scope_mode: strict\n```"}
    change_answer!(workspace, "42")

    assert {:error, {:delivery_acceptance_failed, result}} = Delivery.run(workspace, issue, github_opts(fake))

    assert %Result{status: :fail, mode: nil} = result
    assert [%{code: :invalid_contract, message: message}] = result.findings
    assert message =~ "unsupported_version"
    assert FakeGitHub.state(fake).requests == []
  end

  test "a second cycle over the published candidate is not failed by the contract", %{workspace: workspace} do
    configure!([])
    fake = fake!()
    issue = contract_issue(expected_paths: ["answer.sh"])
    change_answer!(workspace, "42")

    assert {:ok, first} = Delivery.run(workspace, issue, github_opts(fake))
    assert first.contract.status == :pass

    # Nothing new to accept: the candidate was accepted by the cycle that created
    # it, and the resume cycle only advances the published state.
    assert {:ok, second} = Delivery.run(workspace, issue, github_opts(fake))
    assert second.contract.status == :not_applicable
    assert second.candidate_sha == first.candidate_sha
    assert Enum.count(FakeGitHub.state(fake).comments) == 1
  end

  test "an artifact the gates create is not published without acceptance", %{workspace: workspace} do
    # The gates run inside the workspace and write a file: the candidate that
    # would be published includes it, so it has to be accepted too.
    configure!(gates: "echo artifact > gates-artifact.txt")
    fake = fake!()
    issue = contract_issue(expected_paths: ["answer.sh"])
    change_answer!(workspace, "42")

    assert {:error, {:delivery_acceptance_failed, result}} = Delivery.run(workspace, issue, github_opts(fake))

    assert [%{code: :unexpected_path_changed, path: "gates-artifact.txt"}] = result.findings
    assert result.change_set.unexpected == ["gates-artifact.txt"]
    assert FakeGitHub.state(fake).pulls == []
    assert FakeGitHub.sha(fake, delivery_branch()) == nil
  end

  test "an artifact of a declared evidence is accepted when the contract authorizes it", %{workspace: workspace} do
    configure!(gates: "true", evidence: %{"agent-tests" => "echo ran > evidence.txt"})
    fake = fake!()

    issue =
      contract_issue(
        expected_paths: ["answer.sh"],
        required_evidence: ["agent-tests"],
        allowed_extra_paths: ["evidence.txt"]
      )

    change_answer!(workspace, "42")

    assert {:ok, result} = Delivery.run(workspace, issue, github_opts(fake))

    assert result.contract.status == :pass
    assert [%{status: :passed}] = result.contract.evidence
    assert hd(FakeGitHub.state(fake).comments)["body"] =~ "`strict` passed (1/1 expected path(s) delivered, 1 evidence)"
  end

  defp fake!(attrs \\ []) do
    FakeGitHub.start!(Keyword.put(attrs, :remote, Process.get(:delivery_origin)))
  end

  defp configure!(delivery_overrides) do
    delivery = Keyword.merge([gates: "true", ci_timeout_ms: 5_000, ci_poll_interval_ms: 1], delivery_overrides)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_provider: %{"repo" => @repo, "token" => "test-token"},
      tracker_required_labels: ["pipeline:ready"],
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      delivery: delivery
    )
  end

  defp delivery_settings(kind, hosts) do
    %{delivery: %{enabled: true, gates: "true"}, tracker: %{kind: kind}, worker: %{ssh_hosts: hosts}}
  end

  defp delivery_branch, do: "pipeline/smoke-7"

  defp github_opts(fake, checks \\ nil) do
    [github: [request: FakeGitHub.request(fake, checks || checks_ok()), sleep: fn _ms -> :ok end]]
  end

  defp checks_ok, do: fn _sha, _index -> {:ok, %{status: 200, body: %{"check_runs" => [concluded("gates")]}}} end

  defp checks_failed do
    fn _sha, _index -> {:ok, %{status: 200, body: %{"check_runs" => [concluded("gates", "failure")]}}} end
  end

  defp checks_pending do
    fn _sha, _index -> {:ok, %{status: 200, body: %{"check_runs" => [in_progress("gates")]}}} end
  end

  defp checks_none, do: fn _sha, _index -> {:ok, %{status: 200, body: %{"check_runs" => []}}} end

  defp concluded(name, conclusion \\ "success") do
    %{"name" => name, "status" => "completed", "conclusion" => conclusion}
  end

  defp in_progress(name), do: %{"name" => name, "status" => "in_progress", "conclusion" => nil}

  defp change_answer!(workspace, content) do
    File.write!(Path.join(workspace, "answer.sh"), "#!/usr/bin/env bash\necho \"#{content}\"\n")
  end

  defp contract_issue(options) do
    %{@issue | description: contract_body(options)}
  end

  defp contract_body(options) do
    [
      "```yaml",
      "pipeline_contract:",
      "  version: 1",
      "  scope_mode: #{Keyword.get(options, :scope_mode, "strict")}",
      "  expected_paths: #{yaml_list(Keyword.get(options, :expected_paths, ["answer.sh"]))}",
      "  allowed_extra_paths: #{yaml_list(Keyword.get(options, :allowed_extra_paths, []))}",
      "  required_evidence: #{yaml_list(Keyword.get(options, :required_evidence, []))}",
      "  remote_access: false",
      "  deploy: false",
      "```"
    ]
    |> Enum.join("\n")
  end

  defp yaml_list(values), do: "[" <> Enum.map_join(values, ", ", &"\"#{&1}\"") <> "]"

  defp git!(dir, args) do
    opts = [stderr_to_stdout: true] ++ if(dir, do: [cd: dir], else: [])

    case System.cmd("git", args, opts) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end

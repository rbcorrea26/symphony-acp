defmodule SymphonyElixir.OnDemandTest do
  @moduledoc """
  On-demand lifecycle of the fork (ADR-0009 of the platform).

  A resident Symphony never needs to end by itself. The on-demand lifecycle does: the
  platform's dispatcher starts one cycle when there is work and expects the process to
  finish — with a meaningful exit code — instead of being killed by a shell timeout.

  These tests are deterministic and offline: the tracker is the in-memory adapter and
  the shutdown is injected, so nothing stops the test VM.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.CLI
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Shutdown
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @ack_typo "--i-understand-that-this-will-be-running-without-the-usually-guardrails"

  defmodule NeverUsedExecutor do
    @moduledoc "Executor that fails the test if the agent is asked for a turn."
    def start_session(_workspace, _opts), do: {:error, :agent_turns_must_not_run}
  end

  defp cli_deps(parent) do
    %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_run_options: fn options ->
        send(parent, {:run_options, options})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }
  end

  defp clear_on_demand_env do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :exit_when_idle)
      Application.delete_env(:symphony_elixir, :resume_only)
      Application.delete_env(:symphony_elixir, :issue_filter)
      Application.delete_env(:symphony_elixir, :max_runtime_seconds)
      Application.delete_env(:symphony_elixir, :shutdown_fun)
    end)
  end

  defp shutdown_to_test do
    parent = self()
    Application.put_env(:symphony_elixir, :shutdown_fun, fn code -> send(parent, {:shutdown, code}) end)
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp resume_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "item de teste",
      state: "Todo",
      dispatchable: true,
      labels: []
    }
  end

  describe "CLI: switches do modo sob demanda" do
    test "default preserva o comportamento upstream (sem opcoes sob demanda)" do
      clear_on_demand_env()
      assert :ok = CLI.evaluate([@ack_flag], cli_deps(self()))

      assert_received {:run_options, options}
      assert options[:exit_when_idle] == false
      assert options[:resume_only] == false
      assert options[:issue_filter] == nil
      assert options[:max_runtime_seconds] == nil
    end

    test "aceita o ciclo sob demanda com alvo explicito e teto de duracao" do
      clear_on_demand_env()

      assert :ok =
               CLI.evaluate(
                 [@ack_flag, "--exit-when-idle", "--issue", "GH-64", "--max-runtime-seconds", "3600"],
                 cli_deps(self())
               )

      assert_received {:run_options, options}
      assert options[:exit_when_idle] == true
      assert options[:issue_filter] == "GH-64"
      assert options[:max_runtime_seconds] == 3600
      assert options[:resume_only] == false
    end

    test "aceita retomada sem repetir o agente" do
      clear_on_demand_env()
      assert :ok = CLI.evaluate([@ack_flag, "--resume-only"], cli_deps(self()))
      assert_received {:run_options, options}
      assert options[:resume_only] == true
    end

    test "recusa teto de duracao nao numerico" do
      clear_on_demand_env()

      assert {:error, message} =
               CLI.evaluate([@ack_flag, "--max-runtime-seconds", "muito"], cli_deps(self()))

      assert message =~ "Usage: symphony"
      refute_received {:run_options, _}
    end

    test "recusa identificador de issue vazio" do
      clear_on_demand_env()
      assert {:error, message} = CLI.evaluate([@ack_flag, "--issue", ""], cli_deps(self()))
      assert message =~ "Usage: symphony"
      refute_received {:run_options, _}
    end

    test "exige o reconhecimento de guardrails antes de qualquer opcao sob demanda" do
      clear_on_demand_env()
      assert {:error, _banner} = CLI.evaluate([@ack_typo], cli_deps(self()))
      refute_received {:run_options, _}
    end
  end

  describe "encerramento explicito" do
    test "nao mata processo: pede parada graciosa com o codigo de saida" do
      clear_on_demand_env()
      parent = self()

      Application.put_env(:symphony_elixir, :shutdown_fun, fn code ->
        send(parent, {:stopped, code})
      end)

      assert :ok = Shutdown.request(0, "teste")
      assert_received {:stopped, 0}
    end
  end

  describe "orquestrador: idle sob demanda" do
    test "sem trabalho pendente encerra o ciclo com exit 0" do
      clear_on_demand_env()
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :exit_when_idle, true)
      shutdown_to_test()

      start_orchestrator()

      assert_receive {:shutdown, 0}, 5_000
    end

    test "filtro de issue que nao casa nada tambem e idle" do
      clear_on_demand_env()
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :exit_when_idle, true)
      Application.put_env(:symphony_elixir, :issue_filter, "GH-9999")
      shutdown_to_test()

      start_orchestrator()

      assert_receive {:shutdown, 0}, 5_000
    end

    test "sem --exit-when-idle o comportamento upstream (residencia) e preservado" do
      clear_on_demand_env()
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :exit_when_idle, false)
      shutdown_to_test()

      pid = start_orchestrator()

      refute_receive {:shutdown, _code}, 500
      assert Process.alive?(pid)
    end
  end

  describe "resume-only" do
    test "nao executa turnos do agente quando o ciclo e apenas de retomada" do
      clear_on_demand_env()
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      issue = resume_issue("issue-1", "GH-70")

      log =
        capture_log(fn ->
          assert :ok =
                   AgentRunner.run(issue, nil,
                     resume_only: true,
                     executor: NeverUsedExecutor,
                     issue_state_fetcher: fn _ids -> {:ok, [issue]} end
                   )
        end)

      assert log =~ "agent turns skipped"
    end

    test "executa turnos do agente quando nao e retomada" do
      clear_on_demand_env()
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      issue = resume_issue("issue-2", "GH-71")

      assert_raise RuntimeError, fn ->
        AgentRunner.run(issue, nil,
          resume_only: false,
          executor: NeverUsedExecutor,
          issue_state_fetcher: fn _ids -> {:ok, [issue]} end
        )
      end
    end
  end
end

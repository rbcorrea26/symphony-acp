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
      Application.delete_env(:symphony_elixir, :shutdown_exit_code)
    end)
  end

  defp shutdown_to_test do
    parent = self()
    Application.put_env(:symphony_elixir, :shutdown_fun, fn code -> send(parent, {:shutdown, code}) end)
  end

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> stop_orchestrator(pid) end)
    pid
  end

  # O orquestrador e ligado ao processo de teste: quando ele sai, o orquestrador pode
  # morrer entre o `Process.alive?` e o `GenServer.stop`, que entao falha com
  # `:noproc` e derruba o `on_exit` (e o teste) por corrida.
  defp stop_orchestrator(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  # Espera um ciclo de poll terminar e o proximo tick ser agendado: um `sleep` fixo
  # nao garante a ordem sob carga, e o cenario de teste depende de o primeiro ciclo
  # ja ter lido o tracker antes de o item entrar.
  defp wait_for_poll_cycle(pid, attempts \\ 150) do
    state = :sys.get_state(pid)
    now_ms = System.monotonic_time(:millisecond)

    next_tick_scheduled? =
      not state.poll_check_in_progress and is_integer(state.next_poll_due_at_ms) and
        state.next_poll_due_at_ms > now_ms + 50

    cond do
      next_tick_scheduled? ->
        :ok

      attempts == 0 ->
        flunk("orchestrator did not schedule the next poll cycle")

      true ->
        Process.sleep(20)
        wait_for_poll_cycle(pid, attempts - 1)
    end
  end

  # Simula trabalho que terminou entre polls com o prazo ja vencido (o estado muda por
  # `:sys.replace_state`, como nos testes de retry do upstream).
  defp expire_deadline(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | deadline_ms: System.monotonic_time(:millisecond) - 1}
    end)
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

    test "recusa teto de duracao zero (que desligaria o teto em silencio)" do
      clear_on_demand_env()

      assert {:error, message} = CLI.evaluate([@ack_flag, "--max-runtime-seconds", "0"], cli_deps(self()))

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

    test "o codigo pedido pelo ciclo vence o default residente no fim do processo" do
      clear_on_demand_env()
      shutdown_to_test()

      assert :ok = Shutdown.request(3, "teto de duracao atingido")

      # A CLI encerra a VM quando a arvore de supervisao cai (motivo `:shutdown`):
      # sem o registro, o codigo do ciclo seria trocado pelo default residente 1.
      assert Shutdown.exit_code_for_reason(:shutdown) == 3
    end

    test "sem ciclo sob demanda o default residente do upstream e preservado" do
      clear_on_demand_env()

      assert Shutdown.exit_code_for_reason(:normal) == 0
      assert Shutdown.exit_code_for_reason(:shutdown) == 1
    end
  end

  describe "teto de duracao" do
    test "atingir o teto encerra o ciclo com 3 (trabalho pode seguir pendente)" do
      clear_on_demand_env()
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 50)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :max_runtime_seconds, 1)
      shutdown_to_test()

      start_orchestrator()

      assert_receive {:shutdown, 3}, 5_000
      assert Shutdown.exit_code_for_reason(:shutdown) == 3
    end

    test "o teto e respeitado sem esperar o proximo poll" do
      clear_on_demand_env()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :max_runtime_seconds, 1)
      shutdown_to_test()

      start_orchestrator()

      # Com poll de 30s, o teto de 1s so e visto se o proximo ciclo for agendado no
      # vencimento dele (e nao no fim do intervalo de poll).
      assert_receive {:shutdown, 3}, 3_000
    end

    test "teto vencido nao inicia trabalho novo" do
      clear_on_demand_env()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :max_runtime_seconds, 1)
      shutdown_to_test()

      pid = start_orchestrator()

      # O item fica despachavel depois do poll inicial e antes do vencimento do teto:
      # o ciclo que cai no teto nao pode iniciar um run que seria abandonado no mesmo
      # instante. A espera e pelo estado do orquestrador (o proximo ciclo agendado),
      # nao por um `sleep` fixo, que sob carga poderia deixar o item entrar antes do
      # poll inicial.
      wait_for_poll_cycle(pid)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [resume_issue("issue-3", "GH-73")])

      log = capture_log(fn -> assert_receive {:shutdown, 3}, 5_000 end)

      # Controle de que o log do orquestrador (outro processo) foi capturado.
      assert log =~ "On-demand cycle finished"
      refute log =~ "Dispatching issue to agent"
    end

    test "teto vencido com ciclo comprovadamente idle encerra com 0" do
      clear_on_demand_env()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :exit_when_idle, true)
      Application.put_env(:symphony_elixir, :max_runtime_seconds, 1)
      shutdown_to_test()

      pid = start_orchestrator()

      # Trabalho que termina entre polls com o prazo ja vencido: o ciclo do teto nao
      # pode responder `3` ("ainda pode haver trabalho"), senao o dispatcher repete um
      # ciclo concluido. O teto impede o despacho, nao a checagem de idle.
      expire_deadline(pid)
      send(pid, :run_poll_cycle)

      assert_receive {:shutdown, 0}, 5_000
      refute_receive {:shutdown, 3}, 1_000
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

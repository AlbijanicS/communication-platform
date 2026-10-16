defmodule DiscordClone.Media.DirectCallTarget do
  @moduledoc """
  Supervised capacity-two target for one accepted Direct Call.

  Real audio is the default; deterministic tests can inject fake transport.
  Each real Session owns its transport.
  """

  use Supervisor, restart: :temporary, shutdown: 5_000

  alias DiscordClone.Media.{
    AdmissionCoordinator,
    DirectCallTargetServer,
    Profile,
    SessionSupervisor,
    Target
  }

  @doc "Starts a target under the application media supervisor."
  @spec start(Ecto.UUID.t()) :: DynamicSupervisor.on_start_child()
  def start(call_id), do: start_target(call_id, make_ref())

  defp start_target(call_id, generation) do
    with :ok <- startup_control(:before_start, %{call_id: call_id}),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             DiscordClone.Media.DirectCallTargetSupervisor,
             {__MODULE__, call_id: call_id, generation: generation}
           ) do
      await_startup_identity(call_id, generation, pid)
    else
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = failed ->
        if transient_start_failure?(reason) do
          AdmissionCoordinator.call_target_start_cancelled(call_id, generation)
          {:error, :temporarily_unavailable}
        else
          failed
        end
    end
  catch
    :exit, _reason ->
      AdmissionCoordinator.call_target_start_cancelled(call_id, generation)
      {:error, :temporarily_unavailable}
  end

  defp await_startup_identity(call_id, generation, pid) do
    result =
      try do
        with :ok <- startup_control(:started, %{call_id: call_id, target: pid}),
             {:ok, %{runtime_generation: ^generation}} <- identity(pid),
             %{runtime_generation: ^generation, status: :ready} <-
               AdmissionCoordinator.call_target_snapshot(call_id) do
          {:ok, pid}
        else
          _ -> {:error, :temporarily_unavailable}
        end
      catch
        :exit, _reason -> {:error, :temporarily_unavailable}
      end

    if match?({:error, _}, result), do: retire_startup_target(call_id, generation, pid)
    result
  end

  defp retire_startup_target(call_id, generation, pid) do
    permission =
      try do
        AdmissionCoordinator.begin_call_target_start_cleanup(call_id, generation)
      catch
        :exit, _ -> {:error, :temporarily_unavailable}
      end

    # Only the coordinator can authorize retiring a current target. A stale
    # generation may retire its captured pid without touching the winner.
    if permission in [:ok, {:error, :stale_runtime}] do
      target_monitor = Process.monitor(pid)

      {worker, worker_monitor} =
        spawn_monitor(fn ->
          DynamicSupervisor.terminate_child(DiscordClone.Media.DirectCallTargetSupervisor, pid)
        end)

      confirmed? =
        receive do
          {:DOWN, ^target_monitor, :process, ^pid, _reason} -> true
        after
          5_000 -> false
        end

      Process.exit(worker, :kill)
      Process.demonitor(worker_monitor, [:flush])
      Process.demonitor(target_monitor, [:flush])

      if confirmed?, do: AdmissionCoordinator.call_target_start_cancelled(call_id, generation)
      # Unconfirmed retirement retains the coordinator's monitored cleaning
      # record. Its exact target DOWN completes cleanup even after this wait.
    end
  end

  # Approved test-only control. Callbacks run outside the admission mailbox.
  @doc false
  def startup_control(stage, context) do
    case Application.get_env(:discord_clone, :call_target_startup_control, %{}) do
      %{barrier: barrier} when is_function(barrier, 2) -> barrier.(stage, context)
      _ -> :ok
    end
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    call_id = Keyword.fetch!(opts, :call_id)
    generation = Keyword.get_lazy(opts, :generation, &make_ref/0)
    profile = Keyword.get(opts, :profile, Profile.direct_call())
    # start/1 supplies the generation for exclusive/reusable startup.
    # Explicit start_link callers retain the generation-replacement API.
    exclusive_start? = Keyword.has_key?(opts, :generation)
    start_generation(call_id, generation, profile, exclusive_start?)
  end

  defp start_generation(call_id, generation, profile, exclusive_start?) do
    claim =
      if exclusive_start? do
        AdmissionCoordinator.claim_call_target_start(call_id, generation)
      else
        AdmissionCoordinator.call_target_starting(call_id, generation)
      end

    with :ok <- claim do
      result =
        cond do
          profile != Profile.direct_call() ->
            {:error, :invalid_profile}

          exclusive_start? ->
            with :ok <- startup_control(:claimed, %{call_id: call_id, generation: generation}) do
              Supervisor.start_link(__MODULE__, {call_id, generation, profile})
            end

          true ->
            Supervisor.start_link(__MODULE__, {call_id, generation, profile})
        end

      report_start_result(call_id, generation, result)
    else
      {:ok, pid} -> {:error, {:already_started, pid}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason ->
      AdmissionCoordinator.call_target_start_cancelled(call_id, generation)
      {:error, :temporarily_unavailable}
  end

  defp report_start_result(_call_id, _generation, {:ok, _pid} = started), do: started

  defp report_start_result(call_id, generation, {:error, reason} = failed) do
    if transient_start_failure?(reason) do
      AdmissionCoordinator.call_target_start_cancelled(call_id, generation)
      {:error, :temporarily_unavailable}
    else
      :ok = AdmissionCoordinator.call_target_start_failed(call_id, generation, reason)
      failed
    end
  end

  defp transient_start_failure?(reason)
       when reason in [
              :recovering,
              :recovery_timeout,
              :temporarily_unavailable,
              :unavailable,
              :noproc,
              :timeout,
              :stale_runtime
            ],
       do: true

  defp transient_start_failure?({reason, {GenServer, :call, _args}}),
    do: transient_start_failure?(reason)

  defp transient_start_failure?({:shutdown, reason}), do: transient_start_failure?(reason)

  defp transient_start_failure?({:failed_to_start_child, _child, reason}),
    do: transient_start_failure?(reason)

  defp transient_start_failure?(_reason), do: false

  @spec identity(pid()) :: {:ok, map()} | {:error, :unavailable}
  def identity(target), do: call_server(target, :identity)

  @spec admit(pid(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def admit(target, user_id), do: call_server(target, {:admit, user_id})

  @spec session(pid(), Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, pid()} | {:error, atom()}
  def session(target, user_id, call_session_id),
    do: call_server(target, {:session, user_id, call_session_id})

  def real_transport?,
    do: Application.get_env(:discord_clone, :direct_call_transport, :real) == :real

  @spec remove(pid(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def remove(target, user_id, call_session_id),
    do: call_server(target, {:remove, user_id, call_session_id})

  @spec shutdown(pid()) :: :ok
  def shutdown(target) do
    case call_server(target, :shutdown) do
      :ok ->
        try do
          Supervisor.stop(target, :normal)
        catch
          :exit, _ -> :ok
        end

      {:error, :unavailable} ->
        :ok
    end
  end

  @impl true
  def init({call_id, generation, profile}) do
    children = [
      Supervisor.child_spec(
        {SessionSupervisor, target: Target.direct_call(call_id), generation: generation},
        id: DynamicSupervisor
      ),
      %{
        id: DiscordClone.Voice.Forwarder,
        start: {DiscordClone.Voice.Forwarder, :start_call_link, [call_id, generation]}
      },
      {DirectCallTargetServer,
       call_id: call_id, generation: generation, profile: profile, target: self()}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  defp command_timeout(:identity) do
    case Application.get_env(:discord_clone, :call_target_startup_control, %{}) do
      %{identity_timeout_ms: timeout} when is_integer(timeout) and timeout > 0 ->
        min(timeout, 5_000)

      _ ->
        5_000
    end
  end

  defp command_timeout(_command), do: 5_000

  defp call_server(target, command) do
    case target |> Supervisor.which_children() |> List.keyfind(DirectCallTargetServer, 0) do
      {DirectCallTargetServer, server, _, _} when is_pid(server) ->
        GenServer.call(server, command, command_timeout(command))

      _ ->
        {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end
end

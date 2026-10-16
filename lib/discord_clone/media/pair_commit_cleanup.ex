defmodule DiscordClone.Media.PairCommitCleanup do
  @moduledoc false

  alias DiscordClone.Media.DirectCallTarget

  # Capture the target's entire tree before shutdown. A target DOWN alone
  # does not certify that its Session children have finished terminating.
  def run(target, deadline, retired_worker) do
    worker_monitor = Process.monitor(retired_worker)

    receive do
      {:DOWN, ^worker_monitor, :process, ^retired_worker, _} -> :ok
    after
      remaining(deadline) -> exit(:worker_retirement_unconfirmed)
    end

    processes = descendants(target, deadline)
    monitors = Enum.map(processes, &{&1, Process.monitor(&1)})
    {shutdown, shutdown_monitor} = spawn_monitor(fn -> DirectCallTarget.shutdown(target) end)

    receive do
      {:DOWN, ^shutdown_monitor, :process, ^shutdown, _} -> :ok
    after
      max(remaining(deadline) - 50, 0) -> Process.exit(shutdown, :kill)
    end

    Enum.each(processes, &Process.exit(&1, :kill))

    Enum.each(monitors, fn {pid, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        remaining(deadline) -> exit(:target_retirement_unconfirmed)
      end
    end)

    Process.demonitor(shutdown_monitor, [:flush])
    :ok
  end

  # Linked ownership is readable even while a supervisor is starting a child.
  # Follow only child ancestry; links to parents and unrelated roots are excluded.
  def linked_resources(root) do
    walk_links([root], MapSet.new(), [])
  end

  def retire(target, resources, deadline) do
    processes =
      [target | resources]
      |> Enum.filter(&is_pid/1)
      |> Enum.flat_map(&linked_resources/1)
      |> Enum.uniq()

    monitors = Enum.map(processes, &{&1, Process.monitor(&1)})

    Enum.each(processes, fn pid ->
      # Let ExICE release hosted TURN allocations. Setup/Session processes must
      # also retire while blocked in init or negotiation, so kill their owners.
      reason =
        if match?({ExICE.ICEAgent, _, _}, :proc_lib.translate_initial_call(pid)),
          do: :shutdown,
          else: :kill

      Process.exit(pid, reason)
    end)

    Enum.each(monitors, fn {pid, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        max(remaining(deadline) - 50, 0) ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^pid, _} -> :ok
          after
            remaining(deadline) -> exit(:target_retirement_unconfirmed)
          end
      end
    end)

    :ok
  end

  defp walk_links([], _seen, resources), do: resources

  defp walk_links([pid | rest], seen, resources) do
    if MapSet.member?(seen, pid) do
      walk_links(rest, seen, resources)
    else
      links =
        case Process.info(pid, :links) do
          {:links, links} -> Enum.filter(links, &(is_pid(&1) and owned_child?(pid, &1)))
          nil -> []
        end

      walk_links(links ++ rest, MapSet.put(seen, pid), [pid | resources])
    end
  end

  defp owned_child?(parent, child) do
    case Process.info(child, :dictionary) do
      {:dictionary, dictionary} ->
        case Keyword.get(dictionary, :"$ancestors", []) do
          [^parent | _] -> true
          [name | _] when is_atom(name) -> Process.whereis(name) == parent
          _ -> false
        end

      nil ->
        false
    end
  end

  defp descendants(target, deadline) do
    children = GenServer.call(target, :which_children, min(remaining(deadline), 500))

    [
      target
      | Enum.flat_map(children, fn
          {_, pid, :supervisor, _} when is_pid(pid) -> descendants(pid, deadline)
          {_, pid, _, _} when is_pid(pid) -> [pid]
          _ -> []
        end)
    ]
  catch
    :exit, {:noproc, _} -> []
    :exit, {:normal, _} -> []
    :exit, {:shutdown, _} -> []
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end

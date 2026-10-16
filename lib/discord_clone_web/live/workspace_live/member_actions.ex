defmodule DiscordCloneWeb.WorkspaceLive.MemberActions do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]

  alias DiscordClone.{Friendships, Workspaces}

  @member_actions [
    "promote_to_admin",
    "demote_to_member",
    "mute",
    "unmute",
    "timeout",
    "remove_timeout"
  ]

  def run(socket, params, workspace_id, refresh)

  def run(
        socket,
        %{"action" => "send_friend_request", "user_id" => target_user_id},
        workspace_id,
        refresh
      ) do
    socket.assigns.current_scope
    |> Friendships.send_friend_request_to_workspace_member(workspace_id, target_user_id)
    |> handle_result(
      socket,
      refresh,
      %{workspace_id: workspace_id, target_user_id: target_user_id},
      success: "Friend Request sent.",
      error: "Friend Request could not be sent."
    )
  end

  def run(socket, %{"action" => action, "user_id" => user_id} = params, workspace_id, refresh)
      when action in @member_actions do
    target_user_id = user_id

    socket.assigns.current_scope
    |> dispatch_member_action(action, workspace_id, target_user_id, params)
    |> handle_result(
      socket,
      refresh,
      %{workspace_id: workspace_id, target_user_id: target_user_id},
      error: "Member action could not be completed."
    )
  end

  def run(socket, _params, _workspace_id, _refresh) do
    {:noreply, put_flash(socket, :error, "Member action could not be completed.")}
  end

  def kick(socket, %{"user_id" => user_id} = params, workspace_id, refresh) do
    target_user_id = user_id
    reason = Map.get(params, "reason", "")

    socket.assigns.current_scope
    |> Workspaces.kick_member(workspace_id, target_user_id, %{"reason" => reason})
    |> handle_result(
      socket,
      refresh,
      %{workspace_id: workspace_id, target_user_id: target_user_id},
      success: "Member removed from the workspace.",
      reason_required: "A reason is required to kick a member.",
      error: "Member could not be kicked."
    )
  end

  def ban(socket, %{"user_id" => user_id} = params, workspace_id, refresh) do
    target_user_id = user_id

    ban_attrs = %{
      "reason" => Map.get(params, "reason", ""),
      "cleanup_window" => Map.get(params, "cleanup_window")
    }

    socket.assigns.current_scope
    |> Workspaces.ban_member(workspace_id, target_user_id, ban_attrs)
    |> handle_result(
      socket,
      refresh,
      %{workspace_id: workspace_id, target_user_id: target_user_id},
      success: "Member banned from the workspace.",
      reason_required: "A reason is required to ban a member.",
      error: "Member could not be banned."
    )
  end

  def unban(socket, %{"user_id" => user_id}, workspace_id, refresh) do
    target_user_id = user_id

    socket.assigns.current_scope
    |> Workspaces.unban_member(workspace_id, target_user_id)
    |> handle_result(
      socket,
      refresh,
      %{workspace_id: workspace_id, target_user_id: target_user_id},
      success: "Member unbanned.",
      error: "Member could not be unbanned."
    )
  end

  def voice_disconnect(
        socket,
        %{"voice_channel_id" => voice_channel_id, "user_id" => target_user_id},
        workspace_id
      ) do
    _ =
      Workspaces.voice_disconnect_member(
        socket.assigns.current_scope,
        workspace_id,
        voice_channel_id,
        target_user_id
      )

    {:noreply, socket}
  end

  def voice_disconnect(socket, _params, _workspace_id), do: {:noreply, socket}

  defp dispatch_member_action(scope, "promote_to_admin", workspace_id, target_user_id, _params) do
    Workspaces.change_member_role(scope, workspace_id, target_user_id, "admin")
  end

  defp dispatch_member_action(scope, "demote_to_member", workspace_id, target_user_id, _params) do
    Workspaces.change_member_role(scope, workspace_id, target_user_id, "member")
  end

  defp dispatch_member_action(scope, "mute", workspace_id, target_user_id, _params) do
    Workspaces.mute_member(scope, workspace_id, target_user_id)
  end

  defp dispatch_member_action(scope, "unmute", workspace_id, target_user_id, _params) do
    Workspaces.unmute_member(scope, workspace_id, target_user_id)
  end

  defp dispatch_member_action(scope, "timeout", workspace_id, target_user_id, params) do
    Workspaces.timeout_member(
      scope,
      workspace_id,
      target_user_id,
      Map.get(params, "timeout_duration")
    )
  end

  defp dispatch_member_action(scope, "remove_timeout", workspace_id, target_user_id, _params) do
    Workspaces.remove_member_timeout(scope, workspace_id, target_user_id)
  end

  defp handle_result({:ok, _result}, socket, refresh, payload, opts) do
    socket =
      case Keyword.fetch(opts, :success) do
        {:ok, message} -> put_flash(socket, :info, message)
        :error -> socket
      end

    {:noreply, refresh.(socket, payload)}
  end

  defp handle_result({:error, :reason_required}, socket, _refresh, _payload, opts) do
    {:noreply, put_flash(socket, :error, Keyword.fetch!(opts, :reason_required))}
  end

  defp handle_result({:error, _reason}, socket, _refresh, _payload, opts) do
    {:noreply, put_flash(socket, :error, Keyword.fetch!(opts, :error))}
  end

  defp handle_result({:error, _reason, _detail}, socket, _refresh, _payload, opts) do
    {:noreply, put_flash(socket, :error, Keyword.fetch!(opts, :error))}
  end
end

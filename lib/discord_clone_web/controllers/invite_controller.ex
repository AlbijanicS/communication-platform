defmodule DiscordCloneWeb.InviteController do
  use DiscordCloneWeb, :controller

  alias DiscordClone.Workspaces

  def show(conn, %{"code" => code}) do
    case Workspaces.preview_workspace_invite(conn.assigns.current_scope, code) do
      {:ok, preview} ->
        render(conn, :show, preview: preview)

      {:error, reason} ->
        render_invite_failure(conn, reason)
    end
  end

  def accept(conn, %{"code" => code}) do
    case Workspaces.accept_workspace_invite(conn.assigns.current_scope, code) do
      {:ok, landing} ->
        conn
        |> maybe_put_already_member_flash(landing)
        |> redirect(to: ~p"/workspaces/#{landing.workspace_id}/channels/#{landing.channel_id}")

      {:error, reason} ->
        render_invite_failure(conn, reason)
    end
  end

  defp render_invite_failure(conn, reason) do
    failure = invite_failure(reason)

    conn
    |> put_status(failure.status)
    |> render(:not_found, title: failure.title, body: failure.body)
  end

  defp invite_failure(:not_found) do
    %{
      status: :not_found,
      title: "This invite link cannot be used.",
      body: "Ask for a fresh invite link and try again."
    }
  end

  defp invite_failure(:banned) do
    %{
      status: :forbidden,
      title: "This invite link cannot be used.",
      body: "Ask for a fresh invite link and try again."
    }
  end

  defp invite_failure(:revoked) do
    %{
      status: :gone,
      title: "This invite link is no longer active.",
      body: "Ask for a fresh invite link and try again."
    }
  end

  defp invite_failure(:expired) do
    %{
      status: :gone,
      title: "This invite link has expired.",
      body: "Ask for a fresh invite link and try again."
    }
  end

  defp invite_failure(:full) do
    %{
      status: :gone,
      title: "This invite link has no remaining uses.",
      body: "Ask for a fresh invite link and try again."
    }
  end

  defp maybe_put_already_member_flash(conn, %{already_member?: true}),
    do: put_flash(conn, :info, "You're already in this workspace.")

  defp maybe_put_already_member_flash(conn, _landing), do: conn
end

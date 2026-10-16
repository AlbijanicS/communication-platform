defmodule DiscordClone.WorkspacesFixtures do
  @moduledoc """
  Test helpers for creating workspace entities through the Workspaces context.
  """

  import DiscordClone.AccountsFixtures

  alias DiscordClone.Workspaces

  def workspace_fixture(attrs \\ %{}) do
    scope = user_scope_fixture()

    {:ok, workspace} =
      attrs
      |> valid_workspace_attributes()
      |> then(&Workspaces.create_workspace(scope, &1))

    workspace
  end

  def valid_workspace_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Workspace #{System.unique_integer([:positive])}"
    })
  end
end

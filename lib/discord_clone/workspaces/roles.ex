defmodule DiscordClone.Workspaces.Roles do
  @moduledoc """
  Single source of truth for the Workspace Role vocabulary and the
  capability rules that depend only on Roles.

  Every other module — the Workspaces context, the membership schema, and the
  Chat context — references these values and predicates instead of spelling the
  Role strings (`"owner"`/`"admin"`/`"member"`) as bare literals.
  """

  @owner "owner"
  @admin "admin"
  @member "member"
  @all [@owner, @admin, @member]

  @doc "The owner Role value."
  def owner, do: @owner

  @doc "The admin Role value."
  def admin, do: @admin

  @doc "The member Role value."
  def member, do: @member

  @doc "Every valid Workspace Role, for validation and iteration."
  def all, do: @all

  @doc "Whether `role` is the owner Role."
  def owner?(role), do: role == @owner

  @doc "Whether `role` is the admin Role."
  def admin?(role), do: role == @admin

  @doc "Whether `role` is the member Role."
  def member?(role), do: role == @member

  @doc """
  Whether an actor holding `actor_role` may take a moderation action against a
  target holding `target_role`. Owners and admins may moderate admins and
  members; nobody may moderate an owner.
  """
  def can_moderate?(actor_role, target_role),
    do: actor_role in [@owner, @admin] and target_role in [@admin, @member]
end

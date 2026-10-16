defmodule DiscordClone.Chat.DirectConversation do
  @moduledoc """
  The canonical pair subtype for a one-to-one Direct Conversation.

  Its shared primary key is the durable Conversation identity. Participant
  identity remains independent from the deletable Friendship row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, source: :conversation_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "direct_conversations" do
    belongs_to :conversation, DiscordClone.Chat.Conversation,
      define_field: false,
      foreign_key: :id

    belongs_to :user_low, DiscordClone.Accounts.User
    belongs_to :user_high, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(direct_conversation, attrs) do
    direct_conversation
    |> change(attrs)
    |> validate_required([:id, :user_low_id, :user_high_id])
    |> foreign_key_constraint(:id)
    |> foreign_key_constraint(:user_low_id)
    |> foreign_key_constraint(:user_high_id)
    |> check_constraint(:user_low_id, name: :direct_conversations_canonical_pair)
    |> unique_constraint([:user_low_id, :user_high_id])
  end

  def other_user_id(%__MODULE__{user_low_id: user_id, user_high_id: other_user_id}, user_id),
    do: other_user_id

  def other_user_id(%__MODULE__{user_high_id: user_id, user_low_id: other_user_id}, user_id),
    do: other_user_id

  def other_user_id(%__MODULE__{}, _user_id), do: nil

  def other_user(%__MODULE__{user_low_id: user_id, user_high: other_user}, user_id),
    do: other_user

  def other_user(%__MODULE__{user_high_id: user_id, user_low: other_user}, user_id),
    do: other_user

  def other_user(%__MODULE__{}, _user_id), do: nil
end

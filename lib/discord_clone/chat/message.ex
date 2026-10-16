defmodule DiscordClone.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "messages" do
    field :content, :string
    field :mention_recognition, :map, default: %{}
    field :seq, :integer
    field :deleted_at, :utc_datetime

    belongs_to :channel, DiscordClone.Workspaces.Channel,
      foreign_key: :channel_id,
      source: :conversation_id

    belongs_to :user, DiscordClone.Accounts.User
    belongs_to :deleted_by_user, DiscordClone.Accounts.User
    belongs_to :reply_to_message, __MODULE__

    has_many :message_reactions, DiscordClone.Chat.MessageReaction

    has_many :activity_items, DiscordClone.Activities.ActivityItem,
      foreign_key: :source_message_id

    timestamps(type: :utc_datetime_usec)
  end

  def display_preloads, do: [:user, reply_to_message: :user]

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:channel_id, :user_id, :content])
    |> validate_message()
  end

  def direct_message_changeset(message, attrs) do
    message
    |> cast(attrs, [:content])
    |> validate_message()
  end

  defp validate_message(changeset) do
    changeset
    |> update_change(:content, &normalize_content/1)
    |> validate_required([:channel_id, :user_id, :content])
    |> validate_length(:content, min: 1, max: 4_000)
    |> foreign_key_constraint(:channel_id, name: :messages_conversation_id_fkey)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:reply_to_message_id)
    |> check_constraint(:reply_to_message_id, name: :messages_reply_target_not_self)
    |> check_constraint(:seq, name: :messages_seq_positive)
    |> unique_constraint(:seq, name: :messages_conversation_id_seq_index)
  end

  def soft_delete_changeset(message, attrs) do
    message
    |> cast(attrs, [:deleted_at, :deleted_by_user_id])
    |> validate_required([:deleted_at, :deleted_by_user_id])
    |> foreign_key_constraint(:deleted_by_user_id)
  end

  defp normalize_content(content) when is_binary(content), do: String.trim(content)
  defp normalize_content(content), do: content
end

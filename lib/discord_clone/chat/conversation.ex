defmodule DiscordClone.Chat.Conversation do
  @moduledoc """
  Durable identity and sequence allocator shared by every Conversation kind.

  Conversation rows are created only as part of a public subtype workflow so
  the deferred database invariant always observes one matching subtype.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :kind, Ecto.Enum, values: [:workspace_channel, :direct_conversation]
    field :last_message_seq, :integer, default: 0

    has_one :channel, DiscordClone.Workspaces.Channel, foreign_key: :id
    has_one :direct_conversation, DiscordClone.Chat.DirectConversation, foreign_key: :id
    has_many :messages, DiscordClone.Chat.Message, foreign_key: :channel_id
    has_many :read_states, DiscordClone.Chat.ChannelReadState, foreign_key: :channel_id
    has_many :unread_spans, DiscordClone.Chat.ChannelUnreadSpan, foreign_key: :channel_id

    timestamps(type: :utc_datetime_usec)
  end

  def workspace_channel_changeset(conversation \\ %__MODULE__{}) do
    conversation
    |> change(kind: :workspace_channel)
    |> validate_required([:kind])
    |> check_constraint(:kind, name: :conversations_kind_supported)
    |> check_constraint(:last_message_seq,
      name: :conversations_last_message_seq_non_negative
    )
  end

  def direct_conversation_changeset(conversation \\ %__MODULE__{}) do
    conversation
    |> change(kind: :direct_conversation)
    |> validate_required([:kind])
    |> check_constraint(:kind, name: :conversations_kind_supported)
    |> check_constraint(:last_message_seq,
      name: :conversations_last_message_seq_non_negative
    )
  end
end

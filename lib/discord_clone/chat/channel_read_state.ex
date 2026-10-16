defmodule DiscordClone.Chat.ChannelReadState do
  @moduledoc """
  Channel-facing projection of a Conversation Read State.

  The persisted owner is `conversation_id`; this schema keeps the established
  Channel workflow field name at the public Chat boundary.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "conversation_read_states" do
    field :unread_count, :integer, default: 0
    field :first_unread_seq, :integer
    field :last_unread_seq, :integer
    field :last_viewed_anchor_seq, :integer
    field :last_opened_at, :utc_datetime

    belongs_to :conversation, DiscordClone.Chat.Conversation,
      foreign_key: :channel_id,
      source: :conversation_id

    belongs_to :user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(read_state, attrs) do
    read_state
    |> cast(attrs, [
      :channel_id,
      :user_id,
      :unread_count,
      :first_unread_seq,
      :last_unread_seq,
      :last_viewed_anchor_seq,
      :last_opened_at
    ])
    |> validate_required([:channel_id, :user_id, :unread_count])
    |> validate_number(:unread_count, greater_than_or_equal_to: 0)
    |> validate_number(:first_unread_seq, greater_than: 0)
    |> validate_number(:last_unread_seq, greater_than: 0)
    |> validate_number(:last_viewed_anchor_seq, greater_than: 0)
    |> validate_summary_bounds()
    |> foreign_key_constraint(:channel_id, name: :conversation_read_states_conversation_id_fkey)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:unread_count,
      name: :conversation_read_states_unread_count_non_negative
    )
    |> check_constraint(:first_unread_seq,
      name: :conversation_read_states_unread_summary_consistent
    )
    |> check_constraint(:last_viewed_anchor_seq,
      name: :conversation_read_states_last_viewed_anchor_seq_positive
    )
    |> unique_constraint(:channel_id,
      name: :conversation_read_states_conversation_id_user_id_index
    )
  end

  defp validate_summary_bounds(changeset) do
    unread_count = get_field(changeset, :unread_count)
    first_seq = get_field(changeset, :first_unread_seq)
    last_seq = get_field(changeset, :last_unread_seq)

    cond do
      unread_count == 0 and (first_seq || last_seq) ->
        add_error(changeset, :unread_count, "requires nil unread bounds when zero")

      is_integer(unread_count) and unread_count > 0 and (is_nil(first_seq) or is_nil(last_seq)) ->
        add_error(changeset, :unread_count, "requires unread bounds when nonzero")

      is_integer(first_seq) and is_integer(last_seq) and first_seq > last_seq ->
        add_error(changeset, :first_unread_seq, "must be less than or equal to last unread seq")

      true ->
        changeset
    end
  end
end

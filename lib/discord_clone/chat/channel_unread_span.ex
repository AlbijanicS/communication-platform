defmodule DiscordClone.Chat.ChannelUnreadSpan do
  @moduledoc """
  Channel-facing projection of a Conversation Unread Span.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_unread_spans" do
    field :from_seq, :integer
    field :to_seq, :integer

    belongs_to :conversation, DiscordClone.Chat.Conversation,
      foreign_key: :channel_id,
      source: :conversation_id

    belongs_to :user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(unread_span, attrs) do
    unread_span
    |> cast(attrs, [:channel_id, :user_id, :from_seq, :to_seq])
    |> validate_required([:channel_id, :user_id, :from_seq, :to_seq])
    |> validate_number(:from_seq, greater_than: 0)
    |> validate_number(:to_seq, greater_than: 0)
    |> validate_bounds()
    |> foreign_key_constraint(:channel_id, name: :conversation_unread_spans_conversation_id_fkey)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:from_seq, name: :conversation_unread_spans_positive_bounds)
    |> check_constraint(:to_seq, name: :conversation_unread_spans_ordered_bounds)
    |> exclusion_constraint(:from_seq,
      name: :conversation_unread_spans_no_overlap,
      message: "overlaps an existing unread span"
    )
  end

  defp validate_bounds(changeset) do
    from_seq = get_field(changeset, :from_seq)
    to_seq = get_field(changeset, :to_seq)

    if is_integer(from_seq) and is_integer(to_seq) and from_seq > to_seq do
      add_error(changeset, :from_seq, "must be less than or equal to to seq")
    else
      changeset
    end
  end
end

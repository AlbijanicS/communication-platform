defmodule DiscordClone.Chat.MessageReaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_reactions" do
    field :emoji, :string

    belongs_to :message, DiscordClone.Chat.Message
    belongs_to :user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message_reaction, attrs) do
    message_reaction
    |> cast(attrs, [:message_id, :user_id, :emoji])
    |> validate_required([:message_id, :user_id, :emoji])
    |> validate_length(:emoji, min: 1, max: 64)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:message_id, :user_id, :emoji])
  end
end

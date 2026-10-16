defmodule DiscordClone.Workspaces.VoiceChannel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "voice_channels" do
    field :name, :string
    belongs_to :workspace, DiscordClone.Workspaces.Workspace
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(voice_channel, attrs) do
    voice_channel
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:workspace_id, :name])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message:
        "must start with a letter or number and use lowercase letters, numbers, dashes, or underscores"
    )
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:name, name: :voice_channels_workspace_id_name_index)
  end

  def rename_changeset(voice_channel, attrs) do
    voice_channel
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message:
        "must start with a letter or number and use lowercase letters, numbers, dashes, or underscores"
    )
    |> unique_constraint(:name, name: :voice_channels_workspace_id_name_index)
  end

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "-")
  end

  defp normalize_name(name), do: name
end

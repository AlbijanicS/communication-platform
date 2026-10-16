defmodule DiscordCloneWeb.UserSettingsInputs do
  @moduledoc false

  # Only normalize transport shape; Accounts owns field validation.
  def parse(%{"user" => attrs}, field) when is_map(attrs) do
    fields = if field == "password", do: [field, "password_confirmation"], else: [field]
    values = Map.take(attrs, fields)

    if is_binary(Map.get(values, field)) and
         Enum.all?(values, fn {_key, value} -> is_binary(value) end) do
      {:ok, values}
    else
      :error
    end
  end

  def parse(_params, _field), do: :error
end

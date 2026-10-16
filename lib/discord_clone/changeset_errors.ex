defmodule DiscordClone.ChangesetErrors do
  @moduledoc false

  @spec format(Ecto.Changeset.t()) :: String.t()
  def format(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, " and ")}"
    end)
  end

  defp interpolate({message, options}) do
    Enum.reduce(options, message, fn {key, value}, formatted_message ->
      String.replace(formatted_message, "%{#{key}}", to_string(value))
    end)
  end
end

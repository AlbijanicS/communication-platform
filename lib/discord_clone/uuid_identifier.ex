defmodule DiscordClone.UUIDIdentifier do
  @moduledoc false

  def cast(value) do
    case Ecto.UUID.cast(value) do
      {:ok, identifier} -> {:ok, identifier}
      :error -> :error
    end
  end

  @doc """
  Casts `value` as a UUID and runs `fun` with the cast identifier(s), returning
  whatever `fun` returns. If `value` is not a valid UUID (or, when a list is
  given, if any element is invalid), returns `fallback` instead and never calls
  `fun`.

  This collapses the recurring "cast this identifier; on a bad identifier fall
  back to a fixed not-found/empty/false result, otherwise run the query" wrapper
  used by the defensive getters across the contexts and runtime.
  """
  def cast_or(values, fallback, fun) when is_list(values) and is_function(fun, 1) do
    case cast_all(values) do
      {:ok, identifiers} -> fun.(identifiers)
      :error -> fallback
    end
  end

  def cast_or(value, fallback, fun) when is_function(fun, 1) do
    case cast(value) do
      {:ok, identifier} -> fun.(identifier)
      :error -> fallback
    end
  end

  def cast_all(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, identifiers} ->
      case cast(value) do
        {:ok, identifier} -> {:cont, {:ok, [identifier | identifiers]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, identifiers} -> {:ok, Enum.reverse(identifiers)}
      :error -> :error
    end
  end
end

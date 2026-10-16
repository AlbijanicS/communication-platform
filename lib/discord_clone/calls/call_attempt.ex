defmodule DiscordClone.Calls.CallAttempt do
  @moduledoc """
  Durable operational state for one Direct Call attempt.

  This record is not user-facing call history. It stores only the stable facts
  needed to recover invitation state and future missed-call materialization.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, read_after_writes: true}
  @foreign_key_type :binary_id

  @media_intents [:audio, :video]
  @states [:ringing, :connecting, :active, :terminal]
  @terminal_outcomes [
    :declined,
    :cancelled,
    :timed_out,
    :relationship_ended,
    :failed_capacity,
    :failed,
    :interrupted,
    :ended
  ]

  @type media_intent :: :audio | :video
  @type state :: :ringing | :connecting | :active | :terminal
  @type terminal_outcome ::
          :declined
          | :cancelled
          | :timed_out
          | :relationship_ended
          | :failed_capacity
          | :failed
          | :interrupted
          | :ended

  @type t :: %__MODULE__{}

  schema "call_attempts" do
    field :media_intent, Ecto.Enum, values: @media_intents
    field :state, Ecto.Enum, values: @states
    field :ringing_deadline_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :terminal_outcome, Ecto.Enum, values: @terminal_outcomes
    field :ended_at, :utc_datetime_usec

    belongs_to :direct_conversation, DiscordClone.Chat.DirectConversation
    belongs_to :caller_user, DiscordClone.Accounts.User
    belongs_to :recipient_user, DiscordClone.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(call_attempt, attrs) do
    call_attempt
    |> cast(attrs, [
      :direct_conversation_id,
      :caller_user_id,
      :recipient_user_id,
      :media_intent,
      :state,
      :ringing_deadline_at
    ])
    |> validate_required([
      :direct_conversation_id,
      :caller_user_id,
      :recipient_user_id,
      :media_intent,
      :state,
      :ringing_deadline_at
    ])
    |> foreign_key_constraint(:direct_conversation_id)
    |> foreign_key_constraint(:caller_user_id)
    |> foreign_key_constraint(:recipient_user_id)
    |> check_constraint(:caller_user_id, name: :call_attempts_distinct_participants)
    |> check_constraint(:media_intent, name: :call_attempts_valid_media_intent)
    |> check_constraint(:state, name: :call_attempts_valid_state)
    |> check_constraint(:terminal_outcome, name: :call_attempts_valid_terminal_outcome)
    |> check_constraint(:state, name: :call_attempts_lifecycle_consistent)
    |> check_constraint(:ringing_deadline_at, name: :call_attempts_timestamp_order)
    |> unique_constraint(:direct_conversation_id,
      name: :call_attempts_one_nonterminal_per_direct_conversation_index
    )
  end

  @doc false
  def accept_changeset(call_attempt, accepted_at) do
    call_attempt
    |> change(%{
      state: :connecting,
      accepted_at: accepted_at
    })
    |> validate_required([:state, :accepted_at])
    |> check_constraint(:state, name: :call_attempts_valid_state)
    |> check_constraint(:state, name: :call_attempts_lifecycle_consistent)
    |> check_constraint(:ringing_deadline_at, name: :call_attempts_timestamp_order)
  end

  @doc false
  def activate_changeset(call_attempt) do
    call_attempt
    |> change(%{state: :active})
    |> validate_required([:state, :accepted_at])
    |> check_constraint(:state, name: :call_attempts_valid_state)
    |> check_constraint(:state, name: :call_attempts_lifecycle_consistent)
    |> check_constraint(:ringing_deadline_at, name: :call_attempts_timestamp_order)
  end

  @doc false
  def fail_closed_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :failed, ended_at)
  end

  @doc false
  def failed_capacity_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :failed_capacity, ended_at)
  end

  @doc false
  # Direct `ringing -> terminal` failure with the acceptance timestamp set.
  # Used when pair reservation rejects before any connecting projection:
  # capacity (`failed_capacity`) or generic media (`failed`) outcomes must
  # carry `accepted_at` so unanswered-pair rate accounting and terminal dock
  # copy stay consistent with connecting-derived failures.
  def accept_failed_changeset(call_attempt, terminal_outcome, accepted_at, ended_at)
      when terminal_outcome in [:failed_capacity, :failed] do
    call_attempt
    |> change(%{
      state: :terminal,
      terminal_outcome: terminal_outcome,
      accepted_at: accepted_at,
      ended_at: ended_at
    })
    |> validate_required([:state, :terminal_outcome, :accepted_at, :ended_at])
    |> check_constraint(:state, name: :call_attempts_valid_state)
    |> check_constraint(:terminal_outcome, name: :call_attempts_valid_terminal_outcome)
    |> check_constraint(:state, name: :call_attempts_lifecycle_consistent)
    |> check_constraint(:ringing_deadline_at, name: :call_attempts_timestamp_order)
  end

  @doc false
  def ended_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :ended, ended_at)
  end

  @doc false
  def decline_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :declined, ended_at)
  end

  @doc false
  def cancel_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :cancelled, ended_at)
  end

  @doc false
  def timeout_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :timed_out, ended_at)
  end

  @doc false
  def relationship_ended_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :relationship_ended, ended_at)
  end

  @doc false
  def interrupted_changeset(call_attempt, ended_at) do
    terminal_changeset(call_attempt, :interrupted, ended_at)
  end

  defp terminal_changeset(call_attempt, terminal_outcome, ended_at) do
    call_attempt
    |> change(%{
      state: :terminal,
      terminal_outcome: terminal_outcome,
      ended_at: ended_at
    })
    |> validate_required([:state, :terminal_outcome, :ended_at])
    |> check_constraint(:state, name: :call_attempts_valid_state)
    |> check_constraint(:terminal_outcome, name: :call_attempts_valid_terminal_outcome)
    |> check_constraint(:state, name: :call_attempts_lifecycle_consistent)
    |> check_constraint(:ringing_deadline_at, name: :call_attempts_timestamp_order)
  end

  def media_intents, do: @media_intents
  def states, do: @states
  def terminal_outcomes, do: @terminal_outcomes
end

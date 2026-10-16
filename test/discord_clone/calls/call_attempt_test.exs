defmodule DiscordClone.Calls.CallAttemptTest do
  use DiscordClone.DataCase, async: true

  import DiscordClone.CallsFixtures

  alias DiscordClone.Calls.CallAttempt
  alias DiscordClone.Repo

  test "accepts ringing into connecting with accepted_at set once" do
    ringing = insert_ringing_attempt("attempt_accept")
    accepted_at = DateTime.add(ringing.inserted_at, 1, :second)

    assert {:ok, connecting} =
             ringing
             |> CallAttempt.accept_changeset(accepted_at)
             |> Repo.update()

    assert connecting.state == :connecting
    assert connecting.accepted_at == accepted_at
    assert connecting.media_intent == :audio
    assert is_nil(connecting.terminal_outcome)
    assert is_nil(connecting.ended_at)
    assert connecting.caller_user_id == ringing.caller_user_id
    assert connecting.recipient_user_id == ringing.recipient_user_id
  end

  test "activates connecting without rewriting accepted_at" do
    ringing = insert_ringing_attempt("attempt_active")
    accepted_at = DateTime.add(ringing.inserted_at, 1, :second)

    {:ok, connecting} =
      ringing
      |> CallAttempt.accept_changeset(accepted_at)
      |> Repo.update()

    changeset = CallAttempt.activate_changeset(connecting)
    refute Ecto.Changeset.changed?(changeset, :accepted_at)

    assert {:ok, active} = Repo.update(changeset)
    assert active.state == :active
    assert active.accepted_at == accepted_at
    assert is_nil(active.terminal_outcome)
    assert is_nil(active.ended_at)
  end

  test "fails connecting as failed_capacity or failed without missed-call fields" do
    ringing = insert_ringing_attempt("attempt_fail_cap")
    accepted_at = DateTime.add(ringing.inserted_at, 1, :second)
    ended_at = DateTime.add(accepted_at, 1, :second)

    {:ok, connecting} =
      ringing
      |> CallAttempt.accept_changeset(accepted_at)
      |> Repo.update()

    assert {:ok, capacity} =
             connecting
             |> CallAttempt.failed_capacity_changeset(ended_at)
             |> Repo.update()

    assert capacity.state == :terminal
    assert capacity.terminal_outcome == :failed_capacity
    assert capacity.ended_at == ended_at
    assert capacity.accepted_at == accepted_at

    failed_ringing = insert_ringing_attempt("attempt_fail_gen")
    accepted_at = DateTime.add(failed_ringing.inserted_at, 1, :second)
    ended_at = DateTime.add(accepted_at, 1, :second)

    {:ok, failed_connecting} =
      failed_ringing
      |> CallAttempt.accept_changeset(accepted_at)
      |> Repo.update()

    assert {:ok, failed} =
             failed_connecting
             |> CallAttempt.fail_closed_changeset(ended_at)
             |> Repo.update()

    assert failed.state == :terminal
    assert failed.terminal_outcome == :failed
    assert failed.ended_at == ended_at
  end

  test "leaves connecting as cancelled and active as ended" do
    ringing = insert_ringing_attempt("attempt_leave_conn")
    accepted_at = DateTime.add(ringing.inserted_at, 1, :second)
    ended_at = DateTime.add(accepted_at, 1, :second)

    {:ok, connecting} =
      ringing
      |> CallAttempt.accept_changeset(accepted_at)
      |> Repo.update()

    assert {:ok, cancelled} =
             connecting
             |> CallAttempt.cancel_changeset(ended_at)
             |> Repo.update()

    assert cancelled.state == :terminal
    assert cancelled.terminal_outcome == :cancelled
    assert cancelled.ended_at == ended_at
    assert cancelled.accepted_at == accepted_at

    active_ringing = insert_ringing_attempt("attempt_leave_act")
    accepted_at = DateTime.add(active_ringing.inserted_at, 1, :second)
    ended_at = DateTime.add(accepted_at, 1, :second)

    {:ok, connecting_active} =
      active_ringing
      |> CallAttempt.accept_changeset(accepted_at)
      |> Repo.update()

    {:ok, active} =
      connecting_active
      |> CallAttempt.activate_changeset()
      |> Repo.update()

    assert {:ok, ended} =
             active
             |> CallAttempt.ended_changeset(ended_at)
             |> Repo.update()

    assert ended.state == :terminal
    assert ended.terminal_outcome == :ended
    assert ended.ended_at == ended_at
    assert ended.accepted_at == accepted_at
  end

  test "rejects an accept changeset that would violate lifecycle consistency" do
    ringing = insert_ringing_attempt("attempt_accept_bad")

    assert {:error, changeset} =
             ringing
             |> CallAttempt.accept_changeset(nil)
             |> Repo.update()

    assert %{accepted_at: ["can't be blank"]} = errors_on(changeset)
    assert Repo.get!(CallAttempt, ringing.id).state == :ringing
  end

  defp insert_ringing_attempt(suffix) do
    {caller_scope, recipient_scope, direct_conversation, _friendship} =
      direct_conversation_fixture(suffix)

    started_at = DateTime.utc_now(:microsecond)

    {:ok, attempt} =
      %CallAttempt{}
      |> CallAttempt.create_changeset(%{
        direct_conversation_id: direct_conversation.id,
        caller_user_id: caller_scope.user.id,
        recipient_user_id: recipient_scope.user.id,
        media_intent: :audio,
        state: :ringing,
        ringing_deadline_at: DateTime.add(started_at, 30, :second)
      })
      |> Ecto.Changeset.put_change(:inserted_at, started_at)
      |> Ecto.Changeset.put_change(:updated_at, started_at)
      |> Repo.insert()

    attempt
  end
end

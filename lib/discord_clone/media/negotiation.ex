defmodule DiscordClone.Media.Negotiation do
  @moduledoc """
  Bounded offer/ICE state owned and serialized by one Session. Channels validate
  SDP/ICE envelopes before entry; the Session owns authentication and lifetime.
  No process, timer, media policy or packet handling lives here.

  Before the sole offer, candidates may have interleaved negotiation IDs. Only
  the accepted offer's candidates are applied, in arrival order. A new Session
  starts with new state; callers must never copy this state to a replacement.
  """

  @offer_reply_timeout_ms 10_000
  @max_pending_candidates 16
  @max_pending_candidate_bytes 128 * 1024
  @max_accepted_candidates 64

  defstruct negotiation_id: nil,
            pending_candidates: [],
            accepted_candidate_count: 0,
            closed?: false

  @type t :: %__MODULE__{
          negotiation_id: binary() | nil,
          pending_candidates: [map()],
          accepted_candidate_count: non_neg_integer(),
          closed?: boolean()
        }

  @doc "The supplied command deadline can shorten, but never extend, the offer budget."
  def accept_offer(state, peer, negotiation_id, description, deadline) do
    cond do
      state.closed? ->
        {:error, :invalid_session, state}

      state.negotiation_id != nil ->
        {:error, :negotiation_already_active, state}

      true ->
        negotiate(state, peer, negotiation_id, description, offer_deadline(deadline))
    end
  end

  defp negotiate(state, peer, negotiation_id, description, deadline) do
    case peer.__struct__.accept_offer_until(peer, description, deadline) do
      {:ok, answer, peer} ->
        accepted_count =
          state.pending_candidates
          |> Enum.filter(&(&1.negotiation_id == negotiation_id))
          |> Enum.reverse()
          |> Enum.count(&(apply_candidate(peer, &1.candidate, deadline) == :ok))

        {:ok, answer, peer,
         %{
           state
           | negotiation_id: negotiation_id,
             pending_candidates: [],
             accepted_candidate_count: accepted_count
         }}

      {:error, reason} ->
        {:error, reason, stop(state, peer)}
    end
  catch
    :exit, _reason -> {:error, :negotiation_failed, stop(state, peer)}
  end

  def add_ice_candidate(state, peer, negotiation_id, candidate, deadline) do
    cond do
      state.closed? ->
        {:error, :invalid_session}

      candidate.negotiation_id != negotiation_id ->
        {:error, :invalid_negotiation}

      state.negotiation_id == nil ->
        queue_candidate(state, candidate)

      state.negotiation_id != negotiation_id ->
        {:error, :invalid_negotiation}

      state.accepted_candidate_count >= @max_accepted_candidates ->
        {:error, :candidate_limit_reached}

      true ->
        with :ok <- apply_candidate(peer, candidate.candidate, deadline) do
          {:ok, %{state | accepted_candidate_count: state.accepted_candidate_count + 1}}
        end
    end
  end

  def end_of_candidates(state, negotiation_id) do
    if not state.closed? and state.negotiation_id == negotiation_id,
      do: {:error, :end_of_candidates_unsupported},
      else: {:error, :invalid_negotiation}
  end

  @doc "Release the exact connection and buffered work; repeated release is harmless."
  def stop(state, peer) do
    :ok = peer.__struct__.stop(peer)
    %{state | closed?: true, pending_candidates: [], accepted_candidate_count: 0}
  end

  defp queue_candidate(state, candidate) do
    pending = state.pending_candidates
    byte_count = Enum.sum(Enum.map(pending, & &1.byte_count)) + candidate.byte_count

    if length(pending) < @max_pending_candidates and byte_count <= @max_pending_candidate_bytes do
      {:ok, %{state | pending_candidates: [candidate | pending]}}
    else
      {:error, :pending_candidate_limit_reached}
    end
  end

  defp apply_candidate(peer, candidate, deadline) do
    peer.__struct__.add_ice_candidate_until(peer, candidate, deadline)
  catch
    :exit, _reason -> {:error, :candidate_rejected}
  end

  defp offer_deadline(deadline) do
    maximum = System.monotonic_time(:millisecond) + @offer_reply_timeout_ms
    if deadline == :infinity, do: maximum, else: min(deadline, maximum)
  end
end

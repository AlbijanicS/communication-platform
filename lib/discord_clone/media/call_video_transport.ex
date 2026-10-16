defmodule DiscordClone.Media.CallVideoTransport do
  @moduledoc """
  Read-only compatibility boundary for ExWebRTC 0.17.0 / ExICE 0.16.1.

  Public ICE sent counters include TURN permission-buffered packets, and public
  candidate IDs cannot be joined to pairs. After the two ordered stats barriers,
  inspect native relay storage before returning a video frame credit. The OTP
  system request is asynchronous; it neither changes ICE state nor blocks the
  owning Session. Only an outstanding credit can request another observation.
  Buffered ICE binding checks are independent of video delivery; all other
  buffered datagrams retain the credit until sent or irrevocably discarded.
  No state, candidate, credential or packet is logged or projected to clients.
  """

  def ice_pid(peer) do
    %{ice_pid: ice} = :sys.get_state(peer)
    ice
  end

  def request(ice) do
    reference = :erlang.alias([:reply])
    send(ice, {:system, {reference, reference}, :get_state})
    reference
  end

  def completion({:ok, %{ice_agent: %{local_cands: candidates}}}) when map_size(candidates) > 0 do
    consumed? =
      Enum.all?(candidates, fn
        # ExICE retains closed candidates/storage but ignores their TURN input;
        # their buffered work is irrevocably discarded, never pending delivery.
        {_, %ExICE.Priv.Candidate.Relay{base: %{closed?: true}}} ->
          true

        {_, %ExICE.Priv.Candidate.Relay{buffered_packets: packets}} when is_list(packets) ->
          Enum.all?(packets, &connectivity_check?/1)

        {_, %ExICE.Priv.Candidate.Relay{}} ->
          false

        {_, %{base: %{type: type}}} when type in [:host, :srflx, :prflx] ->
          true

        _ ->
          false
      end)

    if consumed? do
      closed =
        for {id,
             %ExICE.Priv.Candidate.Relay{
               base: %{closed?: true},
               buffered_packets: [_ | _]
             }} <- candidates,
            do: id

      {:consumed, MapSet.new(closed)}
    else
      :pending
    end
  end

  def completion(_unknown_layout), do: :pending

  def cancel(nil), do: :ok
  def cancel(reference), do: :erlang.unalias(reference)

  # An unused relay may retain checks for private candidates after TURN denies
  # their permissions. They must not hold credit for video sent on another
  # path. Restrict the exemption to complete, decodable STUN binding messages;
  # SRTP, DTLS, TURN data envelopes and unknown bytes remain pending everywhere.
  defp connectivity_check?(
         {_, _, <<0::2, _::14, length::16, 0x2112A442::32, _::96, attributes::binary>> = packet}
       )
       when byte_size(attributes) == length and rem(length, 4) == 0 do
    match?({:ok, %{type: %{method: :binding}}}, ExSTUN.Message.decode(packet))
  end

  defp connectivity_check?(_packet), do: false
end

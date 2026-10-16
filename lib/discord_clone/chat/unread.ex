defmodule DiscordClone.Chat.Unread do
  @moduledoc """
  Read State and Unread Span workflows for the Chat context.

  `DiscordClone.Chat` remains the public facade for web callers; this module
  owns the read-state persistence, unread span mutation, send fan-out, and the
  private read-state PubSub topic behind that facade.
  """

  import Ecto.Query

  alias DiscordClone.Accounts.{Scope, User}

  alias DiscordClone.Chat.{
    ChannelReadState,
    ChannelUnreadSpan,
    ConversationTopics,
    DirectConversation,
    MessageWindow,
    Unread.Spans
  }

  alias DiscordClone.{Repo, UUIDIdentifier}
  alias DiscordClone.Workspaces.{Channel, WorkspaceMembership}

  def initialize_workspace_reads_for_user(user_id, workspace_id) do
    with :ok <- authorize_workspace_member(workspace_id, user_id) do
      read_rows =
        Repo.all(
          from channel in Channel,
            where: channel.workspace_id == ^workspace_id,
            select: %{
              channel_id: channel.id
            }
        )

      insert_zero_unread_read_states(read_rows, fn %{channel_id: channel_id} ->
        {channel_id, user_id}
      end)

      :ok
    end
  end

  def initialize_channel_reads_for_workspace_members(channel_id) do
    with {:ok, channel_id} <- UUIDIdentifier.cast(channel_id),
         true <- Repo.exists?(from channel in Channel, where: channel.id == ^channel_id) do
      now = DateTime.utc_now(:microsecond)

      read_rows =
        Repo.all(
          from channel in Channel,
            join: membership in WorkspaceMembership,
            on: membership.workspace_id == channel.workspace_id,
            where: channel.id == ^channel_id,
            select: %{
              channel_id: channel.id,
              user_id: membership.user_id,
              inserted_at: type(^now, :utc_datetime_usec),
              updated_at: type(^now, :utc_datetime_usec)
            }
        )

      insert_zero_unread_read_states(read_rows, fn %{channel_id: channel_id, user_id: user_id} ->
        {channel_id, user_id}
      end)

      :ok
    else
      _not_found -> {:error, :not_found}
    end
  end

  def delete_workspace_reads_for_user(user_id, workspace_id) do
    UUIDIdentifier.cast_or([user_id, workspace_id], :ok, fn [user_id, workspace_id] ->
      Repo.delete_all(
        from span in ChannelUnreadSpan,
          join: channel in Channel,
          on: channel.id == span.channel_id,
          where: channel.workspace_id == ^workspace_id,
          where: span.user_id == ^user_id
      )

      Repo.delete_all(
        from read_state in ChannelReadState,
          join: channel in Channel,
          on: channel.id == read_state.channel_id,
          where: channel.workspace_id == ^workspace_id,
          where: read_state.user_id == ^user_id
      )

      :ok
    end)
  end

  def list_unread_counts(%Scope{user: %User{id: user_id}}, workspace_id) do
    with {:ok, summaries} <-
           list_channel_read_summaries(%Scope{user: %User{id: user_id}}, workspace_id) do
      unread_counts =
        summaries
        |> Enum.filter(&(&1.unread_count > 0))
        |> Map.new(fn summary -> {summary.channel_id, summary.unread_count} end)

      {:ok, unread_counts}
    end
  end

  def list_unread_counts(_scope, _workspace_id), do: {:error, :unauthenticated}

  def list_channel_read_summaries(%Scope{user: %User{id: user_id}}, workspace_id) do
    with :ok <- authorize_workspace_member(workspace_id, user_id) do
      summaries =
        Repo.all(
          from read_state in ChannelReadState,
            join: channel in Channel,
            on: channel.id == read_state.channel_id,
            where: channel.workspace_id == ^workspace_id,
            where: read_state.user_id == ^user_id,
            order_by: [asc: channel.inserted_at, asc: channel.id],
            select: %{
              workspace_id: channel.workspace_id,
              channel_id: read_state.channel_id,
              unread_count: read_state.unread_count,
              first_unread_seq: read_state.first_unread_seq,
              last_unread_seq: read_state.last_unread_seq
            }
        )

      {:ok, summaries}
    end
  end

  def list_channel_read_summaries(_scope, _workspace_id), do: {:error, :unauthenticated}

  def jump_to_oldest_unread(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         {:ok, _read_state} <- ensure_channel_read_state!(user_id, channel_id),
         read_state = Repo.get_by!(ChannelReadState, channel_id: channel_id, user_id: user_id),
         true <- read_state.unread_count > 0 do
      first_unread_seq = read_state.first_unread_seq
      {:ok, MessageWindow.load_around_channel(channel, first_unread_seq)}
    else
      nil -> {:error, :not_found}
      false -> {:error, :no_unread_messages}
    end
  end

  def jump_to_oldest_unread(_scope, _channel_id), do: {:error, :unauthenticated}

  def mark_channel_read(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      with {:ok, _read_state} <-
             mutate_channel_unread_spans(user_id, channel, fn _spans -> [] end) do
        :ok
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def mark_channel_read(_scope, _channel_id), do: {:error, :unauthenticated}

  def add_channel_unread_range(%Scope{user: %User{id: user_id}}, channel_id, from_seq, to_seq) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         :ok <- validate_unread_range(from_seq, to_seq) do
      mutate_channel_unread_spans(user_id, channel, fn spans ->
        Spans.merge([{from_seq, to_seq} | spans])
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def add_channel_unread_range(_scope, _channel_id, _from_seq, _to_seq),
    do: {:error, :unauthenticated}

  def subtract_visible_read_range(%Scope{user: %User{id: user_id}}, channel_id, from_seq, to_seq) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         :ok <- validate_visible_read_range(channel, from_seq, to_seq) do
      mutate_channel_unread_spans(user_id, channel, fn spans ->
        Spans.subtract(spans, from_seq, to_seq)
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def subtract_visible_read_range(_scope, _channel_id, _from_seq, _to_seq),
    do: {:error, :unauthenticated}

  def subscribe_to_channel_read_state(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      topic = ConversationTopics.read_state(user_id, channel_id)

      if topic in Registry.keys(DiscordClone.PubSub, self()) do
        :ok
      else
        Phoenix.PubSub.subscribe(DiscordClone.PubSub, topic)
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_to_channel_read_state(_scope, _channel_id), do: {:error, :unauthenticated}

  def fanout_on_send!(%Channel{} = channel, sender_user_id, message_seq) do
    channel
    |> list_channel_recipient_user_ids(sender_user_id)
    |> Enum.reduce([], fn recipient_user_id, read_state_changes ->
      ensure_channel_read_state!(recipient_user_id, channel.id)
      read_state = lock_channel_read_state!(recipient_user_id, channel.id)

      current_spans = list_channel_unread_span_bounds(recipient_user_id, channel.id)
      next_spans = Spans.merge([{message_seq, message_seq} | current_spans])

      if current_spans == next_spans do
        read_state_changes
      else
        replace_channel_unread_spans!(recipient_user_id, channel.id, next_spans)
        read_state = update_read_state_summary!(read_state, next_spans)

        [
          {:workspace_channel, channel.workspace_id, recipient_user_id, read_state}
          | read_state_changes
        ]
      end
    end)
    |> Enum.reverse()
  end

  def fanout_on_direct_send!(
        %DirectConversation{} = direct_conversation,
        sender_user_id,
        message_seq
      ) do
    recipient_user_id = DirectConversation.other_user_id(direct_conversation, sender_user_id)

    read_state = add_unread_message!(recipient_user_id, direct_conversation.id, message_seq)
    [{:direct_conversation, recipient_user_id, read_state}]
  end

  def broadcast_changes(read_state_changes) do
    Enum.each(read_state_changes, fn
      {:workspace_channel, workspace_id, user_id, read_state} ->
        :ok = broadcast_channel_read_state_changed(workspace_id, user_id, read_state)

      {:direct_conversation, user_id, read_state} ->
        :ok = broadcast_direct_read_state_changed(user_id, read_state)
    end)

    :ok
  end

  @doc false
  def lock_direct_read_state_and_spans!(user_id, conversation_id) do
    ensure_channel_read_state!(user_id, conversation_id)
    read_state = lock_channel_read_state!(user_id, conversation_id)

    spans =
      Repo.all(
        from span in ChannelUnreadSpan,
          where: span.channel_id == ^conversation_id and span.user_id == ^user_id,
          order_by: [asc: span.from_seq, asc: span.id],
          lock: "FOR UPDATE",
          select: {span.from_seq, span.to_seq}
      )

    {read_state, spans}
  end

  @doc false
  def apply_locked_visible_range!(read_state, spans, from_seq, to_seq) do
    next_spans = Spans.subtract(spans, from_seq, to_seq)

    if next_spans == spans do
      {read_state, false}
    else
      replace_channel_unread_spans!(read_state.user_id, read_state.channel_id, next_spans)
      {update_read_state_summary!(read_state, next_spans), true}
    end
  end

  defp add_unread_message!(recipient_user_id, conversation_id, message_seq) do
    ensure_channel_read_state!(recipient_user_id, conversation_id)
    read_state = lock_channel_read_state!(recipient_user_id, conversation_id)
    current_spans = list_channel_unread_span_bounds(recipient_user_id, conversation_id)
    next_spans = Spans.merge([{message_seq, message_seq} | current_spans])

    replace_channel_unread_spans!(recipient_user_id, conversation_id, next_spans)
    update_read_state_summary!(read_state, next_spans)
  end

  def ensure_channel_read_state!(user_id, channel_id) do
    %ChannelReadState{}
    |> ChannelReadState.changeset(%{
      channel_id: channel_id,
      user_id: user_id,
      unread_count: 0
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:channel_id, :user_id]
    )
  end

  def lock_channel_read_state!(user_id, channel_id) do
    Repo.one!(
      from read_state in ChannelReadState,
        where: read_state.channel_id == ^channel_id and read_state.user_id == ^user_id,
        lock: "FOR UPDATE"
    )
  end

  def get_channel_read_state!(user_id, channel_id) do
    Repo.get_by!(ChannelReadState, channel_id: channel_id, user_id: user_id)
  end

  def change_read_state(%ChannelReadState{} = read_state, attrs) do
    ChannelReadState.changeset(read_state, attrs)
  end

  defp get_member_channel(channel_id, user_id) do
    UUIDIdentifier.cast_or(channel_id, nil, fn channel_id ->
      Repo.one(
        from channel in Channel,
          join: membership in WorkspaceMembership,
          on: membership.workspace_id == channel.workspace_id,
          where: channel.id == ^channel_id and membership.user_id == ^user_id,
          preload: [:conversation]
      )
    end)
  end

  defp authorize_workspace_member(workspace_id, user_id) do
    UUIDIdentifier.cast_or(workspace_id, {:error, :not_found}, fn workspace_id ->
      if Repo.exists?(
           from membership in WorkspaceMembership,
             where: membership.workspace_id == ^workspace_id and membership.user_id == ^user_id
         ) do
        :ok
      else
        {:error, :not_found}
      end
    end)
  end

  defp list_channel_recipient_user_ids(%Channel{workspace_id: workspace_id}, sender_user_id) do
    Repo.all(
      from membership in WorkspaceMembership,
        where: membership.workspace_id == ^workspace_id and membership.user_id != ^sender_user_id,
        order_by: [asc: membership.user_id],
        select: membership.user_id
    )
  end

  defp mutate_channel_unread_spans(user_id, %Channel{} = channel, fun) do
    Repo.transaction(fn ->
      channel_id = channel.id
      ensure_channel_read_state!(user_id, channel_id)
      read_state = lock_channel_read_state!(user_id, channel_id)

      current_spans = list_channel_unread_span_bounds(user_id, channel_id)
      next_spans = fun.(current_spans)
      changed? = current_spans != next_spans

      read_state =
        if changed? do
          replace_channel_unread_spans!(user_id, channel_id, next_spans)
          update_read_state_summary!(read_state, next_spans)
        else
          read_state
        end

      {read_state, changed?}
    end)
    |> case do
      {:ok, {read_state, true}} ->
        :ok = broadcast_channel_read_state_changed(channel.workspace_id, user_id, read_state)
        {:ok, read_state}

      {:ok, {read_state, false}} ->
        {:ok, read_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Single zero-unread Read State insertion path. `to_channel_user` maps each
  # source row to its `{channel_id, user_id}` pair — the per-invite caller closes
  # over one shared user_id, the per-member caller reads it from each row — so
  # both initialization flows share one code path and on-conflict behavior.
  defp insert_zero_unread_read_states(rows, to_channel_user) do
    now = DateTime.utc_now(:microsecond)

    read_state_rows =
      Enum.map(rows, fn row ->
        {channel_id, user_id} = to_channel_user.(row)

        %{
          channel_id: channel_id,
          user_id: user_id,
          unread_count: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(
      ChannelReadState,
      read_state_rows,
      on_conflict: :nothing,
      conflict_target: [:channel_id, :user_id]
    )
  end

  defp list_channel_unread_span_bounds(user_id, channel_id) do
    Repo.all(
      from span in ChannelUnreadSpan,
        where: span.channel_id == ^channel_id and span.user_id == ^user_id,
        order_by: [asc: span.from_seq],
        select: {span.from_seq, span.to_seq}
    )
  end

  defp replace_channel_unread_spans!(user_id, channel_id, spans) do
    Repo.delete_all(
      from span in ChannelUnreadSpan,
        where: span.channel_id == ^channel_id and span.user_id == ^user_id
    )

    Enum.each(spans, fn {from_seq, to_seq} ->
      Repo.insert!(
        ChannelUnreadSpan.changeset(%ChannelUnreadSpan{}, %{
          channel_id: channel_id,
          user_id: user_id,
          from_seq: from_seq,
          to_seq: to_seq
        })
      )
    end)
  end

  defp update_read_state_summary!(read_state, spans) do
    attrs = unread_summary_attrs(spans)

    read_state
    |> ChannelReadState.changeset(attrs)
    |> Repo.update!()
  end

  defp unread_summary_attrs([]) do
    %{unread_count: 0, first_unread_seq: nil, last_unread_seq: nil}
  end

  defp unread_summary_attrs(spans) do
    {first_seq, _first_to_seq} = List.first(spans)
    {_last_from_seq, last_seq} = List.last(spans)

    unread_count =
      Enum.reduce(spans, 0, fn {from_seq, to_seq}, count ->
        count + to_seq - from_seq + 1
      end)

    %{
      unread_count: unread_count,
      first_unread_seq: first_seq,
      last_unread_seq: last_seq
    }
  end

  defp validate_visible_read_range(channel, from_seq, to_seq)
       when is_integer(from_seq) and is_integer(to_seq) do
    cond do
      from_seq < 1 ->
        {:error, :invalid_range}

      from_seq > to_seq ->
        {:error, :invalid_range}

      to_seq - from_seq + 1 > 50 ->
        {:error, :range_too_large}

      to_seq > channel.conversation.last_message_seq ->
        {:error, :invalid_range}

      true ->
        :ok
    end
  end

  defp validate_visible_read_range(_channel, _from_seq, _to_seq), do: {:error, :invalid_range}

  defp validate_unread_range(from_seq, to_seq) when is_integer(from_seq) and is_integer(to_seq) do
    if from_seq >= 1 and from_seq <= to_seq do
      :ok
    else
      {:error, :invalid_range}
    end
  end

  defp validate_unread_range(_from_seq, _to_seq), do: {:error, :invalid_range}

  defp broadcast_channel_read_state_changed(
         workspace_id,
         user_id,
         %ChannelReadState{} = read_state
       ) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      ConversationTopics.read_state(user_id, read_state.channel_id),
      {:channel_read_state_changed,
       %{
         workspace_id: workspace_id,
         channel_id: read_state.channel_id,
         unread_count: read_state.unread_count,
         first_unread_seq: read_state.first_unread_seq,
         last_unread_seq: read_state.last_unread_seq
       }}
    )
  end

  defp broadcast_direct_read_state_changed(user_id, %ChannelReadState{} = read_state) do
    :ok =
      Phoenix.PubSub.broadcast(
        DiscordClone.PubSub,
        ConversationTopics.read_state(user_id, read_state.channel_id),
        {:conversation_read_state_changed,
         %{
           conversation_id: read_state.channel_id,
           unread_count: read_state.unread_count,
           first_unread_seq: read_state.first_unread_seq,
           last_unread_seq: read_state.last_unread_seq
         }}
      )

    ConversationTopics.broadcast_direct_navigation_change(user_id, %{
      action: :read_state_changed,
      conversation_id: read_state.channel_id
    })
  end
end

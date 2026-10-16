defmodule DiscordClone.Chat do
  @moduledoc """
  The Chat context.

  This context will own persisted message workflows, PubSub orchestration, and
  live channel processes as the chat phases are built.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias DiscordClone.Accounts.{Scope, User}
  alias DiscordClone.Activities
  alias DiscordClone.Activities.{ActivityItem, Topics}

  alias DiscordClone.Chat.{
    ChannelReadState,
    Conversation,
    ConversationTopics,
    DirectConversation,
    Emoji,
    Message,
    MentionParser,
    MessageReaction,
    MessageWindow,
    Runtime,
    Unread
  }

  alias DiscordClone.{Friendships, Repo, UUIDIdentifier, Workspaces}

  alias DiscordClone.Workspaces.{
    Channel,
    Roles,
    WorkspaceAuditEvent,
    WorkspaceMembership,
    WorkspaceModeration
  }

  @recent_message_limit 100
  @message_page_size 50
  @activity_feed_page_size 50
  @small_unread_landing_limit 50
  @large_unread_landing_backtrack div(@message_page_size, 2) - 5

  @type reason :: atom()
  @type window_result :: {:ok, map()} | {:error, reason()}
  @type activity_feed_cursor :: %{inserted_at: DateTime.t(), id: Ecto.UUID.t()}

  @doc "Subscribes the scoped user to private Activity change facts."
  @spec subscribe_to_activity(term()) :: :ok | {:error, :unauthenticated}
  defdelegate subscribe_to_activity(scope), to: Activities, as: :subscribe

  def change_message(attrs \\ %{}) do
    Message.changeset(%Message{}, attrs)
  end

  @doc "Lists the scoped User's Direct Conversation destinations by recent activity."
  @spec list_direct_conversation_destinations(term()) ::
          {:ok,
           [
             %{
               direct_conversation: DirectConversation.t(),
               other_participant: User.t(),
               latest_message_at: DateTime.t() | nil,
               unread_count: non_neg_integer(),
               writable?: boolean()
             }
           ]}
          | {:error, :unauthenticated}
  def list_direct_conversation_destinations(%Scope{user: %User{id: user_id}} = scope) do
    {:ok, friends} = Friendships.list_friends(scope)
    friend_user_ids = MapSet.new(friends, & &1.user.id)

    latest_messages =
      from message in Message,
        group_by: message.channel_id,
        select: %{
          conversation_id: message.channel_id,
          latest_message_at: max(message.inserted_at)
        }

    destinations =
      Repo.all(
        from direct_conversation in DirectConversation,
          join: conversation in Conversation,
          on: conversation.id == direct_conversation.id,
          join: user_low in User,
          on: user_low.id == direct_conversation.user_low_id,
          join: user_high in User,
          on: user_high.id == direct_conversation.user_high_id,
          left_join: latest_message in subquery(latest_messages),
          on: latest_message.conversation_id == direct_conversation.id,
          left_join: read_state in ChannelReadState,
          on:
            read_state.channel_id == direct_conversation.id and
              read_state.user_id == ^user_id,
          where:
            direct_conversation.user_low_id == ^user_id or
              direct_conversation.user_high_id == ^user_id,
          order_by: [
            desc:
              fragment(
                "COALESCE(?, ?)",
                latest_message.latest_message_at,
                conversation.inserted_at
              ),
            asc: direct_conversation.id
          ],
          select:
            {direct_conversation, conversation, user_low, user_high,
             latest_message.latest_message_at, read_state.unread_count}
      )
      |> Enum.map(fn
        {direct_conversation, conversation, user_low, user_high, latest_message_at, unread_count} ->
          direct_conversation = %{
            direct_conversation
            | conversation: conversation,
              user_low: user_low,
              user_high: user_high
          }

          other_participant = DirectConversation.other_user(direct_conversation, user_id)

          %{
            direct_conversation: direct_conversation,
            other_participant: other_participant,
            latest_message_at: latest_message_at,
            unread_count: unread_count || 0,
            writable?: MapSet.member?(friend_user_ids, other_participant.id)
          }
      end)

    {:ok, destinations}
  end

  def list_direct_conversation_destinations(_scope), do: {:error, :unauthenticated}

  @doc "Subscribes the scoped User to Direct Messages navigation changes."
  @spec subscribe_to_direct_navigation(term()) :: :ok | {:error, :unauthenticated}
  def subscribe_to_direct_navigation(%Scope{user: %User{id: user_id}}) do
    Phoenix.PubSub.subscribe(
      DiscordClone.PubSub,
      ConversationTopics.direct_navigation(user_id)
    )
  end

  def subscribe_to_direct_navigation(_scope), do: {:error, :unauthenticated}

  @doc """
  Finds or lazily creates the scoped User's Direct Conversation with another User.

  An existing Conversation remains accessible after Friendship removal. Only
  first creation requires an accepted Friendship.
  """
  @spec open_direct_conversation(term(), term()) ::
          {:ok, DirectConversation.t()}
          | {:error, :unauthenticated | :invalid_participant | :not_found | :not_friends}
  def open_direct_conversation(%Scope{user: %User{id: user_id}} = scope, friend_user_id) do
    with {:ok, friend_user_id} <- Ecto.UUID.cast(friend_user_id),
         :ok <- reject_same_direct_participant(user_id, friend_user_id),
         %User{} <- Repo.get(User, friend_user_id) do
      pair = canonical_user_pair(user_id, friend_user_id)

      case direct_conversation_for_pair(pair) do
        %DirectConversation{} = direct_conversation ->
          {:ok, preload_direct_conversation(direct_conversation)}

        nil ->
          create_direct_conversation_for_friends(scope, pair)
      end
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def open_direct_conversation(_scope, _friend_user_id), do: {:error, :unauthenticated}

  @doc "Finds the scoped User's existing Direct Conversation with another participant."
  @spec find_direct_conversation(term(), term()) ::
          {:ok, DirectConversation.t()}
          | {:error, :unauthenticated | :invalid_participant | :not_found}
  def find_direct_conversation(%Scope{user: %User{id: user_id}}, other_user_id) do
    with {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         :ok <- reject_same_direct_participant(user_id, other_user_id),
         %DirectConversation{} = direct_conversation <-
           direct_conversation_for_pair(canonical_user_pair(user_id, other_user_id)) do
      {:ok, preload_direct_conversation(direct_conversation)}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def find_direct_conversation(_scope, _other_user_id), do: {:error, :unauthenticated}

  @doc "Returns a Direct Conversation destination only when the scoped User participates."
  @spec get_direct_conversation(term(), term()) ::
          {:ok, %{direct_conversation: DirectConversation.t(), other_participant: User.t()}}
          | {:error, :unauthenticated | :not_found}
  def get_direct_conversation(%Scope{user: %User{id: user_id}}, direct_conversation_id) do
    with {:ok, direct_conversation_id} <- Ecto.UUID.cast(direct_conversation_id),
         %DirectConversation{} = direct_conversation <-
           Repo.one(
             from direct_conversation in DirectConversation,
               where:
                 direct_conversation.id == ^direct_conversation_id and
                   (direct_conversation.user_low_id == ^user_id or
                      direct_conversation.user_high_id == ^user_id)
           ) do
      direct_conversation = preload_direct_conversation(direct_conversation)

      {:ok,
       %{
         direct_conversation: direct_conversation,
         other_participant: DirectConversation.other_user(direct_conversation, user_id)
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  def get_direct_conversation(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  defp reject_same_direct_participant(user_id, user_id),
    do: {:error, :invalid_participant}

  defp reject_same_direct_participant(_user_id, _friend_user_id), do: :ok

  defp canonical_user_pair(first_user_id, second_user_id) do
    if first_user_id < second_user_id,
      do: {first_user_id, second_user_id},
      else: {second_user_id, first_user_id}
  end

  defp direct_conversation_for_pair({user_low_id, user_high_id}) do
    Repo.get_by(DirectConversation,
      user_low_id: user_low_id,
      user_high_id: user_high_id
    )
  end

  defp create_direct_conversation_for_friends(
         scope,
         {user_low_id, user_high_id} = pair
       ) do
    case Repo.transaction(fn ->
           other_user_id = if scope.user.id == user_low_id, do: user_high_id, else: user_low_id

           case Friendships.lock_accepted_friendship(scope, other_user_id) do
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end

           conversation =
             %Conversation{}
             |> Conversation.direct_conversation_changeset()
             |> Repo.insert!()

           %DirectConversation{id: conversation.id}
           |> DirectConversation.create_changeset(%{
             user_low_id: user_low_id,
             user_high_id: user_high_id
           })
           |> Repo.insert!(
             on_conflict: :nothing,
             conflict_target: [:user_low_id, :user_high_id]
           )

           direct_conversation = direct_conversation_for_pair(pair)

           if direct_conversation.id != conversation.id do
             Repo.delete!(conversation)
           end

           direct_conversation
         end) do
      {:ok, direct_conversation} ->
        :ok =
          broadcast_direct_navigation_changed(direct_conversation.user_low_id, %{
            action: :created
          })

        :ok =
          broadcast_direct_navigation_changed(direct_conversation.user_high_id, %{
            action: :created
          })

        {:ok, preload_direct_conversation(direct_conversation)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp preload_direct_conversation(direct_conversation) do
    Repo.preload(direct_conversation, [:conversation, :user_low, :user_high])
  end

  @doc "Lists the committed Direct Message timeline for one participant."
  @spec list_direct_messages(term(), term()) ::
          {:ok, [Message.t()]} | {:error, :unauthenticated | :not_found}
  def list_direct_messages(%Scope{user: %User{id: user_id}}, direct_conversation_id) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      messages =
        Message
        |> where([message], message.channel_id == ^conversation_id)
        |> order_by([message], asc: message.seq)
        |> preload(^Message.display_preloads())
        |> Repo.all()
        |> Enum.map(&redact_deleted_direct_message/1)

      {:ok, messages}
    else
      nil -> {:error, :not_found}
    end
  end

  def list_direct_messages(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Reloads one committed Direct Message through its participant boundary."
  @spec fetch_direct_message(term(), term(), term()) ::
          {:ok, Message.t()} | {:error, :unauthenticated | :not_found}
  def fetch_direct_message(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id,
        message_id
      ) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id),
         {:ok, message_id} <- Ecto.UUID.cast(message_id),
         %Message{} = message <-
           Repo.one(
             from message in Message,
               where: message.id == ^message_id and message.channel_id == ^conversation_id,
               preload: ^Message.display_preloads()
           ) do
      {:ok, redact_deleted_direct_message(message)}
    else
      _not_found -> {:error, :not_found}
    end
  end

  def fetch_direct_message(_scope, _direct_conversation_id, _message_id),
    do: {:error, :unauthenticated}

  @doc "Loads the newest bounded Message window for a Direct Conversation participant."
  @spec load_latest_direct_message_window(term(), term()) :: window_result()
  def load_latest_direct_message_window(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id
      ) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      conversation = Repo.preload(direct_conversation, :conversation).conversation
      latest_seq = conversation.last_message_seq
      from_seq = max(1, latest_seq - @message_page_size + 1)

      {:ok,
       conversation
       |> MessageWindow.load_for_conversation(from_seq, latest_seq)
       |> redact_direct_message_window()}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_latest_direct_message_window(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Loads the bounded Direct Message window immediately before a sequence."
  @spec load_older_direct_message_window(term(), term(), term()) :: window_result()
  def load_older_direct_message_window(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id,
        before_seq
      )
      when is_integer(before_seq) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      conversation = Repo.preload(direct_conversation, :conversation).conversation
      to_seq = min(conversation.last_message_seq, before_seq - 1)
      from_seq = max(1, to_seq - @message_page_size + 1)

      {:ok,
       conversation
       |> MessageWindow.load_for_conversation(from_seq, to_seq)
       |> redact_direct_message_window()}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_older_direct_message_window(%Scope{user: %User{}}, _conversation_id, _before_seq),
    do: {:error, :invalid_sequence}

  def load_older_direct_message_window(_scope, _conversation_id, _before_seq),
    do: {:error, :unauthenticated}

  @doc "Loads the bounded Direct Message window immediately after a sequence."
  @spec load_newer_direct_message_window(term(), term(), term()) :: window_result()
  def load_newer_direct_message_window(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id,
        after_seq
      )
      when is_integer(after_seq) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      conversation = Repo.preload(direct_conversation, :conversation).conversation
      from_seq = max(1, after_seq + 1)
      to_seq = min(conversation.last_message_seq, from_seq + @message_page_size - 1)

      {:ok,
       conversation
       |> MessageWindow.load_for_conversation(from_seq, to_seq)
       |> redact_direct_message_window()}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_newer_direct_message_window(%Scope{user: %User{}}, _conversation_id, _after_seq),
    do: {:error, :invalid_sequence}

  def load_newer_direct_message_window(_scope, _conversation_id, _after_seq),
    do: {:error, :unauthenticated}

  @doc "Loads a bounded Direct Message window containing an authorized live target."
  @spec navigate_to_direct_message(term(), term(), term()) :: window_result()
  def navigate_to_direct_message(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id,
        message_id
      ) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id),
         %Message{} = target <- get_live_direct_message(direct_conversation.id, message_id) do
      conversation = Repo.preload(direct_conversation, :conversation).conversation

      window =
        conversation
        |> MessageWindow.load_around_conversation(target.seq)
        |> redact_direct_message_window()

      {:ok, Map.put(window, :target, preload_message_for_display(target))}
    else
      _not_found -> {:error, :not_found}
    end
  end

  def navigate_to_direct_message(_scope, _direct_conversation_id, _message_id),
    do: {:error, :unauthenticated}

  @doc false
  def ensure_direct_conversation_runtime(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id
      ) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      Runtime.ensure_conversation(conversation_id)
    else
      nil -> {:error, :not_found}
    end
  end

  def ensure_direct_conversation_runtime(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc false
  def list_recent_direct_messages(%Scope{user: %User{id: user_id}}, direct_conversation_id) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id),
         {:ok, messages} <- Runtime.list_recent_messages(conversation_id) do
      {:ok, Enum.map(messages, &redact_deleted_direct_message/1)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_recent_direct_messages(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Lists transient typing Users for a Direct Conversation participant."
  def list_direct_typing_user_ids(
        %Scope{user: %User{id: user_id}} = scope,
        direct_conversation_id
      ) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id),
         other_user_id when is_binary(other_user_id) <-
           DirectConversation.other_user_id(direct_conversation, user_id) do
      case Friendships.lock_accepted_friendship(scope, other_user_id) do
        :ok -> Runtime.list_typing_user_ids(direct_conversation.id)
        {:error, :not_friends} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def list_direct_typing_user_ids(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Starts transient typing for a current Friend in a Direct Conversation."
  def direct_user_started_typing(
        %Scope{user: %User{id: user_id}} = scope,
        direct_conversation_id
      ) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id),
         other_user_id when is_binary(other_user_id) <-
           DirectConversation.other_user_id(direct_conversation, user_id),
         :ok <- Friendships.lock_accepted_friendship(scope, other_user_id) do
      Runtime.user_started_typing(direct_conversation.id, user_id)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def direct_user_started_typing(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Stops transient typing for a Direct Conversation participant."
  def direct_user_stopped_typing(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id
      ) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      Runtime.user_stopped_typing_if_running(conversation_id, user_id)
    else
      nil -> {:error, :not_found}
    end
  end

  def direct_user_stopped_typing(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Subscribes one participant to compact Direct Message change facts."
  @spec subscribe_to_direct_messages(term(), term()) ::
          :ok | {:error, :unauthenticated | :not_found}
  def subscribe_to_direct_messages(%Scope{user: %User{id: user_id}}, direct_conversation_id) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, ConversationTopics.messages(conversation_id))
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_to_direct_messages(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Subscribes one participant to committed Direct Message reaction changes."
  @spec subscribe_to_direct_reactions(term(), term()) ::
          :ok | {:error, :unauthenticated | :not_found}
  def subscribe_to_direct_reactions(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id
      ) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, ConversationTopics.reactions(conversation_id))
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_to_direct_reactions(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  @doc "Subscribes one participant to only their private Direct Conversation Read State."
  @spec subscribe_to_direct_read_state(term(), term()) ::
          :ok | {:error, :unauthenticated | :not_found}
  def subscribe_to_direct_read_state(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id
      ) do
    with %DirectConversation{id: conversation_id} <-
           get_participant_direct_conversation(user_id, direct_conversation_id) do
      Phoenix.PubSub.subscribe(
        DiscordClone.PubSub,
        ConversationTopics.read_state(user_id, conversation_id)
      )
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_to_direct_read_state(_scope, _direct_conversation_id),
    do: {:error, :unauthenticated}

  defp get_participant_direct_conversation(user_id, direct_conversation_id) do
    UUIDIdentifier.cast_or(direct_conversation_id, nil, fn direct_conversation_id ->
      Repo.one(
        from direct_conversation in DirectConversation,
          where:
            direct_conversation.id == ^direct_conversation_id and
              (direct_conversation.user_low_id == ^user_id or
                 direct_conversation.user_high_id == ^user_id)
      )
    end)
  end

  @doc "Sends one durable Message in a Direct Conversation between current Friends."
  @spec send_direct_message(term(), term(), map()) ::
          {:ok, Message.t()}
          | {:error, :unauthenticated | :not_found | :not_friends}
          | {:error, :invalid_message, Ecto.Changeset.t()}
  def send_direct_message(
        %Scope{user: %User{id: sender_user_id}} = scope,
        direct_conversation_id,
        attrs
      ) do
    with {:ok, direct_conversation_id} <- Ecto.UUID.cast(direct_conversation_id) do
      case persist_direct_message(scope, direct_conversation_id, attrs) do
        {:ok, {message, read_state_changes, recipient_user_id}} ->
          message = preload_message_for_display(message)
          :ok = Runtime.put_recent_message(message)
          :ok = Runtime.user_stopped_typing(direct_conversation_id, sender_user_id)
          :ok = Unread.broadcast_changes(read_state_changes)
          :ok = broadcast_direct_message_created(message)
          :ok = broadcast_direct_navigation_changed(sender_user_id, %{action: :message_created})

          :ok =
            broadcast_direct_navigation_changed(recipient_user_id, %{
              action: :message_created
            })

          :ok =
            broadcast_activity_change(recipient_user_id, %{
              action: :created,
              source_message_id: message.id
            })

          {:ok, message}

        {:error, {:invalid_message, changeset}} ->
          {:error, :invalid_message, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def send_direct_message(_scope, _direct_conversation_id, _attrs),
    do: {:error, :unauthenticated}

  @doc "Marks one bounded sequence range genuinely visible for a Direct Conversation participant."
  @spec mark_direct_messages_visible(term(), term(), term(), term()) ::
          {:ok, ChannelReadState.t()}
          | {:error, :unauthenticated | :not_found | :invalid_range | :range_too_large}
  def mark_direct_messages_visible(
        %Scope{user: %User{id: user_id}},
        direct_conversation_id,
        from_seq,
        to_seq
      ) do
    with %DirectConversation{} = direct_conversation <-
           get_participant_direct_conversation(user_id, direct_conversation_id),
         %Conversation{} = conversation <- Repo.get(Conversation, direct_conversation.id),
         :ok <- validate_direct_visible_range(conversation, from_seq, to_seq) do
      Repo.transaction(fn ->
        {read_state, spans} =
          Unread.lock_direct_read_state_and_spans!(user_id, direct_conversation.id)

        activity_item_ids =
          lock_visible_direct_activity_item_ids(
            user_id,
            direct_conversation.id,
            from_seq,
            to_seq
          )

        {read_state, read_state_changed?} =
          Unread.apply_locked_visible_range!(read_state, spans, from_seq, to_seq)

        activity_updated_count = mark_locked_activity_items_read(activity_item_ids)
        {read_state, read_state_changed?, activity_updated_count}
      end)
      |> case do
        {:ok, {read_state, read_state_changed?, activity_updated_count}} ->
          if read_state_changed? do
            :ok = Unread.broadcast_changes([{:direct_conversation, user_id, read_state}])
          end

          if activity_updated_count > 0 do
            :ok =
              broadcast_activity_change(user_id, %{
                action: :read,
                conversation_id: direct_conversation.id,
                updated_count: activity_updated_count
              })
          end

          {:ok, read_state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_direct_messages_visible(_scope, _direct_conversation_id, _from_seq, _to_seq),
    do: {:error, :unauthenticated}

  defp persist_direct_message(
         %Scope{user: %User{id: user_id}} = scope,
         direct_conversation_id,
         attrs
       ) do
    Repo.transaction(fn ->
      direct_conversation = get_writable_direct_conversation!(scope, direct_conversation_id)
      locked_conversation = lock_conversation_for_update!(direct_conversation_id)
      next_seq = locked_conversation.last_message_seq + 1

      changeset =
        %Message{channel_id: direct_conversation_id, user_id: user_id}
        |> Message.direct_message_changeset(%{content: direct_message_content(attrs)})

      reply_to_message_id = direct_message_reply_target(attrs)

      with {:ok, reply_to_message_id} <-
             validate_reply_target(
               changeset,
               direct_conversation_id,
               next_seq,
               reply_to_message_id,
               :conversation
             ),
           {:ok, message} <-
             changeset
             |> Ecto.Changeset.put_change(:seq, next_seq)
             |> Ecto.Changeset.put_change(:reply_to_message_id, reply_to_message_id)
             |> Repo.insert() do
        locked_conversation
        |> Ecto.Changeset.change(last_message_seq: next_seq)
        |> Repo.update!()

        read_state_changes =
          Unread.fanout_on_direct_send!(direct_conversation, user_id, next_seq)

        recipient_user_id = DirectConversation.other_user_id(direct_conversation, user_id)

        %ActivityItem{}
        |> ActivityItem.create_direct_message_changeset(%{
          recipient_user_id: recipient_user_id,
          actor_user_id: user_id,
          source_message_id: message.id,
          source_conversation_id: direct_conversation.id
        })
        |> Repo.insert!()

        {message, read_state_changes, recipient_user_id}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          Repo.rollback({:invalid_message, changeset})
      end
    end)
  end

  defp direct_message_content(attrs) when is_map(attrs),
    do: Map.get(attrs, :content) || Map.get(attrs, "content")

  defp direct_message_content(_attrs), do: nil

  defp direct_message_reply_target(attrs) when is_map(attrs),
    do: Map.get(attrs, :reply_to_message_id) || Map.get(attrs, "reply_to_message_id")

  defp direct_message_reply_target(_attrs), do: nil

  defp validate_direct_visible_range(%Conversation{} = conversation, from_seq, to_seq)
       when is_integer(from_seq) and is_integer(to_seq) do
    cond do
      from_seq < 1 or from_seq > to_seq -> {:error, :invalid_range}
      to_seq - from_seq + 1 > @message_page_size -> {:error, :range_too_large}
      to_seq > conversation.last_message_seq -> {:error, :invalid_range}
      true -> :ok
    end
  end

  defp validate_direct_visible_range(_conversation, _from_seq, _to_seq),
    do: {:error, :invalid_range}

  defp lock_visible_direct_activity_item_ids(user_id, conversation_id, from_seq, to_seq) do
    Repo.all(
      from activity_item in ActivityItem,
        join: message in Message,
        on: message.id == activity_item.source_message_id,
        where:
          activity_item.recipient_user_id == ^user_id and
            activity_item.source_conversation_id == ^conversation_id and
            activity_item.kind == ^ActivityItem.direct_message_kind() and
            is_nil(activity_item.read_at) and
            message.channel_id == ^conversation_id and
            message.user_id != ^user_id and
            message.seq >= ^from_seq and message.seq <= ^to_seq,
        order_by: [asc: activity_item.id],
        lock: "FOR UPDATE",
        select: activity_item.id
    )
  end

  defp mark_locked_activity_items_read([]), do: 0

  defp mark_locked_activity_items_read(activity_item_ids) do
    now = DateTime.utc_now(:microsecond)

    {updated_count, _rows} =
      Repo.update_all(
        from(activity_item in ActivityItem,
          where: activity_item.id in ^activity_item_ids and is_nil(activity_item.read_at)
        ),
        set: [read_at: now, updated_at: now]
      )

    updated_count
  end

  defp get_writable_direct_conversation!(
         %Scope{user: %User{id: user_id}} = scope,
         direct_conversation_id
       ) do
    direct_conversation =
      Repo.one(
        from direct_conversation in DirectConversation,
          where:
            direct_conversation.id == ^direct_conversation_id and
              (direct_conversation.user_low_id == ^user_id or
                 direct_conversation.user_high_id == ^user_id)
      )

    if is_nil(direct_conversation), do: Repo.rollback(:not_found)

    other_user_id = DirectConversation.other_user_id(direct_conversation, user_id)

    case Friendships.lock_accepted_friendship(scope, other_user_id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    direct_conversation
  end

  @doc "Returns the scoped user's global unread activity count."
  @spec unread_activity_count(term()) :: {:ok, non_neg_integer()} | {:error, :unauthenticated}
  def unread_activity_count(%Scope{user: %User{id: user_id}}) do
    count =
      Repo.aggregate(
        from(activity_item in ActivityItem,
          where: activity_item.recipient_user_id == ^user_id and is_nil(activity_item.read_at)
        ),
        :count
      )

    {:ok, count}
  end

  def unread_activity_count(_scope), do: {:error, :unauthenticated}

  @doc "Lists the scoped user's primary Activity preview, excluding handled Direct Messages."
  @spec list_activity_preview(term(), pos_integer()) ::
          {:ok, [ActivityItem.t()]} | {:error, :unauthenticated | :invalid_limit}
  def list_activity_preview(scope, limit \\ 5)

  def list_activity_preview(%Scope{user: %User{id: user_id}}, limit)
      when is_integer(limit) and limit > 0 and limit <= @activity_feed_page_size do
    items =
      Repo.all(
        from activity_item in activity_feed_query(user_id),
          where:
            activity_item.kind != ^ActivityItem.direct_message_kind() or
              is_nil(activity_item.read_at),
          limit: ^limit
      )

    {:ok, items}
  end

  def list_activity_preview(%Scope{user: %User{}}, _limit), do: {:error, :invalid_limit}
  def list_activity_preview(_scope, _limit), do: {:error, :unauthenticated}

  @doc "Returns one stable page of the scoped user's accessible global Activity Feed."
  @spec list_activity_feed(term(), nil | activity_feed_cursor()) ::
          {:ok, %{items: [ActivityItem.t()], next_cursor: nil | activity_feed_cursor()}}
          | {:error, :unauthenticated | :invalid_cursor}
  def list_activity_feed(scope, cursor \\ nil)

  def list_activity_feed(%Scope{user: %User{id: user_id}}, cursor) do
    with {:ok, cursor} <- cast_activity_cursor(cursor) do
      query = activity_feed_query(user_id) |> limit(^(@activity_feed_page_size + 1))

      activity_items =
        query
        |> activity_feed_after(cursor)
        |> Repo.all()

      {items, overflow} = Enum.split(activity_items, @activity_feed_page_size)

      next_cursor =
        case overflow do
          [] -> nil
          [_extra_item] -> activity_feed_cursor(List.last(items))
        end

      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  def list_activity_feed(_scope, _cursor), do: {:error, :unauthenticated}

  defp activity_feed_query(user_id) do
    from activity_item in ActivityItem,
      left_join: membership in WorkspaceMembership,
      on:
        membership.workspace_id == activity_item.workspace_id and
          membership.user_id == ^user_id,
      left_join: direct_conversation in DirectConversation,
      on: direct_conversation.id == activity_item.source_conversation_id,
      where:
        activity_item.recipient_user_id == ^user_id and
          (not is_nil(membership.user_id) or
             not is_nil(activity_item.source_friend_relationship_id) or
             (activity_item.kind in [
                ^ActivityItem.direct_message_kind(),
                ^ActivityItem.missed_direct_call_kind()
              ] and
                (direct_conversation.user_low_id == ^user_id or
                   direct_conversation.user_high_id == ^user_id))),
      order_by: [desc: activity_item.inserted_at, desc: activity_item.id],
      preload: [
        :workspace,
        :source_channel,
        :source_message,
        :source_friend_relationship,
        :actor_user,
        source_direct_conversation: [:user_low, :user_high]
      ]
  end

  @doc "Marks the scoped user's currently committed unread Activity Items read."
  @spec mark_all_activity_read(term()) ::
          {:ok, non_neg_integer()} | {:error, :unauthenticated}
  def mark_all_activity_read(%Scope{user: %User{id: user_id}}) do
    {updated_count, _} =
      Repo.update_all(
        from(activity_item in ActivityItem,
          where:
            activity_item.recipient_user_id == ^user_id and is_nil(activity_item.read_at) and
              activity_item.inserted_at <= fragment("statement_timestamp()"),
          update: [
            set: [
              read_at: fragment("statement_timestamp()"),
              updated_at: fragment("statement_timestamp()")
            ]
          ]
        ),
        []
      )

    if updated_count > 0 do
      :ok = broadcast_activity_change(user_id, %{action: :all_read, updated_count: updated_count})
    end

    {:ok, updated_count}
  end

  def mark_all_activity_read(_scope), do: {:error, :unauthenticated}

  defp cast_activity_cursor(nil), do: {:ok, nil}

  defp cast_activity_cursor(%{inserted_at: %DateTime{} = inserted_at, id: id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, %{inserted_at: inserted_at, id: id}}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp cast_activity_cursor(_cursor), do: {:error, :invalid_cursor}

  defp activity_feed_after(query, nil), do: query

  defp activity_feed_after(query, %{inserted_at: inserted_at, id: id}) do
    from activity_item in query,
      where:
        activity_item.inserted_at < ^inserted_at or
          (activity_item.inserted_at == ^inserted_at and activity_item.id < ^id)
  end

  defp activity_feed_cursor(%ActivityItem{id: id, inserted_at: inserted_at}) do
    %{id: id, inserted_at: inserted_at}
  end

  @doc """
  Opens one Activity Item for the scoped recipient.

  The item is marked read only after its current Message, Friend relationship,
  or Direct Conversation source has been validated. All invalid or inaccessible
  targets use `:not_found` so callers cannot infer source existence.
  """
  @spec open_activity_item(term(), term()) ::
          {:ok,
           %{workspace_id: Ecto.UUID.t(), channel_id: Ecto.UUID.t(), message_id: Ecto.UUID.t()}}
          | {:ok,
             %{
               friend_relationship_id: Ecto.UUID.t(),
               friends_section: :incoming_requests | :friends
             }}
          | {:ok, %{direct_conversation_id: Ecto.UUID.t(), message_id: Ecto.UUID.t()}}
          | {:ok, %{direct_conversation_id: Ecto.UUID.t()}}
          | {:error, :unauthenticated | :not_found}
  def open_activity_item(%Scope{user: %User{id: user_id}} = scope, activity_item_id) do
    with {:ok, activity_item_id} <- Ecto.UUID.cast(activity_item_id) do
      Repo.transaction(fn ->
        activity_item =
          Repo.one(
            from activity_item in ActivityItem,
              where:
                activity_item.id == ^activity_item_id and
                  activity_item.recipient_user_id == ^user_id,
              lock: "FOR UPDATE"
          )

        destination = activity_destination(activity_item, scope)

        if destination do
          updated_count = mark_opened_activity_read(activity_item, activity_item_id, user_id)

          {destination, updated_count}
        else
          Repo.rollback(:not_found)
        end
      end)
      |> case do
        {:ok, {destination, 0}} ->
          {:ok, destination}

        {:ok, {destination, _updated_count}} ->
          :ok =
            broadcast_activity_change(user_id, %{
              action: :read,
              activity_item_id: activity_item_id
            })

          {:ok, destination}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def open_activity_item(%Scope{user: %User{}}, _activity_item_id),
    do: {:error, :not_found}

  def open_activity_item(_scope, _activity_item_id), do: {:error, :unauthenticated}

  defp activity_destination(
         %ActivityItem{
           kind: "missed_direct_call",
           id: activity_item_id
         },
         %Scope{user: %User{id: user_id}}
       ) do
    Repo.one(
      from activity_item in ActivityItem,
        join: direct_conversation in DirectConversation,
        on:
          direct_conversation.id == activity_item.source_conversation_id and
            (direct_conversation.user_low_id == ^user_id or
               direct_conversation.user_high_id == ^user_id),
        where:
          activity_item.id == ^activity_item_id and
            activity_item.recipient_user_id == ^user_id and
            activity_item.kind == ^ActivityItem.missed_direct_call_kind(),
        select: %{direct_conversation_id: direct_conversation.id}
    )
  end

  defp activity_destination(
         %ActivityItem{
           kind: "direct_message",
           id: activity_item_id
         },
         %Scope{user: %User{id: user_id}}
       ) do
    Repo.one(
      from activity_item in ActivityItem,
        join: direct_conversation in DirectConversation,
        on:
          direct_conversation.id == activity_item.source_conversation_id and
            (direct_conversation.user_low_id == ^user_id or
               direct_conversation.user_high_id == ^user_id),
        join: message in Message,
        on:
          message.id == activity_item.source_message_id and
            message.channel_id == direct_conversation.id and
            is_nil(message.deleted_at),
        where:
          activity_item.id == ^activity_item_id and
            activity_item.recipient_user_id == ^user_id and
            activity_item.kind == ^ActivityItem.direct_message_kind(),
        select: %{
          direct_conversation_id: direct_conversation.id,
          message_id: message.id
        }
    )
  end

  defp activity_destination(
         %ActivityItem{
           source_friend_relationship_id: relationship_id,
           kind: kind
         },
         scope
       )
       when not is_nil(relationship_id) do
    case DiscordClone.Friendships.get_relationship(scope, relationship_id) do
      {:ok, %{status: :accepted}} ->
        %{friend_relationship_id: relationship_id, friends_section: :friends}

      {:ok, %{status: :pending}} ->
        friends_section =
          if kind == ActivityItem.friend_request_received_kind(),
            do: :incoming_requests,
            else: :friends

        %{friend_relationship_id: relationship_id, friends_section: friends_section}

      {:error, :not_found} ->
        nil
    end
  end

  defp activity_destination(
         %ActivityItem{id: activity_item_id},
         %Scope{user: %User{id: user_id}}
       ) do
    Repo.one(
      from activity_item in ActivityItem,
        join: membership in WorkspaceMembership,
        on:
          membership.workspace_id == activity_item.workspace_id and
            membership.user_id == ^user_id,
        join: channel in Channel,
        on:
          channel.id == activity_item.source_conversation_id and
            channel.workspace_id == activity_item.workspace_id,
        join: message in Message,
        on:
          message.id == activity_item.source_message_id and
            message.channel_id == activity_item.source_conversation_id and
            is_nil(message.deleted_at),
        where:
          activity_item.id == ^activity_item_id and
            activity_item.recipient_user_id == ^user_id,
        select: %{
          workspace_id: activity_item.workspace_id,
          channel_id: activity_item.source_conversation_id,
          message_id: activity_item.source_message_id
        }
    )
  end

  defp activity_destination(nil, _scope), do: nil

  # Direct Message attention is cleared only by the genuine-visibility workflow.
  # Navigating from Activity must not pre-emptively mark it read.
  defp mark_opened_activity_read(
         %ActivityItem{kind: "direct_message"},
         _activity_item_id,
         _user_id
       ),
       do: 0

  defp mark_opened_activity_read(_activity_item, activity_item_id, user_id) do
    {updated_count, _} =
      Repo.update_all(
        from(activity_item in ActivityItem,
          where:
            activity_item.id == ^activity_item_id and
              activity_item.recipient_user_id == ^user_id and
              is_nil(activity_item.read_at)
        ),
        set: [read_at: DateTime.utc_now(:microsecond)]
      )

    updated_count
  end

  @doc "Initializes zero-unread read states for a user across a workspace's channels."
  @spec initialize_workspace_reads_for_user(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, reason()}
  defdelegate initialize_workspace_reads_for_user(user_id, workspace_id), to: Unread

  @doc "Initializes zero-unread read states for all existing members of a channel."
  @spec initialize_channel_reads_for_workspace_members(Ecto.UUID.t()) ::
          :ok | {:error, reason()}
  defdelegate initialize_channel_reads_for_workspace_members(channel_id), to: Unread

  @doc "Deletes a user's read states for every channel in a workspace."
  @spec delete_workspace_reads_for_user(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, reason()}
  defdelegate delete_workspace_reads_for_user(user_id, workspace_id), to: Unread

  @doc """
  Soft-deletes messages authored by `target_user_id` across all channels in the
  given workspace, optionally bounded to a time window.

  `bound` is either `:all` (every message) or a `%DateTime{}` cutoff (only
  messages inserted at or after the cutoff). Reactions on the affected messages
  are removed and each message keeps its content behind a `deleted_at`
  tombstone. Returns `{:ok, messages}` with the affected messages (author
  preloaded) so callers can broadcast refreshes after committing.
  """
  def soft_delete_user_workspace_messages(workspace_id, target_user_id, actor_user_id, bound) do
    case soft_delete_user_workspace_messages_with_activity(
           workspace_id,
           target_user_id,
           actor_user_id,
           bound
         ) do
      {:ok, %{messages: messages, activity_recipient_ids: activity_recipient_ids}} ->
        :ok = broadcast_activity_removals(activity_recipient_ids, %{workspace_id: workspace_id})
        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def soft_delete_user_workspace_messages_with_activity_facts(
        workspace_id,
        target_user_id,
        actor_user_id,
        bound
      ) do
    soft_delete_user_workspace_messages_with_activity(
      workspace_id,
      target_user_id,
      actor_user_id,
      bound
    )
  end

  defp soft_delete_user_workspace_messages_with_activity(
         workspace_id,
         target_user_id,
         actor_user_id,
         bound
       ) do
    deleted_at = DateTime.utc_now(:second)

    message_ids =
      Repo.all(cleanup_message_ids_query(workspace_id, target_user_id, bound))

    if message_ids == [] do
      {:ok, %{messages: [], activity_recipient_ids: []}}
    else
      Multi.new()
      |> Multi.run(:activity_recipient_ids, fn repo, _changes ->
        recipient_ids =
          repo.all(
            from activity_item in ActivityItem,
              where: activity_item.source_message_id in ^message_ids,
              select: activity_item.recipient_user_id,
              distinct: true
          )

        {:ok, recipient_ids}
      end)
      |> Multi.delete_all(
        :activity_items,
        from(activity_item in ActivityItem,
          where: activity_item.source_message_id in ^message_ids
        )
      )
      |> Multi.delete_all(
        :reactions,
        from(reaction in MessageReaction, where: reaction.message_id in ^message_ids)
      )
      |> Multi.update_all(
        :messages,
        from(message in Message, where: message.id in ^message_ids),
        set: [deleted_at: deleted_at, deleted_by_user_id: actor_user_id, updated_at: deleted_at]
      )
      |> Multi.run(:deleted_messages, fn repo, _changes ->
        messages =
          repo.all(
            from message in Message,
              where: message.id in ^message_ids,
              order_by: [asc: message.channel_id, asc: message.seq],
              preload: [:user]
          )

        {:ok, messages}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{deleted_messages: messages, activity_recipient_ids: activity_recipient_ids}} ->
          {:ok, %{messages: messages, activity_recipient_ids: activity_recipient_ids}}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp cleanup_message_ids_query(workspace_id, target_user_id, bound) do
    query =
      from message in Message,
        join: channel in Channel,
        on: channel.id == message.channel_id,
        where: channel.workspace_id == ^workspace_id,
        where: message.user_id == ^target_user_id,
        where: is_nil(message.deleted_at),
        select: message.id

    case bound do
      :all -> query
      %DateTime{} = cutoff -> from message in query, where: message.inserted_at >= ^cutoff
    end
  end

  @doc """
  Broadcasts `:message_deleted` refreshes for messages cleaned during a ban so
  connected channel viewers can re-render the affected placeholders.
  """
  def broadcast_cleaned_messages(messages) do
    Enum.each(messages, fn %Message{} = message ->
      Phoenix.PubSub.broadcast(
        DiscordClone.PubSub,
        ConversationTopics.messages(message.channel_id),
        {:message_deleted, %{conversation_id: message.channel_id, message_id: message.id}}
      )
    end)

    :ok
  end

  @doc false
  def broadcast_activity_removed(user_id, %{workspace_id: workspace_id}) do
    broadcast_activity_change(user_id, %{action: :removed, workspace_id: workspace_id})
  end

  @doc false
  def broadcast_activity_removals(user_ids, %{workspace_id: workspace_id}) do
    broadcast_activity_changes(user_ids, %{action: :removed, workspace_id: workspace_id})
  end

  def schedule_workspace_timeout_expiry(%WorkspaceModeration{} = moderation) do
    Runtime.schedule_timeout_expiry(moderation)
  end

  def cancel_workspace_timeout_expiry(%WorkspaceModeration{} = moderation) do
    Runtime.cancel_timeout_expiry(moderation)
  end

  def broadcast_workspace_user_joined(workspace_id, user_id) do
    Runtime.broadcast_user_joined(workspace_id, user_id)
  end

  defdelegate list_unread_counts(scope, workspace_id), to: Unread
  defdelegate list_channel_read_summaries(scope, workspace_id), to: Unread

  @doc """
  Opens an accessible channel and returns its persisted read state and landing target.

  Returns a normalized error when the scope is unauthenticated or the channel is inaccessible.
  """
  @spec open_channel(term(), Ecto.UUID.t()) :: {:ok, map()} | {:error, reason()}
  def open_channel(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      now = DateTime.utc_now(:second)

      Repo.transaction(fn ->
        Unread.ensure_channel_read_state!(user_id, channel_id)

        read_state =
          user_id
          |> Unread.lock_channel_read_state!(channel_id)
          |> Unread.change_read_state(%{last_opened_at: now})
          |> Repo.update!()

        %{channel: channel, read_state: read_state, landing: channel_open_landing(read_state)}
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def open_channel(_scope, _channel_id), do: {:error, :unauthenticated}

  defdelegate jump_to_oldest_unread(scope, channel_id), to: Unread

  @doc """
  Marks an accessible channel read, persists its latest anchor, and returns the latest message window.

  Returns a normalized error when the scope is unauthenticated or the channel is inaccessible.
  """
  @spec jump_to_latest(term(), Ecto.UUID.t()) :: window_result()
  def jump_to_latest(%Scope{user: %User{id: user_id}} = scope, channel_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         :ok <- mark_channel_read(scope, channel_id),
         {:ok, _read_state} <- Unread.ensure_channel_read_state!(user_id, channel_id) do
      channel =
        Channel
        |> Repo.get!(channel.id)
        |> Repo.preload(:conversation)

      Unread.get_channel_read_state!(user_id, channel_id)
      |> Unread.change_read_state(%{
        last_viewed_anchor_seq: channel.conversation.last_message_seq
      })
      |> Repo.update!()

      {:ok,
       MessageWindow.load_for_channel(
         channel,
         max(1, channel.conversation.last_message_seq - @message_page_size + 1),
         channel.conversation.last_message_seq
       )}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def jump_to_latest(_scope, _channel_id), do: {:error, :unauthenticated}

  @doc """
  Persists a validated rendered-message sequence as the user's channel scroll anchor.

  Invalid sequences and inaccessible channels return normalized error reasons.
  """
  @spec persist_channel_anchor(term(), Ecto.UUID.t(), term()) ::
          {:ok, struct()} | {:error, reason()}
  def persist_channel_anchor(%Scope{user: %User{id: user_id}}, channel_id, anchor_seq)
      when is_integer(anchor_seq) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         :ok <- validate_channel_anchor(channel, anchor_seq) do
      Repo.transaction(fn ->
        Unread.ensure_channel_read_state!(user_id, channel_id)

        user_id
        |> Unread.lock_channel_read_state!(channel_id)
        |> Unread.change_read_state(%{last_viewed_anchor_seq: anchor_seq})
        |> Repo.update!()
      end)
      |> case do
        {:ok, read_state} -> {:ok, read_state}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def persist_channel_anchor(%Scope{user: %User{}}, _channel_id, _anchor_seq),
    do: {:error, :invalid_sequence}

  def persist_channel_anchor(_scope, _channel_id, _anchor_seq), do: {:error, :unauthenticated}

  defp channel_open_landing(%ChannelReadState{unread_count: unread_count} = read_state)
       when unread_count > 0 and unread_count <= @small_unread_landing_limit do
    %{type: :sequence, reason: :first_unread, target_seq: read_state.first_unread_seq}
  end

  defp channel_open_landing(%ChannelReadState{unread_count: unread_count} = read_state)
       when unread_count > @small_unread_landing_limit do
    target_seq = max(1, read_state.last_unread_seq - @large_unread_landing_backtrack)
    %{type: :sequence, reason: :recent_unread, target_seq: target_seq}
  end

  defp channel_open_landing(%ChannelReadState{last_viewed_anchor_seq: anchor_seq})
       when is_integer(anchor_seq) do
    %{type: :sequence, reason: :last_viewed_anchor, target_seq: anchor_seq}
  end

  defp channel_open_landing(%ChannelReadState{}) do
    %{type: :latest, reason: :latest}
  end

  defdelegate mark_channel_read(scope, channel_id), to: Unread
  # Deliberate test seam: the only public way to inject an arbitrary unread
  # span. In production, unread spans arise solely from `send_message/3` fanout.
  @doc false
  defdelegate add_channel_unread_range(scope, channel_id, from_seq, to_seq), to: Unread

  @doc """
  Marks a visible sequence range read after authoritative validation in the Unread boundary.

  Returns `:ok` or a normalized error reason for invalid ranges, access, or authentication.
  """
  @spec subtract_visible_read_range(term(), Ecto.UUID.t(), term(), term()) ::
          :ok | {:error, reason()}
  defdelegate subtract_visible_read_range(scope, channel_id, from_seq, to_seq), to: Unread
  defdelegate subscribe_to_channel_read_state(scope, channel_id), to: Unread

  # Subscribes to the Channel's shared Conversation topic. Transient typing
  # indicators (`:typing_started` / `:typing_stopped`, broadcast by the
  # Conversation runtime)
  # ride on this same topic, so a message subscriber also receives typing
  # events — there is deliberately no separate typing subscription.
  def subscribe_to_channel_messages(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, ConversationTopics.messages(channel_id))
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_to_channel_messages(_scope, _channel_id), do: {:error, :unauthenticated}

  def subscribe_to_channel_reactions(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, ConversationTopics.reactions(channel_id))
    else
      nil -> {:error, :not_found}
    end
  end

  def subscribe_to_channel_reactions(_scope, _channel_id), do: {:error, :unauthenticated}

  def subscribe_to_workspace_messages(%Scope{user: %User{id: user_id}}, workspace_id) do
    with :ok <- authorize_workspace_member(workspace_id, user_id) do
      Phoenix.PubSub.subscribe(DiscordClone.PubSub, workspace_messages_topic(workspace_id))
    end
  end

  def subscribe_to_workspace_messages(_scope, _workspace_id), do: {:error, :unauthenticated}

  def subscribe_to_workspace_presence(%Scope{user: %User{id: user_id}}, workspace_id) do
    with :ok <- authorize_workspace_member(workspace_id, user_id) do
      Runtime.subscribe_workspace_presence(workspace_id)
    end
  end

  def subscribe_to_workspace_presence(_scope, _workspace_id), do: {:error, :unauthenticated}

  def list_online_workspace_user_ids(%Scope{user: %User{id: user_id}}, workspace_id) do
    with :ok <- authorize_workspace_member(workspace_id, user_id) do
      {:ok, Runtime.online_user_ids(workspace_id)}
    end
  end

  def list_online_workspace_user_ids(_scope, _workspace_id), do: {:error, :unauthenticated}

  def join_workspace_presence(scope, workspace_id, live_view_pid \\ self())

  def join_workspace_presence(%Scope{user: %User{id: user_id}}, workspace_id, live_view_pid)
      when is_pid(live_view_pid) do
    with :ok <- authorize_workspace_member(workspace_id, user_id) do
      Runtime.join_workspace_presence(workspace_id, user_id, live_view_pid)
    end
  end

  def join_workspace_presence(_scope, _workspace_id, _live_view_pid),
    do: {:error, :unauthenticated}

  def stop_workspace_presence(workspace_id) do
    Runtime.stop_workspace_presence(workspace_id)
  end

  def ensure_channel_runtime(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      Runtime.ensure_conversation(channel_id)
    else
      nil -> {:error, :not_found}
    end
  end

  def ensure_channel_runtime(_scope, _channel_id), do: {:error, :unauthenticated}

  # Deliberate test seam: the only public window into the runtime hot-message
  # cache, used to assert cache warm-up and reload behavior. Production reads
  # go through the message-window functions below.
  @doc false
  def list_recent_messages(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      Runtime.list_recent_messages(channel_id)
    else
      nil -> {:error, :not_found}
    end
  end

  def list_recent_messages(_scope, _channel_id), do: {:error, :unauthenticated}

  def fetch_message(%Scope{user: %User{id: user_id}}, message_id) do
    case get_member_message(message_id, user_id) do
      %Message{} = message -> {:ok, preload_message_for_display(message)}
      nil -> {:error, :not_found}
    end
  end

  def fetch_message(_scope, _message_id), do: {:error, :unauthenticated}

  @doc """
  Loads the newest bounded message window for a channel visible to the current scope.

  Returns `{:ok, window}` or a normalized authorization/not-found reason.
  """
  @spec load_latest_message_window(term(), Ecto.UUID.t()) :: window_result()
  def load_latest_message_window(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      latest_seq = channel.conversation.last_message_seq
      oldest_requested_seq = max(1, latest_seq - @message_page_size + 1)
      {:ok, MessageWindow.load_for_channel(channel, oldest_requested_seq, latest_seq)}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_latest_message_window(_scope, _channel_id), do: {:error, :unauthenticated}

  @doc """
  Loads a bounded message window centered around a sequence visible to the current scope.

  Invalid sequences and inaccessible channels return normalized error reasons.
  """
  @spec load_message_window_around(term(), Ecto.UUID.t(), term()) :: window_result()
  def load_message_window_around(%Scope{user: %User{id: user_id}}, channel_id, target_seq)
      when is_integer(target_seq) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      {:ok, MessageWindow.load_around_channel(channel, target_seq)}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_message_window_around(%Scope{user: %User{}}, _channel_id, _target_seq),
    do: {:error, :invalid_sequence}

  def load_message_window_around(_scope, _channel_id, _target_seq),
    do: {:error, :unauthenticated}

  @doc """
  Resolves a live Message inside an accessible Channel and loads a bounded
  sequence-centered window containing it.

  Missing, deleted, cross-Channel, malformed, and inaccessible targets are all
  reported as `:not_found` so callers do not reveal Message existence.
  """
  @spec navigate_to_message(term(), Ecto.UUID.t(), Ecto.UUID.t()) :: window_result()
  def navigate_to_message(%Scope{user: %User{id: user_id}}, channel_id, message_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      Repo.transaction(fn ->
        case get_live_channel_message(channel.id, message_id) do
          %Message{} = target ->
            channel
            |> MessageWindow.load_around_channel(target.seq)
            |> Map.put(:target, preload_message_for_display(target))

          nil ->
            Repo.rollback(:not_found)
        end
      end)
    else
      nil -> {:error, :not_found}
    end
  end

  def navigate_to_message(_scope, _channel_id, _message_id),
    do: {:error, :unauthenticated}

  @doc """
  Loads the message window immediately before `before_seq` for an accessible channel.

  Invalid cursors and inaccessible channels return normalized error reasons.
  """
  @spec load_older_message_window(term(), Ecto.UUID.t(), term()) :: window_result()
  def load_older_message_window(%Scope{user: %User{id: user_id}}, channel_id, before_seq)
      when is_integer(before_seq) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      to_seq = min(channel.conversation.last_message_seq, before_seq - 1)
      from_seq = max(1, to_seq - @message_page_size + 1)
      {:ok, MessageWindow.load_for_channel(channel, from_seq, to_seq)}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_older_message_window(%Scope{user: %User{}}, _channel_id, _before_seq),
    do: {:error, :invalid_sequence}

  def load_older_message_window(_scope, _channel_id, _before_seq),
    do: {:error, :unauthenticated}

  @doc """
  Loads the message window immediately after `after_seq` for an accessible channel.

  Invalid cursors and inaccessible channels return normalized error reasons.
  """
  @spec load_newer_message_window(term(), Ecto.UUID.t(), term()) :: window_result()
  def load_newer_message_window(%Scope{user: %User{id: user_id}}, channel_id, after_seq)
      when is_integer(after_seq) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id) do
      from_seq = max(1, after_seq + 1)
      to_seq = min(channel.conversation.last_message_seq, from_seq + @message_page_size - 1)
      {:ok, MessageWindow.load_for_channel(channel, from_seq, to_seq)}
    else
      nil -> {:error, :not_found}
    end
  end

  def load_newer_message_window(%Scope{user: %User{}}, _channel_id, _after_seq),
    do: {:error, :invalid_sequence}

  def load_newer_message_window(_scope, _channel_id, _after_seq),
    do: {:error, :unauthenticated}

  def list_typing_user_ids(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      Runtime.list_typing_user_ids(channel_id)
    else
      nil -> {:error, :not_found}
    end
  end

  def list_typing_user_ids(_scope, _channel_id), do: {:error, :unauthenticated}

  def user_started_typing(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         :ok <- Workspaces.member_participation_status(channel.workspace_id, user_id) do
      Runtime.user_started_typing(channel_id, user_id)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def user_started_typing(_scope, _channel_id), do: {:error, :unauthenticated}

  def user_stopped_typing(%Scope{user: %User{id: user_id}}, channel_id) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      Runtime.user_stopped_typing(channel_id, user_id)
    else
      nil -> {:error, :not_found}
      {:error, :muted} -> {:error, :muted}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  def user_stopped_typing(_scope, _channel_id), do: {:error, :unauthenticated}

  # Deliberate test seam: simple `%Message{}`-cursor pagination retained for
  # message-loading tests. Production pagination uses the seq-based message
  # window functions (`load_older_message_window/3` and friends), which return
  # a `%{messages, meta}` window rather than a bare list.
  @doc false
  def list_older_messages(
        %Scope{user: %User{id: user_id}},
        channel_id,
        %Message{seq: cursor_seq}
      ) do
    with %Channel{} <- get_member_channel(channel_id, user_id) do
      messages =
        Message
        |> where([message], message.channel_id == ^channel_id)
        |> where([message], message.seq < ^cursor_seq)
        |> order_by([message], desc: message.seq)
        |> limit(^@recent_message_limit)
        |> preload(^Message.display_preloads())
        |> Repo.all()
        |> Enum.reverse()

      {:ok, messages}
    else
      nil -> {:error, :not_found}
    end
  end

  def list_older_messages(_scope, _channel_id, _cursor), do: {:error, :unauthenticated}

  def send_message(%Scope{user: %User{id: user_id}}, channel_id, attrs) do
    with %Channel{} = channel <- get_member_channel(channel_id, user_id),
         :ok <- Workspaces.member_participation_status(channel.workspace_id, user_id) do
      changeset =
        Message.changeset(%Message{}, %{
          "content" => Map.get(attrs, "content") || Map.get(attrs, :content),
          "channel_id" => channel_id,
          "user_id" => user_id
        })

      reply_to_message_id =
        Map.get(attrs, "reply_to_message_id") || Map.get(attrs, :reply_to_message_id)

      case insert_sequenced_message(changeset, user_id, channel, reply_to_message_id) do
        {:ok, {message, read_state_changes, activity_recipient_ids}} ->
          message = preload_message_for_display(message)
          :ok = Runtime.put_recent_message(message)
          :ok = Runtime.user_stopped_typing(channel_id, user_id)
          :ok = Unread.broadcast_changes(read_state_changes)
          :ok = broadcast_message_created(message)
          :ok = broadcast_workspace_message_created(channel.workspace_id, message)

          :ok =
            broadcast_activity_changes(activity_recipient_ids, %{
              action: :created,
              source_message_id: message.id
            })

          {:ok, message}

        {:error, {:invalid_message, changeset}} ->
          {:error, :invalid_message, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, :muted} -> {:error, :muted}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  def send_message(_scope, _channel_id, _attrs), do: {:error, :unauthenticated}

  defp insert_sequenced_message(
         changeset,
         user_id,
         %Channel{id: channel_id} = channel,
         reply_to_message_id
       ) do
    Repo.transaction(fn ->
      locked_conversation = lock_conversation_for_update!(channel_id)
      next_seq = locked_conversation.last_message_seq + 1

      with {:ok, reply_to_message_id} <-
             validate_reply_target(
               changeset,
               channel_id,
               next_seq,
               reply_to_message_id,
               :channel
             ),
           mention_recognition <-
             resolve_mention_recognition(changeset, channel.workspace_id, user_id),
           {:ok, message} <-
             changeset
             |> Ecto.Changeset.put_change(:seq, next_seq)
             |> Ecto.Changeset.put_change(:reply_to_message_id, reply_to_message_id)
             |> Ecto.Changeset.put_change(:mention_recognition, mention_recognition)
             |> Repo.insert(),
           {:ok, _channel} <-
             locked_conversation
             |> Ecto.Changeset.change(last_message_seq: next_seq)
             |> Repo.update() do
        activity_recipient_ids = insert_mention_activity!(message, channel, user_id)
        read_state_changes = Unread.fanout_on_send!(channel, user_id, next_seq)
        {message, read_state_changes, activity_recipient_ids}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          Repo.rollback({:invalid_message, changeset})
      end
    end)
  end

  defp resolve_mention_recognition(changeset, workspace_id, actor_id) do
    usernames =
      changeset
      |> Ecto.Changeset.get_field(:content)
      |> MentionParser.usernames()

    everyone? = "everyone" in usernames
    direct_usernames = List.delete(usernames, "everyone")

    resolved_usernames =
      Repo.all(
        from membership in WorkspaceMembership,
          join: user in assoc(membership, :user),
          where:
            membership.workspace_id == ^workspace_id and
              fragment("lower(?)", user.username) in ^direct_usernames,
          select: fragment("lower(?)", user.username),
          lock: "FOR SHARE"
      )

    everyone_authorized? =
      everyone? and
        Repo.exists?(
          from membership in WorkspaceMembership,
            where:
              membership.workspace_id == ^workspace_id and membership.user_id == ^actor_id and
                membership.role in ^[Roles.owner(), Roles.admin()],
            lock: "FOR SHARE"
        )

    %{
      "usernames" => resolved_usernames,
      "everyone" => everyone_authorized?
    }
  end

  defp insert_mention_activity!(%Message{} = message, %Channel{} = channel, actor_id) do
    usernames = MentionParser.usernames(message.content)
    everyone? = "everyone" in usernames

    activity_rows_query =
      from membership in WorkspaceMembership,
        join: user in assoc(membership, :user),
        join: actor_membership in WorkspaceMembership,
        on:
          actor_membership.workspace_id == membership.workspace_id and
            actor_membership.user_id == ^actor_id,
        where:
          membership.workspace_id == ^channel.workspace_id and user.id != ^actor_id and
            (user.username in ^usernames or
               (^everyone? and actor_membership.role in ^[Roles.owner(), Roles.admin()])),
        lock: "FOR SHARE",
        select: %{
          recipient_user_id: user.id,
          actor_user_id: type(^actor_id, :binary_id),
          source_message_id: type(^message.id, :binary_id),
          source_conversation_id: type(^channel.id, :binary_id),
          workspace_id: type(^channel.workspace_id, :binary_id),
          kind:
            fragment(
              "CASE WHEN ? THEN ? ELSE ? END",
              user.username in ^usernames,
              ^ActivityItem.user_mention_kind(),
              ^ActivityItem.everyone_mention_kind()
            ),
          inserted_at: ^message.inserted_at,
          updated_at: ^message.inserted_at
        }

    {_count, activity_items} =
      Repo.insert_all(ActivityItem, activity_rows_query, returning: [:recipient_user_id])

    Enum.map(activity_items, & &1.recipient_user_id)
  end

  defp validate_reply_target(_changeset, _channel_id, _next_seq, nil, _conversation_label),
    do: {:ok, nil}

  defp validate_reply_target(
         changeset,
         channel_id,
         next_seq,
         reply_to_message_id,
         conversation_kind
       ) do
    target =
      UUIDIdentifier.cast_or(reply_to_message_id, nil, fn reply_to_message_id ->
        Repo.one(
          from message in Message,
            where:
              message.id == ^reply_to_message_id and message.channel_id == ^channel_id and
                message.seq < ^next_seq and is_nil(message.deleted_at),
            lock: "FOR SHARE",
            select: message.id
        )
      end)

    case target do
      nil ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :reply_to_message_id,
           reply_target_error(conversation_kind)
         )}

      target ->
        {:ok, target}
    end
  end

  defp reply_target_error(:channel), do: "is not an earlier message in this channel"

  defp reply_target_error(:conversation),
    do: "is not an earlier message in this conversation"

  defp preload_message_for_display(message) do
    Repo.preload(message, Message.display_preloads())
  end

  def toggle_reaction(%Scope{user: %User{id: user_id}} = scope, message_id, emoji) do
    with {:ok, normalized_emoji} <- Emoji.validate_reaction(emoji) do
      case get_accessible_message(message_id, user_id) do
        {:channel, message} ->
          toggle_channel_reaction(message, user_id, normalized_emoji)

        {:direct, message, direct_conversation} ->
          toggle_direct_reaction(
            scope,
            message,
            direct_conversation,
            user_id,
            normalized_emoji
          )

        nil ->
          {:error, :not_found}
      end
    else
      {:error, reason} -> {:error, :invalid_emoji, reason}
    end
  end

  def toggle_reaction(_scope, _message_id, _emoji), do: {:error, :unauthenticated}

  defp toggle_channel_reaction(message, user_id, normalized_emoji) do
    with :ok <- reject_deleted_message(message),
         :ok <- Workspaces.member_participation_status(message.channel.workspace_id, user_id) do
      persist_reaction_toggle(message, user_id, normalized_emoji)
    end
  end

  defp toggle_direct_reaction(
         scope,
         message,
         direct_conversation,
         user_id,
         normalized_emoji
       ) do
    with :ok <- reject_deleted_message(message) do
      Repo.transaction(fn ->
        case reaction_for(message.id, user_id, normalized_emoji) do
          %MessageReaction{} = reaction ->
            Repo.delete!(reaction)

          nil ->
            other_user_id = DirectConversation.other_user_id(direct_conversation, user_id)

            case Friendships.lock_accepted_friendship(scope, other_user_id) do
              :ok -> insert_reaction!(message.id, user_id, normalized_emoji)
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, reaction_or_deleted_reaction} ->
          :ok = broadcast_reaction_changed(message, normalized_emoji)
          {:ok, reaction_or_deleted_reaction}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp persist_reaction_toggle(message, user_id, normalized_emoji) do
    case reaction_for(message.id, user_id, normalized_emoji) do
      nil ->
        %MessageReaction{}
        |> MessageReaction.changeset(%{
          message_id: message.id,
          user_id: user_id,
          emoji: normalized_emoji
        })
        |> Repo.insert()

      %MessageReaction{} = reaction ->
        Repo.delete(reaction)
    end
    |> case do
      {:ok, reaction_or_deleted_reaction} ->
        :ok = broadcast_reaction_changed(message, normalized_emoji)
        {:ok, reaction_or_deleted_reaction}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp reaction_for(message_id, user_id, emoji) do
    Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id, emoji: emoji)
  end

  defp insert_reaction!(message_id, user_id, emoji) do
    %MessageReaction{}
    |> MessageReaction.changeset(%{message_id: message_id, user_id: user_id, emoji: emoji})
    |> Repo.insert!()
  end

  def delete_message(%Scope{user: %User{id: user_id}}, message_id) do
    case get_accessible_message(message_id, user_id) do
      {:channel, message} ->
        with :ok <- authorize_delete_message(message, user_id) do
          delete_message_with_optional_audit(message, user_id)
        end

      {:direct, %Message{user_id: ^user_id} = message, _direct_conversation} ->
        with :ok <- reject_deleted_message(message),
             {:ok, deleted_message} <- delete_message_with_optional_audit(message, user_id) do
          {:ok, redact_deleted_direct_message(deleted_message)}
        end

      {:direct, _message, _direct_conversation} ->
        {:error, :unauthorized}

      nil ->
        {:error, :not_found}
    end
  end

  def delete_message(_scope, _message_id), do: {:error, :unauthenticated}

  @doc """
  Answers whether the scoped user may delete `message`, reading roles from a
  `member_by_user_id` map the caller already holds (no DB round-trip).

  This is the UI-facing twin of the context's delete enforcement: both route
  through the same `Workspaces.can_delete_message?/2` rule, so the affordance the
  channel view shows can never drift from what `delete_message/2` will accept.
  """
  @spec can_delete_message?(term(), struct(), map()) :: boolean()
  def can_delete_message?(
        %Scope{user: %User{id: user_id}},
        %Message{} = message,
        member_by_user_id
      ) do
    actor_role = role_of(member_by_user_id, user_id)
    author_role = role_of(member_by_user_id, message.user_id)

    message.user_id == user_id or Workspaces.can_delete_message?(actor_role, author_role)
  end

  def can_delete_message?(_scope, _message, _member_by_user_id), do: false

  defp role_of(member_by_user_id, user_id) do
    case Map.get(member_by_user_id, user_id) do
      %{role: role} -> role
      _no_membership -> nil
    end
  end

  def list_reaction_summaries(%Scope{user: %User{}}, []), do: {:ok, %{}}

  def list_reaction_summaries(%Scope{user: %User{id: user_id}}, message_ids)
      when is_list(message_ids) do
    message_ids = Enum.uniq(message_ids)

    with :ok <- authorize_accessible_messages(message_ids, user_id) do
      summaries =
        MessageReaction
        |> where([reaction], reaction.message_id in type(^message_ids, {:array, :binary_id}))
        |> group_by([reaction], [reaction.message_id, reaction.emoji])
        |> order_by([reaction], asc: reaction.message_id, asc: reaction.emoji)
        |> select([reaction], %{
          message_id: reaction.message_id,
          emoji: reaction.emoji,
          count: count(reaction.id),
          reacted?: fragment("bool_or(? = ?)", reaction.user_id, type(^user_id, :binary_id))
        })
        |> Repo.all()
        |> Enum.group_by(& &1.message_id, fn summary ->
          %{emoji: summary.emoji, count: summary.count, reacted?: summary.reacted?}
        end)

      {:ok, summaries}
    end
  end

  def list_reaction_summaries(_scope, _message_ids), do: {:error, :unauthenticated}

  defp get_member_channel(channel_id, user_id) do
    UUIDIdentifier.cast_or(channel_id, nil, fn channel_id ->
      Repo.one(
        from channel in Channel,
          join: membership in WorkspaceMembership,
          on:
            membership.workspace_id == channel.workspace_id and
              membership.user_id == ^user_id,
          where: channel.id == ^channel_id,
          limit: 1,
          preload: [:conversation]
      )
    end)
  end

  defp get_member_message(message_id, user_id) do
    UUIDIdentifier.cast_or(message_id, nil, fn message_id ->
      Repo.one(
        from message in Message,
          join: channel in Channel,
          on: channel.id == message.channel_id,
          join: membership in WorkspaceMembership,
          on:
            membership.workspace_id == channel.workspace_id and
              membership.user_id == ^user_id,
          where: message.id == ^message_id,
          limit: 1,
          preload: [channel: channel]
      )
    end)
  end

  defp get_accessible_message(message_id, user_id) do
    case get_member_message(message_id, user_id) do
      %Message{} = message ->
        {:channel, message}

      nil ->
        case get_direct_participant_message(message_id, user_id) do
          {message, direct_conversation} -> {:direct, message, direct_conversation}
          nil -> nil
        end
    end
  end

  defp get_direct_participant_message(message_id, user_id) do
    UUIDIdentifier.cast_or(message_id, nil, fn message_id ->
      Repo.one(
        from message in Message,
          join: direct_conversation in DirectConversation,
          on: direct_conversation.id == message.channel_id,
          where:
            message.id == ^message_id and
              (direct_conversation.user_low_id == ^user_id or
                 direct_conversation.user_high_id == ^user_id),
          select: {message, direct_conversation},
          limit: 1
      )
    end)
  end

  defp redact_deleted_direct_message(%Message{} = message) do
    reply_to_message = redact_deleted_reply_target(message.reply_to_message)
    message = %{message | reply_to_message: reply_to_message}

    if is_nil(message.deleted_at), do: message, else: %{message | content: nil}
  end

  defp redact_deleted_reply_target(%Message{deleted_at: %DateTime{}} = message),
    do: %{message | content: nil}

  defp redact_deleted_reply_target(message), do: message

  defp redact_direct_message_window(%{messages: messages} = window) do
    Map.put(window, :messages, Enum.map(messages, &redact_deleted_direct_message/1))
  end

  defp get_live_direct_message(direct_conversation_id, message_id) do
    UUIDIdentifier.cast_or(message_id, nil, fn message_id ->
      Repo.one(
        from message in Message,
          where:
            message.id == ^message_id and
              message.channel_id == ^direct_conversation_id and
              is_nil(message.deleted_at),
          lock: "FOR SHARE",
          limit: 1
      )
    end)
  end

  defp get_live_channel_message(channel_id, message_id) do
    UUIDIdentifier.cast_or(message_id, nil, fn message_id ->
      Repo.one(
        from message in Message,
          where:
            message.id == ^message_id and message.channel_id == ^channel_id and
              is_nil(message.deleted_at),
          lock: "FOR SHARE",
          limit: 1
      )
    end)
  end

  defp authorize_accessible_messages(message_ids, user_id) do
    UUIDIdentifier.cast_or(message_ids, {:error, :not_found}, fn message_ids ->
      accessible_message_count =
        Repo.one(
          from message in Message,
            left_join: channel in Channel,
            on: channel.id == message.channel_id,
            left_join: membership in WorkspaceMembership,
            on:
              membership.workspace_id == channel.workspace_id and
                membership.user_id == ^user_id,
            left_join: direct_conversation in DirectConversation,
            on: direct_conversation.id == message.channel_id,
            where: message.id in type(^message_ids, {:array, :binary_id}),
            where:
              not is_nil(membership.id) or
                direct_conversation.user_low_id == ^user_id or
                direct_conversation.user_high_id == ^user_id,
            select: count(message.id)
        )

      if accessible_message_count == length(message_ids), do: :ok, else: {:error, :not_found}
    end)
  end

  defp authorize_delete_message(%Message{user_id: user_id}, user_id), do: :ok

  defp authorize_delete_message(%Message{} = message, user_id) do
    {actor, author} = actor_target_roles(message.channel.workspace_id, user_id, message.user_id)

    if Workspaces.can_delete_message?(role_of_membership(actor), role_of_membership(author)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp role_of_membership(%{role: role}), do: role
  defp role_of_membership(_no_membership), do: nil

  defp delete_message_with_optional_audit(%Message{} = message, user_id) do
    deleted_at = DateTime.utc_now(:second)

    multi =
      Multi.new()
      |> Multi.run(:activity_recipient_ids, fn repo, _changes ->
        recipient_ids =
          repo.all(
            from activity_item in ActivityItem,
              where: activity_item.source_message_id == ^message.id,
              select: activity_item.recipient_user_id,
              distinct: true
          )

        {:ok, recipient_ids}
      end)
      |> Multi.delete_all(
        :activity_items,
        from(activity_item in ActivityItem,
          where: activity_item.source_message_id == ^message.id
        )
      )
      |> Multi.delete_all(
        :reactions,
        from(reaction in MessageReaction, where: reaction.message_id == ^message.id)
      )
      |> Multi.update(
        :message,
        Message.soft_delete_changeset(message, %{
          deleted_at: deleted_at,
          deleted_by_user_id: user_id
        })
      )
      |> maybe_insert_message_delete_audit(message, user_id)

    case Repo.transaction(multi) do
      {:ok, %{message: message, activity_recipient_ids: activity_recipient_ids}} ->
        message = Repo.preload(message, :user)
        :ok = Runtime.put_recent_message(message)
        :ok = broadcast_message_deleted(message)

        :ok =
          broadcast_activity_changes(activity_recipient_ids, %{
            action: :removed,
            source_message_id: message.id
          })

        {:ok, message}

      {:error, :message, changeset, _changes_so_far} ->
        {:error, :invalid_message, changeset}

      {:error, :audit_event, changeset, _changes_so_far} ->
        {:error, :invalid_audit_event, changeset}
    end
  end

  defp maybe_insert_message_delete_audit(%Multi{} = multi, %Message{user_id: user_id}, user_id),
    do: multi

  defp maybe_insert_message_delete_audit(%Multi{} = multi, %Message{} = message, actor_user_id) do
    Multi.insert(multi, :audit_event, fn %{message: deleted_message} ->
      WorkspaceAuditEvent.changeset(%WorkspaceAuditEvent{}, %{
        workspace_id: message.channel.workspace_id,
        actor_user_id: actor_user_id,
        target_user_id: message.user_id,
        event_type: "moderator_message_deleted",
        metadata: %{
          "message_id" => deleted_message.id,
          "channel_id" => deleted_message.channel_id,
          "channel_name" => message.channel.name
        }
      })
    end)
  end

  defp actor_target_roles(workspace_id, actor_user_id, target_user_id) do
    memberships =
      Repo.all(
        from membership in WorkspaceMembership,
          where:
            membership.workspace_id == ^workspace_id and
              membership.user_id in ^[actor_user_id, target_user_id],
          select: {membership.user_id, membership}
      )
      |> Map.new()

    {Map.get(memberships, actor_user_id), Map.get(memberships, target_user_id)}
  end

  defp reject_deleted_message(%Message{deleted_at: %DateTime{}}), do: {:error, :message_deleted}
  defp reject_deleted_message(%Message{}), do: :ok

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

  defp lock_conversation_for_update!(conversation_id) do
    Repo.one!(
      from conversation in Conversation,
        where: conversation.id == ^conversation_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_channel_anchor(%Channel{} = channel, anchor_seq) when is_integer(anchor_seq) do
    if anchor_seq >= 1 and anchor_seq <= channel.conversation.last_message_seq do
      :ok
    else
      {:error, :invalid_sequence}
    end
  end

  defp broadcast_message_created(%Message{} = message) do
    Phoenix.PubSub.broadcast_from(
      DiscordClone.PubSub,
      self(),
      ConversationTopics.messages(message.channel_id),
      {:message_created, message}
    )
  end

  defp broadcast_direct_message_created(%Message{} = message) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      ConversationTopics.messages(message.channel_id),
      {:direct_message_created,
       %{conversation_id: message.channel_id, message_id: message.id, seq: message.seq}}
    )
  end

  defp broadcast_message_deleted(%Message{} = message) do
    Phoenix.PubSub.broadcast_from(
      DiscordClone.PubSub,
      self(),
      ConversationTopics.messages(message.channel_id),
      {:message_deleted, %{conversation_id: message.channel_id, message_id: message.id}}
    )
  end

  defp workspace_messages_topic(workspace_id), do: "chat:workspace:#{workspace_id}:messages"

  defp broadcast_activity_change(user_id, payload) do
    Topics.broadcast_change(user_id, payload)
  end

  defp broadcast_activity_changes(user_ids, payload) do
    Enum.each(Enum.uniq(user_ids), fn user_id ->
      :ok = broadcast_activity_change(user_id, payload)
    end)

    :ok
  end

  defp broadcast_direct_navigation_changed(user_id, payload) do
    ConversationTopics.broadcast_direct_navigation_change(user_id, payload)
  end

  defp broadcast_reaction_changed(%Message{} = message, emoji) do
    Phoenix.PubSub.broadcast_from(
      DiscordClone.PubSub,
      self(),
      ConversationTopics.reactions(message.channel_id),
      {:reaction_changed, %{message_id: message.id, emoji: emoji}}
    )
  end

  defp broadcast_workspace_message_created(workspace_id, %Message{} = message) do
    Phoenix.PubSub.broadcast(
      DiscordClone.PubSub,
      workspace_messages_topic(workspace_id),
      {:workspace_message_created,
       %{
         workspace_id: workspace_id,
         channel_id: message.channel_id,
         message_id: message.id,
         user_id: message.user_id
       }}
    )
  end
end

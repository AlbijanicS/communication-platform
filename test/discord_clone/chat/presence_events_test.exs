defmodule DiscordClone.Chat.PresenceEventsTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Chat.PresenceEvents

  describe "workspace presence event contract" do
    test "builds and translates joined and left events" do
      workspace_id = 123
      user_id = 456

      joined_event = {:workspace_user_joined, %{workspace_id: workspace_id, user_id: user_id}}
      left_event = {:workspace_user_left, %{workspace_id: workspace_id, user_id: user_id}}

      assert PresenceEvents.user_joined_event(workspace_id, user_id) == joined_event
      assert PresenceEvents.user_left_event(workspace_id, user_id) == left_event

      assert PresenceEvents.to_presence_event(joined_event) ==
               {:ok, :user_joined, elem(joined_event, 1)}

      assert PresenceEvents.to_presence_event(left_event) ==
               {:ok, :user_left, elem(left_event, 1)}

      assert PresenceEvents.to_presence_event({:other_event, %{}}) == :error
    end
  end
end

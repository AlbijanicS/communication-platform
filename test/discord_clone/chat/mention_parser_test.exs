defmodule DiscordClone.Chat.MentionParserTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Chat.MentionParser

  describe "usernames/1" do
    test "recognizes mentions at text boundaries beside punctuation case-insensitively" do
      content = "@Alpha, please pair with (@BETA_2). End with @gamma3"

      assert MentionParser.usernames(content) == ["alpha", "beta_2", "gamma3"]
    end

    test "ignores email-like text, embedded handles, malformed names, and duplicates" do
      content =
        "alpha@example.com prefix@member @@other @ab @member @MEMBER @name-with-dash"

      assert MentionParser.usernames(content) == ["member", "name"]
    end

    test "returns no candidates for non-text content" do
      assert MentionParser.usernames(nil) == []
    end
  end
end

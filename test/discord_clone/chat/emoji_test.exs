defmodule DiscordClone.Chat.EmojiTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Chat.Emoji

  describe "validate_reaction/1" do
    test "accepts one direct Unicode emoji" do
      assert Emoji.validate_reaction("👍") == {:ok, "👍"}
    end

    test "accepts one composed Unicode emoji grapheme" do
      assert Emoji.validate_reaction("👍🏽") == {:ok, "👍🏽"}
    end

    test "trims and normalizes the reaction value" do
      decomposed_e_acute = "e\u0301"

      assert Emoji.validate_reaction(" #{decomposed_e_acute} ") == {:ok, "é"}
    end

    test "rejects blank reaction values" do
      assert Emoji.validate_reaction("   ") == {:error, :blank}
    end

    test "rejects values with more than one grapheme" do
      assert Emoji.validate_reaction("👍🔥") == {:error, :multiple_graphemes}
    end

    test "rejects oversized reaction values" do
      assert Emoji.validate_reaction(String.duplicate("a", 65)) == {:error, :too_long}
    end

    test "rejects malformed binary reaction values" do
      assert Emoji.validate_reaction(<<255>>) == {:error, :invalid}
    end

    test "rejects non-binary reaction values" do
      assert Emoji.validate_reaction(nil) == {:error, :invalid}
    end
  end

  describe "render_shortcodes/1" do
    test "replaces supported shortcodes with emoji" do
      assert Emoji.render_shortcodes("ship it :thumbsup: :heart:") == "ship it 👍 ❤️"
    end

    test "leaves unknown shortcodes unchanged" do
      assert Emoji.render_shortcodes("deploying :rocketship:") == "deploying :rocketship:"
    end
  end
end

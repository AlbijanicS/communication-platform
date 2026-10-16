defmodule DiscordClone.UUIDIdentifierTest do
  use ExUnit.Case, async: true

  alias DiscordClone.UUIDIdentifier

  @valid Ecto.UUID.generate()
  @other Ecto.UUID.generate()

  describe "cast_or/3 with a single value" do
    test "runs the function with the cast identifier and returns its result" do
      assert UUIDIdentifier.cast_or(@valid, :fallback, fn id ->
               assert id == @valid
               {:ok, id}
             end) == {:ok, @valid}
    end

    test "returns the fallback without calling the function for an invalid identifier" do
      assert UUIDIdentifier.cast_or("not-a-uuid", :fallback, fn _ ->
               flunk("function should not run for an invalid identifier")
             end) == :fallback
    end
  end

  describe "cast_or/3 with a list of values" do
    test "runs the function with all cast identifiers when every value is valid" do
      assert UUIDIdentifier.cast_or([@valid, @other], nil, fn ids ->
               assert ids == [@valid, @other]
               ids
             end) == [@valid, @other]
    end

    test "returns the fallback if any value in the list is invalid" do
      assert UUIDIdentifier.cast_or([@valid, "nope"], nil, fn _ ->
               flunk("function should not run when a list value is invalid")
             end) == nil
    end
  end
end

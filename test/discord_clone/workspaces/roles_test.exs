defmodule DiscordClone.Workspaces.RolesTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Workspaces.Roles

  describe "vocabulary" do
    test "exposes the three Role values" do
      assert Roles.owner() == "owner"
      assert Roles.admin() == "admin"
      assert Roles.member() == "member"
    end

    test "all/0 is the full ordered set of Role values" do
      assert Roles.all() == ["owner", "admin", "member"]
    end
  end

  describe "predicates" do
    test "owner?/1 only matches the owner Role" do
      assert Roles.owner?("owner")
      refute Roles.owner?("admin")
      refute Roles.owner?("member")
      refute Roles.owner?(nil)
    end

    test "admin?/1 only matches the admin Role" do
      assert Roles.admin?("admin")
      refute Roles.admin?("owner")
      refute Roles.admin?("member")
      refute Roles.admin?(nil)
    end

    test "member?/1 only matches the member Role" do
      assert Roles.member?("member")
      refute Roles.member?("owner")
      refute Roles.member?("admin")
      refute Roles.member?(nil)
    end
  end

  describe "can_moderate?/2" do
    test "owners and admins may moderate admins and members" do
      assert Roles.can_moderate?("owner", "admin")
      assert Roles.can_moderate?("owner", "member")
      assert Roles.can_moderate?("admin", "admin")
      assert Roles.can_moderate?("admin", "member")
    end

    test "nobody may moderate an owner" do
      refute Roles.can_moderate?("owner", "owner")
      refute Roles.can_moderate?("admin", "owner")
    end

    test "members may not moderate anyone" do
      refute Roles.can_moderate?("member", "member")
      refute Roles.can_moderate?("member", "admin")
    end

    test "absent Roles never moderate" do
      refute Roles.can_moderate?(nil, "member")
      refute Roles.can_moderate?("owner", nil)
    end
  end
end

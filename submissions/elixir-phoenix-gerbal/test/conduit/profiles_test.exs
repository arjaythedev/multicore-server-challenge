defmodule Conduit.ProfilesTest do
  use Conduit.DataCase, async: true

  alias Conduit.Profiles

  setup do
    %{alice: user_fixture(), bob: user_fixture()}
  end

  test "following is per viewer", %{alice: alice, bob: bob} do
    assert {:ok, %{following: false}} = Profiles.get_profile(bob.username, alice.id)
    assert {:ok, %{following: true}} = Profiles.follow(alice.id, bob.username)
    assert {:ok, %{following: true}} = Profiles.get_profile(bob.username, alice.id)
    assert {:ok, %{following: false}} = Profiles.get_profile(alice.username, bob.id)
    assert {:ok, %{following: false}} = Profiles.get_profile(bob.username, nil)
  end

  test "follow and unfollow are idempotent", %{alice: alice, bob: bob} do
    assert {:ok, _} = Profiles.follow(alice.id, bob.username)
    assert {:ok, _} = Profiles.follow(alice.id, bob.username)
    assert {:ok, %{following: false}} = Profiles.unfollow(alice.id, bob.username)
    assert {:ok, %{following: false}} = Profiles.unfollow(alice.id, bob.username)
    assert {:ok, %{following: false}} = Profiles.get_profile(bob.username, alice.id)
  end

  test "unknown users are not found", %{alice: alice} do
    assert {:error, :not_found} = Profiles.get_profile("nobody-here", nil)
    assert {:error, :not_found} = Profiles.follow(alice.id, "nobody-here")
    assert {:error, :not_found} = Profiles.unfollow(alice.id, "nobody-here")
  end
end

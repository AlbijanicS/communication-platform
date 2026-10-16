defmodule DiscordClone.Voice.ICEProviders.CloudflareTest do
  use ExUnit.Case, async: true

  alias DiscordClone.Voice.ICEProviders.Cloudflare

  test "exchanges the server-side TURN key for one bounded temporary authorization" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/turn/keys/key-123/credentials/generate-ice-servers"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer durable-secret"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"ttl" => 3_600}

      conn
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{
        "iceServers" => [
          %{"urls" => ["stun:stun.cloudflare.com:3478"]},
          %{
            "urls" => [
              "turn:turn.cloudflare.com:3478?transport=udp",
              "turn:turn.cloudflare.com:3478?transport=tcp",
              "turns:turn.cloudflare.com:5349?transport=tcp"
            ],
            "username" => "temporary-user",
            "credential" => "temporary-password"
          }
        ]
      })
    end)

    before_request = DateTime.utc_now(:second)

    assert {:ok, authorization} =
             Cloudflare.resolve(
               key_id: "key-123",
               secret: "durable-secret",
               ttl_seconds: 3_600,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert authorization.urls == [
             "turn:turn.cloudflare.com:3478?transport=udp",
             "turn:turn.cloudflare.com:3478?transport=tcp",
             "turns:turn.cloudflare.com:5349?transport=tcp"
           ]

    assert authorization.username == "temporary-user"
    assert authorization.credential == "temporary-password"
    assert DateTime.diff(authorization.expires_at, before_request, :second) in 3_599..3_601
  end

  test "normalizes an unsuccessful response without retrying or exposing its body" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(:too_many_requests)
      |> Req.Test.json(%{"sensitive_provider_detail" => "must-not-cross-boundary"})
    end)

    assert {:error, :unsuccessful_status} =
             Cloudflare.resolve(
               key_id: "key-123",
               secret: "durable-secret",
               ttl_seconds: 3_600,
               req_options: [plug: {Req.Test, __MODULE__}, retry: :transient]
             )

    Req.Test.verify!(__MODULE__)
  end

  test "rejects malformed credential responses" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{"iceServers" => [%{"urls" => ["stun:example.test"]}]})
    end)

    assert {:error, :invalid_response} =
             Cloudflare.resolve(
               key_id: "key-123",
               secret: "durable-secret",
               ttl_seconds: 3_600,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "rejects invalid local options without making a request" do
    assert {:error, :invalid_response} = Cloudflare.resolve([])

    assert {:error, :invalid_response} =
             Cloudflare.resolve(key_id: "key-123", secret: "secret", ttl_seconds: 59)
  end
end

defmodule DiscordCloneWeb.CallSignalingBootstrapTest do
  use DiscordCloneWeb.ConnCase, async: true

  import DiscordClone.AccountsFixtures

  test "anonymous pages do not render the call signaling bootstrap marker", %{conn: conn} do
    document =
      conn
      |> get(~p"/users/log-in")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#call-signaling-bootstrap") |> Enum.empty?()
    assert document |> LazyHTML.query(~s(meta[name="call-signaling"])) |> Enum.empty?()
  end

  test "authenticated pages render a token-free bootstrap marker", %{conn: conn} do
    user = user_fixture()
    conn = conn |> log_in_user(user) |> get(~p"/friends")
    document = conn |> html_response(200) |> LazyHTML.from_fragment()
    token = get_session(conn, :user_token)

    marker = LazyHTML.query(document, "#call-signaling-bootstrap")
    assert LazyHTML.attribute(marker, "id") == ["call-signaling-bootstrap"]
    assert LazyHTML.attribute(marker, "name") == ["call-signaling"]
    assert LazyHTML.attribute(marker, "content") == ["authenticated"]

    contents = document |> LazyHTML.query("meta") |> LazyHTML.attribute("content")
    refute to_string(user.id) in contents
    refute user.email in contents
    refute Base.url_encode64(token) in contents
  end

  test "anonymous pages do not render the global Direct Call dock", %{conn: conn} do
    document =
      conn
      |> get(~p"/users/log-in")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("#direct-call-dock") |> Enum.empty?()
    assert document |> LazyHTML.query("#direct-call-dock-status") |> Enum.empty?()
    assert document |> LazyHTML.query("#direct-call-incoming-backdrop") |> Enum.empty?()
    assert document |> LazyHTML.query("#direct-call-incoming-dialog") |> Enum.empty?()
  end

  test "global call surfaces render no fake media controls or device selectors", %{conn: conn} do
    user = user_fixture()

    document =
      conn
      |> log_in_user(user)
      |> get(~p"/friends")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    dock = LazyHTML.query(document, "#direct-call-dock")
    refute LazyHTML.attribute(dock, "aria-modal") == ["true"]

    remote = LazyHTML.query(document, "#direct-call-remote-video")
    assert LazyHTML.attribute(remote, "muted") == [""]
    assert LazyHTML.attribute(remote, "playsinline") == [""]

    selectors = [
      "video:not(#direct-call-local-preview):not(#direct-call-incoming-preview):not(#direct-call-remote-video)",
      "audio",
      "select",
      "input",
      "[data-call-action='mute']",
      "[data-call-action='deafen']",
      "[data-call-action='camera']"
    ]

    for surface <- ["#direct-call-dock", "#direct-call-incoming-backdrop"],
        selector <- selectors do
      assert document |> LazyHTML.query("#{surface} #{selector}") |> Enum.empty?(),
             "#{surface} rendered #{selector}"
    end
  end

  test "participant areas are named and preserve the existing muted video elements", %{conn: conn} do
    document =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/friends")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    group = LazyHTML.query(document, "#direct-call-participants")
    assert Enum.count(group) == 1

    for {region, label} <- [
          {"direct-call-remote-video", "direct-call-remote-video-name"},
          {"direct-call-local-preview", "direct-call-local-preview-name"}
        ] do
      area = LazyHTML.query(group, "##{region}-region")
      assert LazyHTML.attribute(area, "aria-labelledby") == [label]
      assert Enum.count(LazyHTML.query(area, "##{region}-placeholder")) == 1
      assert Enum.count(LazyHTML.query(area, "##{label}")) == 1
      assert Enum.count(LazyHTML.query(area, "video")) == 1
    end
  end

  test "authenticated pages render one global Direct Call dock outside LiveView content", %{
    conn: conn
  } do
    user = user_fixture()

    document =
      conn
      |> log_in_user(user)
      |> get(~p"/friends")
      |> html_response(200)
      |> LazyHTML.from_fragment()

    dock = LazyHTML.query(document, "#direct-call-dock")
    assert LazyHTML.attribute(dock, "id") == ["direct-call-dock"]
    assert LazyHTML.attribute(dock, "aria-label") == ["Direct Call"]
    assert LazyHTML.attribute(dock, "data-call-dock-state") == ["idle"]
    assert document |> LazyHTML.query("[data-phx-main] #direct-call-dock") |> Enum.empty?()

    return_link = LazyHTML.query(dock, "#direct-call-dock-return")
    assert LazyHTML.attribute(return_link, "data-phx-link") == ["redirect"]
    assert LazyHTML.attribute(return_link, "hidden") == [""]

    assert document |> LazyHTML.query("#direct-call-page-content [data-phx-main]") |> Enum.count() ==
             1

    preview = LazyHTML.query(dock, "#direct-call-local-preview")
    assert LazyHTML.attribute(preview, "id") == ["direct-call-local-preview"]

    for attribute <- ~w(muted autoplay playsinline) do
      assert LazyHTML.attribute(preview, attribute) == [""]
    end

    assert LazyHTML.attribute(preview, "aria-label") == ["Your local camera preview"]
    assert LazyHTML.attribute(preview, "src") == []
    assert LazyHTML.attribute(preview, "tabindex") == ["-1"]

    assert LazyHTML.attribute(
             LazyHTML.query(dock, "#direct-call-local-preview-region"),
             "hidden"
           ) == [""]

    preview_status = LazyHTML.query(dock, "#direct-call-local-preview-status")
    assert LazyHTML.attribute(preview_status, "role") == ["status"]
    assert LazyHTML.attribute(preview_status, "aria-live") == ["off"]
    assert LazyHTML.text(preview_status) =~ "Camera is not sending video yet."

    status = LazyHTML.query(dock, "#direct-call-dock-status")
    assert LazyHTML.attribute(status, "id") == ["direct-call-dock-status"]
    assert LazyHTML.attribute(status, "role") == ["status"]
    assert LazyHTML.attribute(status, "aria-live") == ["polite"]
    assert String.trim(LazyHTML.text(status)) == ""

    media_status = LazyHTML.query(dock, "#direct-call-dock-media-state")
    assert LazyHTML.attribute(media_status, "role") == ["status"]
    assert LazyHTML.attribute(media_status, "aria-live") == ["polite"]
    assert LazyHTML.attribute(media_status, "hidden") == [""]
    assert String.trim(LazyHTML.text(media_status)) == ""

    for id <-
          ~w(direct-call-dock-cancel direct-call-dock-leave direct-call-dock-retry direct-call-dock-dismiss direct-call-dock-start-voice-instead direct-call-dock-deafen direct-call-dock-enable-audio direct-call-dock-camera) do
      control = LazyHTML.query(dock, "##{id}")
      assert LazyHTML.attribute(control, "id") == [id]
      assert LazyHTML.attribute(control, "type") == ["button"]
    end

    fallback = LazyHTML.query(dock, "#direct-call-dock-start-voice-instead")
    assert LazyHTML.attribute(fallback, "data-call-action") == ["fallback-audio"]
    assert String.trim(LazyHTML.text(fallback)) == "Start audio call instead"

    camera = LazyHTML.query(dock, "#direct-call-dock-camera")
    assert LazyHTML.attribute(camera, "data-call-action") == ["toggle-camera"]
    assert LazyHTML.attribute(camera, "aria-label") == ["Turn camera on"]
    assert LazyHTML.attribute(camera, "aria-pressed") == []
    assert LazyHTML.attribute(camera, "data-active") == ["false"]
    assert LazyHTML.attribute(camera, "hidden") == [""]

    preview_toggle = LazyHTML.query(dock, "#direct-call-dock-preview")
    size_toggle = LazyHTML.query(dock, "#direct-call-dock-size")
    assert LazyHTML.attribute(size_toggle, "data-call-action") == ["toggle-size"]
    assert LazyHTML.attribute(size_toggle, "aria-controls") == ["direct-call-participants"]
    assert LazyHTML.attribute(size_toggle, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(size_toggle, "aria-pressed") == []
    assert LazyHTML.attribute(size_toggle, "hidden") == [""]
    assert LazyHTML.attribute(preview_toggle, "data-call-action") == ["toggle-preview"]

    assert LazyHTML.attribute(preview_toggle, "aria-controls") == [
             "direct-call-local-preview-region"
           ]

    assert LazyHTML.attribute(preview_toggle, "aria-pressed") == []
    assert LazyHTML.attribute(preview_toggle, "hidden") == [""]

    self_status = LazyHTML.query(dock, "#direct-call-self-camera-status")
    assert LazyHTML.attribute(self_status, "role") == []
    assert LazyHTML.attribute(self_status, "aria-live") == ["off"]

    assert dock
           |> LazyHTML.query("#direct-call-local-preview-region #direct-call-dock-preview")
           |> Enum.empty?()

    assert dock
           |> LazyHTML.query("#direct-call-local-preview-region #direct-call-self-camera-status")
           |> Enum.empty?()

    assert document |> LazyHTML.query("#direct-call-camera-unavailable-reason") |> Enum.count() ==
             1

    deafen = LazyHTML.query(dock, "#direct-call-dock-deafen")
    assert LazyHTML.attribute(deafen, "data-call-action") == ["toggle-deafen"]
    assert LazyHTML.attribute(deafen, "aria-label") == ["Deafen audio"]
    assert LazyHTML.attribute(deafen, "aria-pressed") == []
    assert LazyHTML.attribute(deafen, "data-active") == ["false"]

    enable_audio = LazyHTML.query(dock, "#direct-call-dock-enable-audio")
    assert LazyHTML.attribute(enable_audio, "data-call-action") == ["enable-audio"]
    assert LazyHTML.attribute(enable_audio, "aria-label") == ["Play call audio"]
    assert String.trim(LazyHTML.text(enable_audio)) == "Play audio"

    title = LazyHTML.query(dock, "#direct-call-dock-title")
    assert String.trim(LazyHTML.text(title)) == "Voice call"
    assert LazyHTML.attribute(title, "tabindex") == ["-1"]

    backdrop = LazyHTML.query(document, "#direct-call-incoming-backdrop")
    assert LazyHTML.attribute(backdrop, "id") == ["direct-call-incoming-backdrop"]

    assert document
           |> LazyHTML.query("[data-phx-main] #direct-call-incoming-backdrop")
           |> Enum.empty?()

    dialog = LazyHTML.query(backdrop, "#direct-call-incoming-dialog")
    assert LazyHTML.attribute(dialog, "role") == ["dialog"]
    assert LazyHTML.attribute(dialog, "aria-modal") == ["true"]
    assert LazyHTML.attribute(dialog, "aria-labelledby") == ["direct-call-incoming-title"]

    cancel_preparation = LazyHTML.query(dialog, "#direct-call-incoming-cancel-preparation")
    assert LazyHTML.attribute(cancel_preparation, "data-call-action") == ["cancel"]
    assert LazyHTML.attribute(cancel_preparation, "aria-label") == ["Cancel device preparation"]
    assert LazyHTML.attribute(cancel_preparation, "hidden") == [""]

    preview = LazyHTML.query(dialog, "#direct-call-incoming-preview")
    assert LazyHTML.attribute(preview, "id") == ["direct-call-incoming-preview"]
    assert LazyHTML.attribute(preview, "aria-label") == ["Your local camera preview"]
    assert LazyHTML.attribute(preview, "muted") == [""]
    assert LazyHTML.attribute(preview, "playsinline") == [""]

    assert LazyHTML.attribute(
             LazyHTML.query(dialog, "#direct-call-incoming-preview-region"),
             "hidden"
           ) == [""]

    described_by = dialog |> LazyHTML.attribute("aria-describedby") |> List.first()
    assert described_by =~ "direct-call-incoming-caller"
    assert described_by =~ "direct-call-incoming-intent"
    assert described_by =~ "direct-call-incoming-status"

    for id <-
          ~w(direct-call-incoming-title direct-call-incoming-caller direct-call-incoming-intent direct-call-incoming-status direct-call-incoming-accept-audio direct-call-incoming-accept-video direct-call-incoming-answer-without-video direct-call-incoming-decline) do
      assert LazyHTML.attribute(LazyHTML.query(dialog, "##{id}"), "id") == [id]
    end

    assert LazyHTML.attribute(
             LazyHTML.query(dialog, "#direct-call-incoming-status"),
             "aria-live"
           ) == ["polite"]

    assert LazyHTML.attribute(
             LazyHTML.query(dialog, "#direct-call-incoming-accept-audio"),
             "data-call-action"
           ) == ["accept-audio"]

    assert LazyHTML.attribute(
             LazyHTML.query(dialog, "#direct-call-incoming-accept-video"),
             "data-call-action"
           ) == ["accept-video"]

    assert LazyHTML.attribute(
             LazyHTML.query(dialog, "#direct-call-incoming-answer-without-video"),
             "data-call-action"
           ) == ["answer-without-video"]

    assert LazyHTML.attribute(
             LazyHTML.query(dialog, "#direct-call-incoming-decline"),
             "data-call-action"
           ) == ["decline"]
  end
end

defmodule DiscordCloneWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DiscordCloneWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    <.flash_group flash={@flash} />
    """
  end

  @doc "Renders the local-only Call camera preview for a persistent presentation surface."
  attr :id, :string, required: true

  attr :participant, :boolean, default: false

  def call_preview(assigns) do
    ~H"""
    <figure
      id={@id <> "-region"}
      hidden
      aria-labelledby={@participant && @id <> "-name"}
      class="mt-3"
    >
      <div class={[@participant && "call-participant-picture"]}>
        <video
          id={@id}
          autoplay
          muted
          playsinline
          tabindex="-1"
          aria-label="Your local camera preview"
          aria-describedby={@id <> "-status"}
          class={[
            "-scale-x-100 object-contain",
            if(@participant,
              do: "absolute inset-0 size-full",
              else: "aspect-video w-full rounded-xl bg-base-300"
            )
          ]}
        >
        </video>
        <div :if={@participant} id={@id <> "-placeholder"} class="call-participant-placeholder">
          <span class="call-participant-avatar" aria-hidden="true">
            <.icon name="hero-user" class="size-5" />
          </span>
          <.icon name="hero-video-camera-slash" class="size-4" />
        </div>
      </div>
      <p :if={@participant} id={@id <> "-name"} class="mt-2 text-xs font-semibold">
        You <span class="call-participant-status">· Self-preview</span>
      </p>
      <figcaption
        id={@id <> "-status"}
        role="status"
        aria-live="off"
        class="call-participant-status"
      >
        Local preview. Camera is not sending video yet.
      </figcaption>
      <button
        id={@id <> "-retry"}
        type="button"
        data-call-action="retry-preview"
        hidden
        class={[
          "mt-2 inline-flex h-9 items-center rounded-xl px-3 text-xs font-semibold",
          "ring-1 ring-base-content/20 transition hover:bg-base-content/10",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
        ]}
      >
        Try preview again
      </button>
    </figure>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end

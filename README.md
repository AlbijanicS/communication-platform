# Communication & Social Platform

A Discord-inspired communication platform built with Elixir and Phoenix LiveView. Developed independently over three months as an internship project, from the database and OTP processes to the interface and deployment.

- Workspaces, text channels, roles, invitations, and moderation.
- Real-time messages, replies, reactions, mentions, and unread activity.
- Friend requests, online presence, and direct messages.
- Voice channels and one-to-one audio/video calls with server-routed WebRTC.
- Password authentication and operator-provisioned accounts.

**Stack:** Elixir · Phoenix LiveView · PostgreSQL · Ecto · JavaScript · Tailwind CSS · ExWebRTC

A hosted demo is available. The application link and two demo accounts are shared privately on request.

## Run locally

Requires Elixir 1.19 / Erlang OTP 28, PostgreSQL 16+, and Node.js 22+. PostgreSQL should be running locally with the development credentials in `config/dev.exs` (`postgres` / `postgres`); adjust those locally if needed.

```sh
git clone https://github.com/AlbijanicS/communication-platform.git
cd communication-platform
mix setup
```

Create a local account; choose your own password of at least 12 characters:

```sh
read -s DISCORD_CLONE_USER_PASSWORD
export DISCORD_CLONE_USER_PASSWORD
mix discord_clone.provision_user you@example.com your_username
unset DISCORD_CLONE_USER_PASSWORD
mix phx.server
```

Open [localhost:4000](http://localhost:4000). Public registration is disabled; provision a second account the same way to try friendships and calls using separate browser profiles. Local calls need no hosted TURN credentials. Calls across different networks require HTTPS and STUN/TURN configuration; the hosted demo provides this. Desktop Chrome is the tested video client.

## Checks

```sh
mix precommit
```

Runs compilation, formatting, strict lint, JavaScript tests, and Elixir tests, including real encrypted-media integration tests. On macOS, if the native SRTP library cannot find Homebrew OpenSSL, run with `ERL_AFLAGS='-env DYLD_LIBRARY_PATH /opt/homebrew/opt/openssl@3/lib'`.

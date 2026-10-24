# fxclip for Telegram

Clean links, ready to share. fxclip is a self-hosted Telegram bot that removes tracking
from links and optionally improves X, Instagram and Reddit previews, without requiring group
members to install a client. Menus support English and French. Run your own instance
using the [Docker setup](#docker-setup); this project does not configure a public bot.

## Choose your behavior

Open the bot privately and press **Start** or send `/settings`. Buttons show the
current selection:

- **Reply to the message** keeps the original and replies with the cleaned text.
  Telegram's reply header already identifies the author; no extra credit line.
- **Replace the message** reposts the text with “Posted by …”, then deletes the
  original only after Telegram confirms the repost. Without deletion permission,
  or for media, forwards and anonymous senders, it replies instead.
- **Secretary · private chats** edits your own outgoing messages in connected
  private chats. It does not change group messages.
- **Turn off fxclip** leaves your messages untouched.
- **Follow the group's setting** removes your personal override.

Priority: **personal choice → group mode → global default**. A group must first
have cleaning enabled; disabling that activation stops all automatic cleaning,
including personal overrides. The group's `off` mode is a default that a personal
mode can override while cleaning remains enabled.

The owner chooses the global default with `/default` and manages discovered
groups with `/groups`. Group admins can use **Group settings**, `/setup` or
`/fxclip` to activate and configure only their own chat. Every action checks
current permissions. They cannot change global defaults, other groups or another
member's preferences. A short join greeting links everyone to their settings.
Once the group settings panel is confirmed sent, `/setup` (or bare `/fxclip`)
is removed if the bot has permission to delete it. Without that permission,
the command stays; closing the panel never removes other messages.

Commands remain available: `/mode reply|replace|secretary|off|default`,
`/fxclip reply|replace|off`, and `/fxclip previews on|off`.

## Preview links

Group admins can enable or disable enhanced previews in `/setup` or with
`/fxclip previews on|off`. When enabled, X, Instagram and Reddit links can use
`fxtwitter.com`, `zzinstagram.com` and `vxreddit.com`. Each mirror has its own switch and editable domain under **Link settings → Previews and providers**.

For a message containing only a plain YouTube video link, enhanced previews also
fetch the title and thumbnail directly from YouTube and send them with the clean
link. This includes already-clean links. Telegram's Bot API does not expose
whether its own card appeared, so a duplicate preview is possible. Turning
enhanced previews off disables these cards. Explicitly suppressed previews,
formatted or hidden links, captions and messages containing more than one link
keep their existing behavior. Secretary only edits links; it does not post cards.

Other links already prepared by a fxclip client produce no reply, repost,
deletion or edit. A tracker-free original can still become a mirror link when
previews are enabled. A clean YouTube link is never deleted just to add a card.
Metadata failures fall back to normal cleaning. Photo rejection can fall back to
cleaned text; an ambiguous send is never retried.

Bot replies include **Remove preview**. Anyone can see the button, but only the
person who posted the original link can use it; admins and the bot owner have no
override. It removes only the bot's reply. YouTube cards keep their opening
button as well. Replacement posts do not offer removal because they may be the
only remaining copy. Anonymous/channel-authored messages have no identifiable
personal owner and do not receive this control.

Removal controls keep only chat/message IDs, the poster's ID and a timestamp,
for up to 48 hours, with a limit of 4096 recent replies. Message text and links
are not stored. Ownership survives a restart and does not depend on the original
message still being available.

## Link settings

Open `/setup` in a group, then **Link settings**. Group admins can configure
global tracker removal, individual sites, cleaning exclusions, each preview
mirror and its provider, and the separate YouTube card option. The existing
group activation and preview pause switches still apply.

Members get the same link controls in private `/settings`. Without a personal
configuration, each group's choices apply. The first personal edit starts a
complete configuration from the bot defaults and applies it to that person's
messages in all enabled groups. **Follow inherited settings** removes that
custom configuration. Group custom configurations similarly replace the bot's
link defaults as a whole. Message modes remain separate.

Provider and exclusion editing uses short commands:

| Scope | Provider | Cleaning exclusion |
|---|---|---|
| Personal, in private | `/provider reddit mirror.example` | `/exclude add example.com` |
| Group, admin only | `/fxclip provider reddit mirror.example` | `/fxclip exclude add example.com` |
| Bot defaults, owner only in private | `/default provider reddit mirror.example` | `/default exclude add example.com` |

Use `default` instead of a provider domain to restore its built-in provider.
Use `remove` instead of `add` to remove an exclusion. Exclusions include
subdomains by default; append `exact` when adding one to match only that host.
These exclusions skip tracker removal; preview switches remain separate,
matching the native apps.

Provider values are domains only, without a scheme, credentials, port, path or
query. Links use HTTPS. The selected service can receive links when previews are
generated or opened. Changing a provider preserves its enabled state and does
not contact it from the settings screen.

The bot stores the same `FxEngine.UserSettings` used by the apps. `targetHost`
overrides a built-in mirror domain; `previewDefaultsEnabled` preserves the
default choice for newly added mirrors, including old installations that
declined all previews. Rule lists come from `Shared/rules.json`. Message mode,
chat activation and YouTube photo cards are Telegram-specific.

## English and French

English is the fallback language. French is fully supported, including buttons,
help, permission messages, attribution, profile text and native command menus.

In private, **Automatic** follows the user's Telegram interface `language_code`.
French variants such as `fr-FR` and `fr_CA` use French. Other nonempty tags use
English. If Telegram omits the tag, the last observed language is retained;
without one, English is used. **Language / Langue** or `/language auto|en|fr`
provides a persistent personal override. Returning to Automatic restores locale
following. Settings interactions reconcile native commands after transient API
failures, including for Automatic users.

Telegram does not supply a group-language field. Shared group menus, welcomes
and replacement attribution therefore use a stable group language: English
until an admin chooses **English** or **Français** in `/setup`. Another member's
personal language never changes that shared interface. Private callback alerts
use the clicking person's language. Command descriptions shown by Telegram follow
its locale selection; private overrides also update that private command menu.

Message content is never translated or analyzed to guess a language. Existing
modes, group activation and polling checkpoints survive the language upgrade.

## Secretary Mode

Enable **Secretary Mode** in @BotFather, then connect the bot in your account's
Telegram automation settings. Choose accessible chats and grant reply/edit
permission. Select **Secretary · private chats** in the bot's private settings.

The bot checks the current connection and rights before every edit. Only messages
sent by that connection's owner are edited; incoming messages and messages sent
by business bots remain untouched. Telegram limits `can_reply` to private chats
with incoming activity within 24 hours. Text and caption edits are supported.

## Docker setup

Use one instance per token. No public port, domain or inbound tunnel is needed:
the bot contacts Telegram over HTTPS long polling.

From the repository root:

```sh
swift test --package-path Engine
swift test --package-path Telegram
docker build --platform linux/amd64 -f Telegram/Dockerfile -t fxclip-telegram:local .
docker run --rm --platform linux/amd64 fxclip-telegram:local --check
```

Copy `compose.yaml` and `.env.example` to the server, then create `.env` from the
example. Store the token in `secrets/telegram_token`, never in the image, Git or
Compose commands. Restrict the `secrets` directory to its owner (`chmod 700`).
For non-Swarm Compose the file must be readable by container user 10001; mode
`0444` inside that private directory works. The image initializes the state volume.

Set `FXCLIP_IMAGE`, `TELEGRAM_OWNER_IDS` (numeric bot-owner IDs), and optionally
`TELEGRAM_ALLOWED_CHATS` (initial group IDs). With an empty group list, private
settings and `/chatid` work; group cleaning starts only when an admin enables it.
Saved activation overrides the initial environment list. Secretary uses separate
personal consent and the connected Telegram account's permissions.

```sh
docker compose up -d
docker compose run --rm --no-deps fxclip-telegram --check-config
docker compose logs --tail=30
```

Add the bot to the group. For replacement, grant **Delete messages** as an admin.
An admin bot receives group messages; otherwise disable Privacy Mode in
@BotFather. Suggested bot-level admin rights do not grant rights in an existing
group. The bot discovers groups on membership changes or incoming messages.
Use `/groups` privately to inspect actual rights. `/chatid` returns a group ID
in the group, or your numeric user ID in private for `TELEGRAM_OWNER_IDS`.

Startup registers English/French native descriptions and command menus. The
persistent volume retains modes, language preferences, discovered group IDs and
titles, and the polling checkpoint. Back up that volume. Message text and URLs
are never persisted or logged. Automatic container updates are disabled in the supplied
configuration: install new images explicitly.

## Real-world verification

1. Open `/settings` with French and English Telegram locales. Check Automatic,
   explicit English/French and persistence across restart.
2. Open `/setup`, choose a group language, then interact from an account with a
   different personal language. The shared panel must keep the group's language.
3. Post an X link containing `?s=1` in an enabled test group. The bot replies with
   the fxtwitter link and keeps the original, without an extra author-credit line.
4. Select replacement for your account. Only your behavior changes. Removing the
   bot's deletion permission retains the original. Check media and forwards too.
5. Select off, then follow the group setting, and confirm each outcome.
6. Connect Secretary in an eligible private test chat. Your outgoing link is
   edited in place; an incoming link stays intact. Revocation prevents edits.

## Privacy and limits

Cleaning runs locally on the server, but the bot communicates with Telegram.
Telegram receives reposted messages; mirrors can receive links when previews are
generated. The engine does not expand or visit links. No additional analytics or
external account is used. Native YouTube cards request video metadata from
YouTube's oEmbed endpoint and let Telegram fetch the YouTube thumbnail; they use
no preview mirror and do not persist metadata. Locale detection uses Telegram's supplied language tag,
never message-text analysis or an external translation service.

Unchanged links stay untouched except for enabled YouTube cards. Protected, paid,
overlong or older-than-five-minute messages are ignored. Copies queued during
downtime are not rewritten on restart. Code blocks
are left alone. Hidden links and formatting use adjusted UTF-16 entity positions.

The polling checkpoint is saved **before** each action. After an ambiguous network
response or interruption during a send, the bot does not retry that message:
the original is retained, but one cleaning can be missed. A failed deletion
leaves both the original and repost.

Revisions delivered together are coalesced. Telegram provides no atomic
compare-and-edit/delete operation: a correction typed during an outgoing request
can still be overwritten in Secretary Mode or lost during replacement. Reply
keeps the original and remains the initial default.

References: [language support](https://core.telegram.org/bots/features#language-support),
[Business bots](https://core.telegram.org/bots/features#secretary-bots),
[Business rights](https://core.telegram.org/bots/api#businessbotrights),
[deletion](https://core.telegram.org/bots/api#deletemessage).

## Shared rules

The bot reuses Swift `FxEngine` and [`Shared/rules.json`](../Shared/rules.json), the
single source of rules for every platform. Do not add site rules or cleaning logic
to the bot. Behavior changes begin in [`Shared/vectors.json`](../Shared/vectors.json),
pass the reference Swift engine, then the Android and Windows ports against the
same data. Language only affects presentation.

# fxclip for Telegram

Clean links, ready to share. fxclip is a self-hosted Telegram bot that removes tracking
from links and optionally improves X, Instagram and Reddit previews, without requiring group
members to install a client. Menus support English and French. Run your own instance
using the [Docker setup](#docker-setup); this project does not configure a public bot.

## Direct messages / Messages directs

Send a link directly to the bot: it replies with the cleaned link or the enabled
preview, even if the link is already clean. No group activation or Secretary
connection is needed. Direct requests always keep your message; group Reply,
Replace and Off choices do not change this behavior. Ordinary conversation and
unknown commands do not trigger link replies.

Your personal link, YouTube, Facebook and Reddit-video choices apply; absent
choices use bot defaults, never a group's settings. Facebook and Reddit native
videos stay off by default. Enabled previews use the same disclosed network
providers as group previews. Direct replies have no Replace action or durable
publication listing; the temporary Remove button still lasts five minutes.

Envoyez un lien directement au bot : il répond avec le lien nettoyé ou l’aperçu
activé, même si le lien est déjà propre. Aucun groupe ni connexion Secrétaire
n’est nécessaire. Votre message reste toujours ; les modes de groupe ne changent
pas ces réponses. Vos préférences de liens et d’aperçus s’appliquent, sinon les
réglages du bot. Les vidéos Facebook et Reddit restent désactivées par défaut.
Les aperçus activés utilisent les mêmes fournisseurs réseau qu’en groupe.

## Settings / Réglages

Open the bot privately with `/settings`. Start from **My preferences / Mes
préférences**, then choose **Group behavior / Comportement en groupe** or **Links & previews /
Liens et aperçus**.

| Scope / Portée | What changes / Ce qui change |
|---|---|
| **My preferences / Mes préférences** | Only your future messages, in every group where cleaning is enabled. Uniquement vos futurs messages, dans tous les groupes où le nettoyage est activé. |
| **This group / Ce groupe** | This group's defaults for members without a personal override. Les choix de ce groupe pour les membres sans préférence personnelle. |
| **Bot defaults / Réglages par défaut du bot** | The fallback when no personal or group choice exists; changing it never resets existing choices. Le choix de repli sans préférence personnelle ni réglage du groupe ; le modifier ne réinitialise aucun choix existant. |

**Follow group / Suivre le groupe** means inheritance: the result can differ from
one group to another. It does not mean “off”. A group must have cleaning enabled;
turning that activation off stops automatic cleaning for everyone, including
members with personal preferences.

**Suivre le groupe** laisse chaque groupe décider : ce n’est pas une
désactivation. Si le nettoyage du groupe est désactivé, aucun choix personnel ne
peut le réactiver.

In **Group behavior / Comportement en groupe**, choose a cleaned reply that keeps the original unless you explicitly confirm **Replace / Remplacer**,
replacement with an author credit, or off. Replacement deletes the original only
after the repost succeeds and permissions allow it; media, forwards and anonymous
senders receive a reply instead. **Secretary / Secrétaire** only edits your own
outgoing messages in connected private chats; see [Secretary Mode](#secretary-mode).
Secretary has its own on/off choice and leaves group behavior unchanged.
Behavior and link choices are separate.

Dans **Comportement en groupe**, choisissez une réponse qui garde l’original sauf
confirmation explicite de **Remplacer**, un remplacement automatique avec le nom
de l’auteur, ou la désactivation. **Secrétaire** concerne
uniquement vos messages sortants dans les conversations privées connectées.
Son activation est indépendante et ne change pas le comportement en groupe.
Changer les liens ne change pas ce comportement.

Changes save immediately and apply to future messages. **Close / Fermer** only
hides the panel; there is no extra Save step.
Les changements sont enregistrés immédiatement pour les futurs messages.
**Fermer** masque simplement le panneau.

Group admins open `/setup` or `/fxclip` for their own group's settings. The bot
owner uses `/default` for bot defaults and `/groups` for discovered groups.
Permissions are checked on every action; group admins cannot change other
members' preferences or bot defaults. A join greeting links to personal settings.
After the group panel is sent, `/setup` or bare `/fxclip` is removed if permitted;
closing the panel never removes other messages.

Commands remain available: `/mode reply|replace|secretary|off|default`,
`/fxclip reply|replace|off`, and `/fxclip previews on|off`.

## Preview links

Group admins can enable or disable enhanced previews in `/setup` or with
`/fxclip previews on|off`. When enabled, X, Instagram and Reddit links can use
`fxtwitter.com`, `zzinstagram.com` and `vxreddit.com`. Choose a mirror under **Links & previews → Previews**, then enable it or open its advanced provider settings.

For a message containing only a plain YouTube video link, enhanced previews also
fetch the title and thumbnail directly from YouTube and send them with the clean
link. This includes already-clean links. Telegram's Bot API does not expose
whether its own card appeared, so a duplicate preview is possible. Turning
enhanced previews off disables these cards. Explicitly suppressed previews,
formatted or hidden links, captions and messages containing more than one link
keep their existing behavior. Secretary only edits links; it does not post cards.

**Facebook videos** (**Vidéos Facebook**) is a separate Telegram-only option under
**Links & previews → Previews → Facebook**, **off by default**, including after an
upgrade. Turning on group cleaning or enhanced previews does not turn it on.
When explicitly enabled, a message containing only one plain public Facebook or
Facebed link can receive a native video reply, even if the link is already clean.
The full upstream Facebed source runs privately alongside the bot on the NAS,
pinned to revision `ccc612c6`. It resolves metadata by contacting Facebook itself;
resolution still depends on Meta allowing logged-out fetching. There is no
Facebook login or access to private content, and no runtime request or fallback
to the public facebed.com service.

Following Facebed's URL-forwarding format, the bot rewrites accepted source links
to `http://facebook-resolver:9812` on the Docker network, preserving the
engine-cleaned path and meaningful query parameters and dropping the fragment.
This includes reel, share (such as `/share/r/token`), post, watch and group routes;
a supported URL format does not guarantee a video. Only metadata containing a
validated `og:video` can produce a native video reply. Image/text-only posts are
not converted by this option.

Accepted source hosts are exactly `facebook.com`, `www.facebook.com`,
`m.facebook.com`, `facebed.com` and `www.facebed.com`. Facebed source links use the
same private resolver; their public host is never contacted. The resolver is not
an editable mirror provider. Diagnostic/service routes (including `/dump` and
`/healthz`), unsafe paths, credentials and unrelated/lookalike hosts are rejected.
The bot downloads validated public Facebook video from an HTTPS `*.fbcdn.net`
MP4 URL to the bot server, then uploads a copy to Telegram. Tracker removal stays
entirely in the shared engine and `Shared/rules.json`; this option adds no shared
mirror rule or separate tracking-parameter list.

Slow Facebook/Reddit replies and YouTube fetches show a quiet “Preparing preview…” reply
(“Préparation de l’aperçu…” in French) after 0.7 seconds. The same message becomes
the video, thumbnail card or size notice; fast fetches skip the status. Facebook
and Reddit replacement attempts skip this status until the outcome is known, preserving the
reply target if a video is too large and the original must stay. Removal
controls start their five-minute window only when the finished content is confirmed.
If fetching fails, the bot uses the cleaned-text fallback or removes its status.
The original is kept until the final replacement is confirmed. A restart or an
uncertain Telegram response can leave a status behind; the bot does not send a
second preview to guess whether the first request succeeded. Link-mirror previews for
X, Instagram and Reddit are generated by Telegram itself, so their rendering
completion cannot be tracked this way.

Full-video replies show just the video and five-minute controls, without a
heading, author/description, raw link or **Open Facebook** button. Eligible replies
offer **Remove / Replace**; confirmed manual replacements add an author/source
credit. Automatic replacements offer **Delete my message** for five minutes. When
automatic replacement is attempted, a small poster credit is added; the original stays if deletion
fails. Full-video removal records need no source Open URL.

Videos are limited to 20 MiB; temporary downloads are discarded after the attempt.
For a larger video, the bot replies with its title and **Open Facebook**
(**Ouvrir Facebook**) instead, keeping the original even in Replace mode. This
reply has a five-minute removal control, never **Replace**; its opening button
stays after expiry. Captions, hidden/formatted links and messages with several
links are not eligible for this video path. Secretary does not send videos.
Pausing enhanced previews pauses Facebook videos too. Telegram may also show
its own preview, so duplicates are possible.

## Reddit videos / Vidéos Reddit

**Links & previews → Previews → Reddit · Video & links → Videos in Telegram**
controls native Reddit videos. This Telegram-only feature is **off by default**,
including after an upgrade. It needs an explicit opt-in; enabling group cleaning,
resuming enhanced previews or changing a Reddit mirror never enables it. Existing
disabled Reddit mirror preferences stay disabled. Native videos and Reddit link
mirrors are independent: the mirror leaf controls only link rewriting, and its
advanced provider setting never changes the native video source.

Personal, group and bot-default video choices inherit independently of the full
link configuration, like Facebook videos. **Enable/Disable for me**, **for this
group** or **by default** changes only that scope. **Follow group again** or
**Use bot default** removes the scalar override. These replies work in groups and direct requests to the bot;
Secretary never sends native videos. Pausing group cleaning or enhanced previews
also pauses them. Resetting link preferences includes this video preference:
personal/group choices return to inheritance, and bot defaults return to off.
Only a single plain public video link is eligible; captions, hidden/formatted
links and messages with several links keep normal link handling.

When enabled, the bot fetches public Reddit videos privately on its own server
using pinned upstream vx code and Reddit CDN, then uploads the video to Telegram.
Native video resolution makes no request or fallback to the public vx service,
requires no Reddit login and grants no access to private content. An independently
enabled link mirror may still contact its configured public provider through
Telegram. No settings-screen action fetches a video.

The bot selects the highest resolution that fits **20 MiB**, possibly reducing
quality. It combines audio when present and prepares the MP4 for quick playback
(faststart). Automatic previews keep the clean original; only explicitly
confirming **Replace** can remove it. Unsupported posts, unavailable
Reddit responses and resolution/download/upload failures preserve the original;
normal cleaning and a separately enabled mirror can still apply. Reddit
availability is not guaranteed. Telegram can also show its own preview, so
duplicates are possible. Temporary downloads are discarded after the attempt.

Slow replies can show **Preparing preview…** before the finished reply. The
**Remove / Replace** controls on eligible replies belong to the original poster
and last five minutes. Remove deletes the bot reply, not the Reddit post; Replace
requires confirmation before deleting the original Telegram message. Pending
button cleanup retains only the existing control identifiers and, when an opening button exists, its label and
URL locally for at most 48 hours. Full-video replies retain no source Open URL.
Message text and media are not persisted.

Dans **Liens et aperçus → Aperçus → Reddit · Vidéos et liens → Vidéos dans
Telegram**, les vidéos natives sont **désactivées par défaut**, même après mise
à jour. Elles s’activent séparément des liens miroirs, sans réactiver un miroir
désactivé. Chaque portée garde son choix ; **Suivre à nouveau le groupe** ou
**Utiliser le réglage par défaut du bot** rétablit l’héritage. En groupe
uniquement, jamais avec Secrétaire ; la pause des aperçus les suspend aussi.

Le serveur du bot utilise du code vx à version figée et le CDN Reddit, sans
service vx public ni connexion Reddit, puis envoie la copie à Telegram. Il choisit
la meilleure résolution tenant dans **20 Mio**, quitte à réduire la qualité,
assemble le son s’il existe et prépare la lecture rapide. Les aperçus automatiques
gardent l’original propre ; seule une confirmation explicite de **Remplacer** peut
le supprimer. Un échec peut laisser agir un miroir seulement s’il est activé
séparément. La disponibilité Reddit n’est pas garantie et des doublons sont possibles. Le retrait
par bouton reste disponible cinq minutes ; `/delete` ou `/supprimer` permet
ensuite de retirer la publication du bot pendant moins de 48 heures. Les URL
d’ouverture en attente de retrait du bouton restent localement au plus 48 heures.
Texte et médias ne sont pas conservés.

## Preview fallback and removal

Other links already prepared by a fxclip client produce no reply, repost,
deletion or edit. A tracker-free original can still become a mirror link when
previews are enabled. Enabled Facebook and Reddit videos are other exceptions for
already-clean links. A clean YouTube, Facebook or Reddit link is never deleted
just to add a card or video automatically; explicit manual replacement is the
exception. Unsupported links and metadata, download or upload failures
preserve the original; normal link cleaning can still apply.
Metadata failures fall back to normal cleaning. Photo rejection can fall back to
cleaned text; an ambiguous send is never retried.

Newly tracked eligible group replies offer **Remove / Replace** in English or
**Retirer / Remplacer** in French, side by side with equal width. Only the original
poster can use them, for five minutes from the finished reply; admins and the bot
owner have no override. Remove deletes the bot reply for everyone, never the
website post. Automatic replacements keep their single **Delete my message /
Supprimer mon message** button. Controls disappear at expiry without deleting the
publication, and removal never restores a replaced original.

Manual replacement requires an unedited text original sent by an identifiable
person in a group. Media originals, anonymous/channel-authored, protected, paid
and automatically forwarded messages are excluded. A forwarded text is eligible
only when its source can be preserved. The bot reply itself can be text, a photo
or a video; oversized-video notices offer removal only. Old replies without a
saved original receipt never acquire Replace.

The first **Replace / Remplacer** checks the sender, saved receipt, original
message ID/date/author and current bot deletion rights. It changes only the
keyboard to equal-width **Confirm / Cancel** or **Confirmer / Annuler** and shows
an alert: the original will be deleted, and the author and forwarded source kept.
Cancel restores the paired buttons; neither action changes saved preferences.
Confirmation repeats those checks, including that the original is still unedited.
It adds **Shared by / Partagé par**, plus **Source** for forwards, to the same bot
message, preserving its content, formatting, opening button and preview options.
Only a confirmed edit of that same message permits deletion of the original.
Insufficient room or an uncertain edit keeps the original; there is no resend or
content truncation.

Les nouvelles réponses de groupe éligibles proposent **Retirer / Remplacer** sur
une même ligne, à parts égales, pendant cinq minutes et pour l’auteur uniquement.
**Remplacer** affiche l’avertissement de suppression et les boutons **Confirmer /
Annuler**, sans changer les préférences. Après une nouvelle vérification,
**Confirmer** conserve le contenu, le nom de l’auteur et la source d’un transfert
dans le même message du bot avant de supprimer l’original. **Annuler** rétablit les
deux boutons. Un original modifié ou une réponse de vidéo trop volumineuse ne peut
pas être remplacé ainsi.

For less than 48 hours after publication, reply to the bot's message with
`/delete` or `/supprimer`; both aliases work in either language. Privately, open
`/publications` or **My publications / Mes publications** to see only your own
tracked group publications, five per page. Entries show the group, UTC date and
message ID; **View / Voir** is available for supergroup messages. **Delete /
Supprimer** opens a confirmation. Older messages are not reconstructed, except
when a surviving legacy removal control supplies ownership metadata.

Ownership records retain only chat/message IDs, poster ID and publication date,
independently of button cleanup. No link, title, message text or media is saved
in this register; group titles are resolved for display. The only extra data for
manual replacement is an optional original message ID/date during the five-minute
button window. It is cleared durably before attempting the credit edit, even if
the response is uncertain, at five-minute expiry even without a remaining control,
or when the buttons are cleaned up. No original body,
author name or forwarded-source title is saved. The register holds at most 20,000
unexpired records and never evicts one early. At capacity, replacement falls back
to a reply and keeps the original.

Pending cleanup keeps chat/message IDs, the poster's ID and a timestamp. For
YouTube cards and oversized-video notices it also temporarily keeps the source
Open button's label and URL, so that button can stay after the removal button
expires, including across a restart. Full-video replies have no Open button and
retain no source Open URL.
The cleanup record is deleted after successful cleanup; the separate ownership
record remains until its 48-hour expiry, without the original-replacement receipt.
Failed cleanup can retry for up to 48 hours; its existing 4096-record limit is unchanged. No message text or media
is stored. Legacy replies without a saved opening button have their old keyboard
cleared; links in their captions remain usable. Cleanup resumes when the bot reconnects;
the button action itself is always refused after five minutes. The command and
private list use the separate ownership window of less than 48 hours.

## Link settings / Réglages des liens

From the relevant dashboard, open **Links & previews / Liens et aperçus** and
choose a category: tracker cleaning, previews or cleaning exclusions. In
**Previews / Aperçus**, choose one service, then enable or disable it. Provider
domains and editing commands appear only inside that service's advanced page.
YouTube cards, Facebook videos and Reddit videos have separate choices; Facebook
and Reddit native videos remain off by default. A group's enhanced-preview pause
pauses all three. Reddit's parent opens separate link-mirror and native-video settings.

Depuis le tableau de bord de la portée souhaitée, ouvrez **Liens et aperçus**,
puis une catégorie. Dans **Aperçus**, choisissez un service avant de l’activer ou
le désactiver. Le fournisseur et sa commande de modification se trouvent dans
les réglages avancés de ce service.

Personal link rules also apply to your outgoing messages in connected private chats
when Secretary Mode is enabled. Without a personal link configuration, those
private chats use the bot defaults; groups use their own defaults. YouTube cards
and Facebook/Reddit video replies work in groups and direct requests to the bot, not Secretary actions.

Les règles personnelles des liens s’appliquent aussi aux messages sortants en
privé connecté lorsque Secrétaire est activé. Sans personnalisation, Secrétaire
suit les réglages par défaut du bot ; les groupes suivent leurs propres réglages.
Les fiches YouTube et les vidéos Facebook ou Reddit ne sont pas envoyées par Secrétaire.

Personal links initially **Follow group / Suivre le groupe**. To customize
tracker, mirror or exclusion settings, confirm the explanation first: a complete link configuration starts from the
**bot defaults**, then replaces group link choices for your future messages in
all enabled groups. It does not copy the currently viewed group's settings.
YouTube, Facebook and Reddit videos can be changed separately; starting the complete
configuration keeps those choices.

Pour personnaliser vos liens, une confirmation explique la portée : la
configuration complète part des **réglages par défaut du bot**, puis remplace
ceux des groupes pour vos futurs messages dans tous les groupes activés. Vos
choix YouTube, vidéos Facebook et Reddit déjà définis sont conservés séparément.

Resetting links also asks for confirmation. For personal preferences, it removes
your custom link choices and returns to **Follow group / Suivre le groupe**. For
a group, it returns to bot defaults; for bot defaults, it restores the built-in
link choices, including the off default for native Reddit videos. The reset also
clears the scope's YouTube, Facebook and Reddit video overrides. Resetting links
does not reset behavior or group activation.
La réinitialisation des liens demande confirmation ; elle ne change ni le
comportement des messages ni l’activation du groupe.

Advanced provider and exclusion commands remain available:

| Scope | Provider | Cleaning exclusion |
|---|---|---|
| Personal, in private | `/provider reddit mirror.example` | `/exclude add example.com` |
| Group, admin only | `/fxclip provider reddit mirror.example` | `/fxclip exclude add example.com` |
| Bot defaults, owner only in private | `/default provider reddit mirror.example` | `/default exclude add example.com` |

Use `default` instead of a provider domain to restore its built-in provider, or
`remove` instead of `add` to remove an exclusion. Exclusions include subdomains;
append `exact` when adding one to match only that host. Exclusions skip tracker
removal, while preview choices still apply separately.

Providers are domains only, without a scheme, credentials, port, path or query;
preview links use HTTPS. The selected service can receive links when previews
are generated or opened. Editing a provider keeps its enabled state and does
not contact the service from the settings screen.

This settings redesign does not migrate saved choices or change native app
rules. Le nouveau parcours conserve les choix enregistrés et les règles des
applications natives.

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
permission. Open **Secretary · private chats** in the bot's private settings and
choose **Enable Secretary**. The dashboard and this page show its current status;
use **Disable Secretary** on that page to stop private edits. Enabling or disabling
Secretary leaves group replies, replacement and off choices unchanged. Changing
group behavior also preserves Secretary's choice. The legacy `/mode secretary`
command enables Secretary without replacing group behavior.

Dans les réglages privés, ouvrez **Secrétaire · en privé**, puis **Activer
Secrétaire**. Le tableau de bord et cette page indiquent son état ; **Désactiver
Secrétaire** arrête les modifications en privé. Le comportement en groupe reste
inchangé, et le modifier conserve aussi le choix Secrétaire.

Existing Secretary consent is preserved when loading older state files, without
rewriting them. A legacy personal Secretary mode now follows the group's behavior
while keeping private edits enabled until explicitly disabled.

The bot checks the current connection and rights before every edit. Only messages
sent by that connection's owner are edited; incoming messages and messages sent
by business bots remain untouched. Telegram limits `can_reply` to private chats
with incoming activity within 24 hours. Text and caption edits are supported.

## Docker setup

Use one instance per token. No public port, domain or inbound tunnel is needed:
the bot contacts Telegram over HTTPS long polling. The private Facebed sidecar
uses `http://facebook-resolver:9812` only on the Docker network, with no published
host port or public hostname. It receives neither the Telegram token nor the bot
state volume. Python access logs, content logs and Discord diagnostics are
disabled. The private Reddit resolver uses `http://reddit-resolver:9813` on that
same internal network. It also has no host port, token or state volume; media is
assembled in temporary files and discarded after each request.

From the repository root:

```sh
swift test --package-path Engine
swift test --package-path Telegram
docker build --platform linux/amd64 -f Telegram/Dockerfile -t fxclip-telegram:local .
docker build -f Telegram/resolver/Dockerfile -t fxclip-facebook-resolver:local .
docker build -f Telegram/reddit-resolver/Dockerfile -t fxclip-reddit-resolver:local .
docker run --rm --platform linux/amd64 fxclip-telegram:local --check
```

Copy `compose.yaml` and `.env.example` to the server, then create `.env` from the
example. Store the token in `secrets/telegram_token`, never in the image, Git or
Compose commands. Restrict the `secrets` directory to its owner (`chmod 700`).
For non-Swarm Compose the file must be readable by container user 10001; mode
`0444` inside that private directory works. The image initializes the state volume.

Set `FXCLIP_IMAGE` and `TELEGRAM_OWNER_IDS` (numeric bot-owner IDs).
`FXCLIP_REDDIT_RESOLVER_IMAGE` selects the private Reddit image and defaults to
`fxclip-reddit-resolver:local`. See [the resolver guide](reddit-resolver/README.md)
for its pinned source, media bounds and offline checks.

`FXCLIP_FACEBOOK_RESOLVER_IMAGE` selects the private sidecar image and defaults to
`fxclip-facebook-resolver:local`. Optionally set
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
titles, and the polling checkpoint. Back up that volume. Message bodies and media
are never persisted or logged. Pending removal-button cleanup temporarily retains
YouTube and oversized-notice opening-button URLs until cleanup succeeds, for at
most 48 hours; full-video replies retain no source Open URL.
Automatic container updates are disabled in the supplied
configuration: install new images explicitly.

## Real-world verification

1. Open `/settings` with French and English Telegram locales. Check Automatic,
   explicit English/French and persistence across restart.
2. Open `/setup`, choose a group language, then interact from an account with a
   different personal language. The shared panel must keep the group's language.
3. Post an X link containing `?s=1` in an enabled test group. The bot replies with
   the fxtwitter link and keeps the original, without an extra author-credit line.
4. On a new eligible text reply, check equal-width **Remove / Replace** and
   **Retirer / Remplacer** at narrow widths. Replace must show a deletion alert
   and **Confirm / Cancel** or **Confirmer / Annuler** without changing the body.
   Cancel restores the pair; confirmation credits the same reply before deleting
   the original. Test a forwarded text, text/photo/video replies, expired buttons,
   changed originals and revoked deletion rights. Oversized notices and old
   replies without an original receipt must never offer Replace.
5. Select automatic replacement for your account. Only your behavior changes;
   its single deletion button stays unchanged. Removing the bot's deletion
   permission retains the original. Check media and forwards too.
6. Select off, then follow the group setting, and confirm each outcome.
7. Connect Secretary in an eligible private test chat. Your outgoing link is
   edited in place; an incoming link stays intact. Enable and disable Secretary
   and confirm that group behavior stays unchanged. Change group behavior and
   confirm that Secretary's choice persists. Revocation prevents edits.

## Privacy and limits

Cleaning runs locally on the server, but the bot communicates with Telegram.
Telegram receives reposted messages; mirrors can receive links when previews are
generated. The engine does not expand or visit links. No additional analytics or
external account is used. Native YouTube cards request video metadata from
YouTube's oEmbed endpoint and let Telegram fetch the YouTube thumbnail; they use
no preview mirror. Fetched titles, thumbnails and videos are not persisted;
YouTube and oversized-notice opening-button URLs are retained only while
removal-button cleanup is pending, for at most 48 hours. Full-video replies have
no opening button or saved source Open URL. Separately, publication ownership
IDs and dates remain for less than 48 hours for author-only deletion and the
private recent-publications list; no URL, title or message content is stored in
that register. An optional original message ID/date enables explicit replacement
only during the five-minute button window; it is cleared before the edit attempt,
at five-minute expiry even without a remaining control, or on button cleanup.
Original text, names and forwarded-source titles are never saved. Explicitly confirming Replace can delete a clean original after the bot
reply has kept the author/source credit; automatic previews keep it.
See [publication removal](#preview-fallback-and-removal).
Facebook videos are off by default. Opting in
sends the cleaned public Facebook or Facebed link to the private resolver running
pinned upstream Facebed code on the same server. The resolver contacts Facebook
for metadata; the bot downloads validated Facebook CDN video and uploads a copy
to Telegram (up to 20 MiB). This still uses Facebook and Telegram over the network;
it makes no runtime requests or fallback to the public facebed.com service.
Resolution depends on Meta allowing logged-out fetching, with no Facebook login
or private access. Larger videos receive a title and opening-button reply while
the original stays intact. Temporary video data is discarded after each attempt.
The resolver has no Telegram secret or state volume, Python access/content logs
or Discord diagnostics. Locale detection uses Telegram's supplied language tag,
never message-text analysis or an external translation service.

Reddit native videos also require separate consent, use pinned vx code privately
on the bot server with Reddit CDN and upload copies to Telegram (20 MiB maximum).
They do not use a public vx service or Reddit login. Link-mirror choices remain
independent; see the Reddit videos section for quality, audio, availability and
cleanup limits.

Unchanged links stay untouched except for enabled YouTube cards or Facebook/Reddit videos. Protected, paid,
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

Native Facebook and Reddit video preferences live only in Telegram's bot state,
not in shared `UserSettings` or desktop/mobile port settings: uploading video replies
is specific to the bot, while the existing Reddit link mirror remains a shared rule.

# fxclip pour Telegram

Un bot hébergé chez vous : les membres d’un groupe n’ont rien à installer.
Il réutilise le moteur Swift et `Shared/rules.json` pour retirer les traceurs
et améliorer les aperçus X / Instagram.

`Shared/rules.json` est l’unique source des règles pour toutes les plateformes.
Le bot importe directement `FxEngine` : aucune règle de site ou logique de
nettoyage spécifique à Telegram ne doit être ajoutée ici. Tout changement de
nettoyage commence dans `Shared/vectors.json`, passe le moteur Swift de référence,
puis les ports Android et Windows contre les mêmes données.

## Choisir son comportement

Ouvrir le bot en privé puis **Démarrer** ou `/settings`. Le menu est en français,
avec des boutons et une coche sur le choix actuel :

- **Répondre au message** : garde l’original et répond avec la version nettoyée.
  L’auteur figure déjà dans la citation Telegram, sans ligne d’attribution ajoutée.
- **Remplacer le message** : republie le texte avec « Publié par … », puis supprime
  l’original uniquement après confirmation de l’envoi. Sans droit de suppression,
  avec un média, un transfert ou une identité anonyme, le bot répond à la place.
- **Secrétaire · en privé** : modifie ses propres messages sortants dans les
  conversations privées connectées. Aucun changement des messages de groupe.
- **Désactiver fxclip** : ne fait rien pour ses messages.
- **Suivre le réglage du groupe** : retire le choix personnel.

Priorité : **choix personnel → réglage du groupe → réglage général**.
Le propriétaire configure le réglage général avec `/default` en privé.
Le bouton **Groupes connectés** (ou `/groups`) affiche les groupes découverts,
permet leur activation et indique les droits réellement accordés au bot.
Les administrateurs d’un groupe autorisé utilisent `/fxclip reply|replace|off`
et `/fxclip previews on|off`. Le choix d’une personne reste prioritaire,
y compris si le réglage par défaut du groupe est désactivé.

À l’ajout du bot, un court message de bienvenue propose **Mes réglages**
à chaque membre. Le bouton **Réglage du groupe**, `/setup` ou `/fxclip`
ouvre le menu du groupe : ses administrateurs peuvent activer le nettoyage
et choisir le mode de leur propre conversation. Chaque action vérifie les
droits actuels de la personne. Ils ne peuvent pas modifier le réglage général
du bot, les autres groupes ou les préférences d’un membre.

Les commandes `/mode reply|replace|secretary|off|default` restent disponibles.

## Secrétaire

Activer **Secretary Mode** dans @BotFather puis connecter le bot dans les
réglages d’automatisation de son compte Telegram. Choisir les conversations
accessibles et donner le droit de réponse / modification. Sélectionner ensuite
**Secrétaire · en privé** dans le menu du bot.

Le bot vérifie la connexion et les droits avant chaque modification. Il édite
uniquement les messages dont l’auteur est le propriétaire de cette connexion,
jamais ceux reçus ni ceux envoyés par une autre automatisation. Telegram limite
`can_reply` aux conversations privées ayant reçu un message dans les dernières
24 heures. Le mode ne fonctionne pas dans les groupes. Les modifications
de texte et de légendes sont prises en charge.

## Installation Docker

Une seule instance doit utiliser le token. Aucun port entrant, domaine ou tunnel
public n’est nécessaire : le bot contacte Telegram en HTTPS par long polling.
Tailscale sert uniquement à administrer le serveur.

Depuis la racine du dépôt :

```sh
swift test --package-path Engine
swift test --package-path Telegram
docker build --platform linux/amd64 -f Telegram/Dockerfile -t fxclip-telegram:local .
docker run --rm --platform linux/amd64 fxclip-telegram:local --check
```

Copier `compose.yaml` et `.env.example` sur le serveur. Créer `.env` à partir
de l’exemple. Stocker le token dans `secrets/telegram_token`, jamais dans l’image,
le dépôt ou les commandes Compose. Le dossier `secrets` doit être accessible
uniquement à son propriétaire (`chmod 700`). Pour Compose sans Swarm, le fichier
doit être lisible par l’utilisateur 10001 du conteneur ; un fichier `0444`
dans ce dossier privé convient. Le volume `state` est initialisé par l’image.

Configurer `FXCLIP_IMAGE`, `TELEGRAM_OWNER_IDS` (identifiants numériques des
propriétaires) et `TELEGRAM_ALLOWED_CHATS` (identifiants des groupes autorisés).
La liste vide laisse fonctionner les réglages privés et la découverte
`/chatid`, mais aucun nettoyage classique de groupe tant qu’il n’a pas été
activé dans **Groupes connectés**. Le mode Secrétaire suit
séparément le consentement personnel et la connexion Telegram.

```sh
docker compose up -d
docker compose run --rm --no-deps fxclip-telegram --check-config
docker compose logs --tail=30
```

Ajouter le bot au groupe et lui donner le droit de supprimer les messages pour
le remplacement. Un bot administrateur reçoit les messages du groupe ; sinon,
désactiver Privacy Mode dans @BotFather. Le bot découvre un groupe à son ajout,
à un changement de droits ou à la réception d’un message. Ouvrir `/groups`
en privé pour vérifier ses droits et activer le groupe. La liste
`TELEGRAM_ALLOWED_CHATS` reste utilisable pour une configuration initiale ;
le choix d’activation enregistré depuis le menu passe avant cette liste.
`/chatid` dans le groupe permet aussi de récupérer son identifiant. `/chatid` en privé
donne l’identifiant personnel nécessaire à `TELEGRAM_OWNER_IDS`.

Le fichier `state.json` du volume conserve les préférences et la position de
lecture, ainsi que les identifiants et noms des groupes découverts.
Sauvegarder ce volume pour garder les réglages. Aucun texte de message
ni URL n’est conservé dans le volume ou dans les journaux. Watchtower est
désactivé pour ce service : installer explicitement chaque nouvelle image.

## Vérification réelle

1. En privé, `/settings` doit afficher le menu français et garder le choix après
   redémarrage. Un membre ordinaire ne peut pas changer le réglage général.
2. Dans un groupe de test autorisé, envoyer un lien X avec `?s=1` : le bot répond
   avec le lien fxtwitter et « Publié par … », sans modifier l’original.
3. Choisir le remplacement pour son propre compte : seul l’auteur concerné
   change de comportement. Retirer le droit de suppression doit conserver
   l’original. Tester aussi un média et un message transféré.
4. Choisir « Désactiver » : aucune réponse. Choisir « Suivre le réglage du
   groupe » : le défaut s’applique à nouveau.
5. Connecter Secrétaire dans une conversation privée de test ayant reçu un
   message récent : son lien sortant est modifié sur place. Un lien reçu reste
   intact. Révoquer la connexion ou les droits empêche les modifications.

## Limites et confidentialité

Le nettoyage reste local au serveur, mais ce bot communique avec Telegram.
Telegram reçoit les messages republiés ; les sites miroirs peuvent recevoir
les liens lors de la génération des aperçus. Aucun lien n’est développé ou
visité par le moteur. Aucun suivi, compte externe ou télémétrie supplémentaire.

Un message inchangé, protégé, payant, trop long pour être republié sans perte,
ou âgé de plus de cinq minutes est ignoré. Les anciennes copies accumulées
pendant une panne ne sont pas réécrites au redémarrage. Les liens dans les
blocs de code ne sont pas modifiés. Les liens cachés et le formatage sont
conservés avec leurs positions UTF-16 adaptées.

La position de lecture est enregistrée **avant** toute action. Si une réponse
réseau est ambiguë ou si le processus s’arrête pendant l’envoi, le bot ne
réessaie pas le même message : l’original reste en place, mais un nettoyage
peut être manqué. Une suppression refusée laisse les deux messages.

Les révisions reçues ensemble sont regroupées avant traitement. Telegram
ne propose pas de comparaison atomique avant modification ou suppression :
une correction tapée pendant la requête sortante peut encore être écrasée
en mode Secrétaire, ou perdue en mode remplacement. Le mode réponse conserve
l’original et reste le choix initial.

Références : [Business bots](https://core.telegram.org/bots/features#secretary-bots),
[droits Business](https://core.telegram.org/bots/api#businessbotrights),
[suppression](https://core.telegram.org/bots/api#deletemessage).

# Fashion Brief

A free, self-updating "Feedly" for fashion / luxury / retail executives.
Every morning GitHub fetches 13 media, an AI keeps only the fashion business news
(earnings, collabs, store openings, M&A, appointments, China, macro), translates the
headlines into English and publishes the page.

**Cost: €0** — GitHub Actions + GitHub Pages (public repository) + Google Gemini (free AI tier).
Your computer can be off.

## Mise en ligne (une seule fois, ~10 min)

1. Crée un compte sur https://github.com (gratuit).
2. **New repository** → nom : `fashion-brief` → **Public** → *Create repository*.
3. Sur la page du dépôt : **uploading an existing file** → glisse **tous les fichiers et dossiers**
   de ce dossier (y compris le dossier caché `.github` : dans le Finder, `Cmd + Shift + .` pour l'afficher)
   → *Commit changes*.
   Si le dossier `.github` n'a pas été envoyé : **Add file → Create new file**, nom
   `.github/workflows/daily-brief.yml`, colle le contenu du fichier → *Commit changes*.
4. **Settings → Pages** → *Source* : `Deploy from a branch` → Branch `main`, dossier `/docs` → *Save*.
5. **Actions** → *Daily fashion brief* → **Run workflow** (premier lancement, ~3 min).
6. Ta page : `https://<ton-pseudo>.github.io/fashion-brief/` → ajoute-la à l'écran d'accueil de ton téléphone.

Ensuite elle se met à jour toute seule chaque matin (~6 h / 7 h, heure de Paris).
Pour forcer une mise à jour : **Actions → Daily fashion brief → Run workflow**.

## Sécurité
- La **clé Gemini** est rangée dans les *Secrets* de GitHub (Settings → Secrets and variables → Actions) :
  chiffrée, jamais dans les fichiers, masquée dans les journaux. Personne ne peut la relire, même avec le dépôt public.
- **Aucune carte bancaire** chez Google ni chez GitHub : impossible d’être facturée. Si la limite gratuite est
  atteinte, Google refuse simplement la demande (le tri par mots-clés prend le relais).
- Si tu crois que la clé a fuité : supprime-la sur https://aistudio.google.com/apikey et crées-en une nouvelle.
- Dépôt public = tout le monde peut *lire*, mais **seule toi peux modifier** ou lancer le brief.
- Ne colle jamais de mot de passe ou de clé dans un fichier de ce dépôt.
- Active la **double authentification** : GitHub → photo de profil → Settings → Password and authentication
  → *Enable two-factor authentication*. C'est la vraie protection de ton compte.

## Modifier
- **Médias** : liste `SOURCES` en haut de `veille_mode.rb`.
- **Heure** : ligne `cron` dans `.github/workflows/daily-brief.yml` (heure UTC).
- **Critères de tri** : texte `PROMPT` dans `veille_mode.rb`.

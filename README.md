# RushCut

Éditeur vidéo natif pour macOS, inspiré de CapCut : montage sur timeline, textes, audio, export MP4/MOV.
Tout fonctionne en local, sans compte, sans abonnement et sans filigrane.

- Mac avec puce Apple (M1 ou plus récent)
- macOS 26 Tahoe ou macOS 27 Golden Gate

## Installer RushCut

1. Ouvrez la page [Versions](https://github.com/logiprof/RushCut/releases/latest) et téléchargez **RushCut.zip**.
2. Double-cliquez sur le fichier pour le décompresser, puis glissez **RushCut** dans le dossier **Applications**.
3. **Première ouverture** : RushCut n'est pas signé par un compte développeur Apple payant, macOS le bloque donc la première fois.
   - Double-cliquez sur RushCut, puis cliquez sur **OK** dans le message.
   - Ouvrez **Réglages Système › Confidentialité et sécurité**, descendez jusqu'à « RushCut a été bloqué » et cliquez sur **Ouvrir quand même**.
   - Confirmez avec votre mot de passe. Les ouvertures suivantes se font normalement.

   Autre solution, dans le Terminal :
   ```bash
   xattr -dr com.apple.quarantine /Applications/RushCut.app
   ```

## Utilisation rapide

1. **Nouveau projet** : choisissez le format (16:9 pour YouTube, 9:16 pour Reels/TikTok…).
2. **Importer** (⌘I) ou glissez vos fichiers dans la bibliothèque.
3. **Double-cliquez** sur un média pour l'ajouter à la fin de la piste principale, ou **glissez-le** à l'endroit voulu de la timeline.
4. Coupez avec **⌘B**, supprimez avec **⌫** : la piste principale se referme toute seule.
5. Réglez la position, la taille, le volume ou le texte dans l'**inspecteur** à droite, ou directement avec les poignées dans l'aperçu.
6. **Exporter** (⌘E) : choisissez un préréglage (YouTube, Reels, site web…) et lancez l'export.

Les projets sont enregistrés automatiquement toutes les 30 secondes dans `~/Movies/RushCut/`.
Les fichiers vidéo d'origine ne sont jamais modifiés.

### Raccourcis clavier

| Action | Raccourci |
| --- | --- |
| Lecture / pause | Espace |
| Arrière / pause / avant (1×, 2×, 4×) | J / K / L |
| Image précédente / suivante | ← / → (⇧ : 10 images) |
| Couper à la tête de lecture | ⌘B |
| Supprimer à gauche / à droite de la tête | Q / W |
| Supprimer | ⌫ |
| Annuler / rétablir | ⌘Z / ⇧⌘Z |
| Copier / coller / dupliquer | ⌘C / ⌘V / ⌘D |
| Détacher l'audio | ⌥⌘D |
| Ajouter un marqueur | M |
| Aimantation oui / non | N |
| Zoom timeline avant / arrière / ajuster | ⌘+ / ⌘− / ⇧Z |
| Importer / exporter / enregistrer | ⌘I / ⌘E / ⌘S |
| Aperçu en grand | ⇧⌘F |

## Pour les développeurs

Projet Swift Package (Swift 6, SwiftUI, AVFoundation, Core Image), sans dépendance externe.

```bash
swift build              # compiler
swift test               # lancer les tests (modèle, sauvegarde, rendu et export de bout en bout)
./scripts/build-app.sh   # créer dist/RushCut.app et dist/RushCut.zip
```

Ouvrir `Package.swift` dans Xcode 26 permet aussi de compiler et lancer l'application.

Chaque envoi sur `main` est compilé et testé sur un Mac de GitHub Actions ; si tout passe, une nouvelle version est publiée dans les Versions.

Organisation du code (`Sources/RushCut`) :

| Dossier | Rôle |
| --- | --- |
| `Model` | Projet, pistes, clips (structures `Codable`), temps exact `RTime`, géométrie partagée aperçu/rendu |
| `Editing` | Opérations de montage (fonctions pures testées) et pile annuler/rétablir |
| `Persistence` | Paquets `.rushcut`, sauvegarde atomique, récupération après plantage |
| `Media` | Analyse des fichiers, vignettes, bandes de miniatures, formes d'onde |
| `Engine` | Composition AVFoundation et compositeur Core Image (identique pour l'aperçu et l'export) |
| `Export` | Encodage H.264 / HEVC / ProRes avec AVAssetWriter |
| `Editor`, `Views`, `App` | Interface SwiftUI |

Le cahier des charges complet décrit les lots suivants (V1, V2).

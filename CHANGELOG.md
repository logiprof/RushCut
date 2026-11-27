# Journal des versions

## 0.2 — Lot V1 (moteur, catalogues, audio, texte et voix)

Livré :

- Images clés sur la position, l'échelle, la rotation, l'opacité et le volume (losange dans l'inspecteur, navigation entre images clés, 5 courbes), repères dans la timeline ; les poignées de l'aperçu suivent les images clés.
- Vitesse constante ×0,1 à ×100, avec ou sans conservation de la hauteur du son.
- 62 transitions (fondus, glissements, zooms, volets, formes, flous, glitch, 3D…) avec aperçu animé au survol, durée réglable, « appliquer à tous les raccords ».
- Plus de 130 effets originaux (lumière, flou, glitch, mouvements de caméra, rétro, distorsion, particules, cadres, tutoriel), appliqués au clip ou sur une piste d'effets qui agit sur tout ce qui est dessous.
- 62 filtres avec intensité ; 12 ajustements de couleur et « Amélioration auto » ; masques (linéaire, miroir, cercle, rectangle) ; incrustation fond vert / bleu ; 8 modes de fusion ; coins arrondis, bordure et ombre du calque.
- 43 animations de clip (entrée, sortie, en boucle), 22 animations de texte (machine à écrire, mot par mot, karaoké, compteur…), 50 styles de texte, 50 autocollants vectoriels.
- Audio : volume jusqu'à +20 dB avec limiteur, réduction de bruit, atténuation automatique de la musique sous les voix (ducking), normalisation de la sonie (−14 ou −23 LUFS), vu-mètre, enregistrement de voix off, extraction du son d'une vidéo.
- Bibliothèque de 10 musiques et 20 bruitages originaux, générés par RushCut lui-même : libres de droits, y compris pour des vidéos monétisées.
- Sous-titres automatiques sur le Mac (framework Speech de macOS 26, 8 langues), découpage en lignes lisibles avec le minutage de chaque mot (karaoké), liste modifiable, style appliqué à tous, import et export SRT / VTT.
- Voix de synthèse (voix de macOS) placées sous le texte, import de voix enregistrées en lot (alignées sur les textes).
- Copier / coller les attributs d'un clip.


## 0.1 — Lot MVP

Livré :

- Accueil : nouveau projet (16:9, 9:16, 1:1, 4:5, 4:3, 21:9, personnalisé ; 24 à 60 i/s), projets récents avec vignette, renommer, dupliquer, corbeille.
- Paquet de projet `.rushcut` (JSON lisible, version, migration), sauvegarde atomique automatique toutes les 30 s, récupération après fermeture inattendue.
- Import : Finder (glisser-déposer, dossiers entiers), bouton Importer ; MP4, MOV, M4V (H.264, HEVC, ProRes), MP3, M4A, WAV, AIFF, FLAC, PNG, JPEG, HEIC, WebP, GIF et PNG animés ; vidéos de téléphone tournées et à fréquence variable.
- Bibliothèque : vignettes, durée, recherche, tri, indicateur « utilisé », média manquant en rouge et « Relier le média… ».
- Timeline : piste principale magnétique, pistes illimitées (calques, texte, audio), miniatures et formes d'onde, aimantation, zoom, marqueurs, déplacement entre pistes, rognage par les bords, fondus audio par poignées, masquer / couper le son / verrouiller une piste.
- Montage : couper (⌘B), Q / W, supprimer avec fermeture du vide, détacher l'audio (le son suit sa vidéo), copier / coller / dupliquer, annuler / rétablir illimité.
- Aperçu : lecture fluide, J/K/L, image par image, poignées de déplacement et de redimensionnement avec guides au centre, aperçu en grand.
- Inspecteur : cadrage (ajuster, remplir, étirer), position, échelle, rotation, miroir, opacité, recadrage libre ou 16:9 / 9:16 / 1:1 / 4:5 ; volume et fondus ; fond du projet en couleur ou flou de la vidéo.
- Texte : 6 modèles, police (système ou importée .ttf/.otf), taille, couleur, gras, italique, alignement, interlettrage, interligne, contour, ombre, fond arrondi.
- Export : MP4 / MOV, H.264, HEVC, ProRes 422, 480p à 4K, 24 à 60 i/s, débit recommandé / léger / net / personnalisé, estimation de la taille, vérification de l'espace disque, préréglages (YouTube, Reels, site web, archive), annulation, notification.
- Tests automatiques : modèle, montage, annuler × 50, sauvegarde et migration, export de bout en bout avec contrôle des pixels, de la durée, de la résolution et du son.

Écarts par rapport au cahier des charges, à traiter en V1 :

- Le volume est limité à 0 dB (pas d'amplification au-delà) ; les images clés de volume sur la forme d'onde arrivent avec les images clés (V1).
- Sélection multiple par Cmd-clic et Maj-clic ; la sélection au rectangle arrive en V1.
- La saisie du texte se fait dans l'inspecteur (pas encore directement dans l'aperçu).
- L'application n'est pas encore « bac à sable » (App Sandbox) : sans compte développeur, le bac à sable compliquerait l'accès aux fichiers sans apporter de protection utile pour un usage personnel.
- L'interface est en français directement dans le code (catalogue de traductions en V1).

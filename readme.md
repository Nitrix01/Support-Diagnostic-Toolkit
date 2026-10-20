# Support Diagnostic Toolkit

**Outil de diagnostic Windows en PowerShell — diagnostics locaux et distants, rapports HTML et JSON.**

> **Langue :** interface, messages et rapports en français. La documentation anglaise pourra être ajoutée ultérieurement.

## Présentation

Support Diagnostic Toolkit est un projet PowerShell destiné à faciliter la collecte et la consultation d'informations utiles au diagnostic de postes Windows. Il regroupe sept modules accessibles depuis un menu en console et permet de générer des rapports structurés pour documenter une intervention de support informatique.

Le projet a été développé dans une démarche d'apprentissage pratique du support IT, de PowerShell, de l'administration Windows et du diagnostic à distance avec WinRM.

**Périmètre :** collecte et restitution d'informations en lecture seule. L'outil ne répare pas automatiquement les incidents détectés.

## Fonctionnalités

- Exécution de diagnostics sur le **poste local**.
- Exécution de diagnostics sur un **poste Windows distant via PowerShell Remoting / WinRM**.
- Génération de rapports complets aux formats **HTML** (consultation) et **JSON** (données structurées).
- Classement des rapports par ordinateur et horodatage.
- Consultation des rapports HTML existants depuis le menu.
- Gestion des échecs par module lors de la génération des rapports : un diagnostic en échec n'empêche pas la collecte des autres résultats.

### Modules disponibles

| Module | Objectif |
| --- | --- |
| `SystemInfo.ps1` | Recueillir les informations système et matérielles du poste. |
| `Services.ps1` | Examiner les services Windows et repérer les situations nécessitant une vérification. |
| `Storage.ps1` | Contrôler les volumes, leur capacité et l'espace disponible. |
| `Network.ps1` | Examiner la configuration et certains éléments de connectivité réseau. |
| `Performance.ps1` | Collecter des indicateurs de performance, notamment processeur et mémoire. |
| `EventLogs.ps1` | Consulter des événements utiles au diagnostic dans les journaux Windows. |
| `WindowsUpdate.ps1` | Examiner les informations de diagnostic liées aux mises à jour Windows. |

Les informations exactes disponibles dépendent du système, des droits du compte et des résultats renvoyés par chaque module.

## Structure du projet

```text
Support-Diagnostic-Toolkit/
├── main.ps1                 # Menu principal
├── Remote.ps1               # Fonctions de diagnostic distant
├── Report.ps1               # Génération HTML et JSON
├── modules/
│   ├── EventLogs.ps1
│   ├── Network.ps1
│   ├── Performance.ps1
│   ├── Services.ps1
│   ├── Storage.ps1
│   ├── SystemInfo.ps1
│   └── WindowsUpdate.ps1
├── reports/                 # Rapports générés (ignorés par Git)
├── .gitignore
└── README.md
```

## Prérequis

- Un environnement **Windows** avec **Windows PowerShell 5.1** ou une version compatible de **PowerShell 7**.
- Les droits nécessaires pour consulter les informations demandées par les modules ; certaines opérations de lecture peuvent nécessiter une session élevée.
- Pour les diagnostics distants : un poste cible Windows accessible sur le réseau, **WinRM / PowerShell Remoting configuré**, des autorisations adaptées et des identifiants valides.

> La compatibilité doit être vérifiée selon les éditions et versions de Windows utilisées. Le projet a notamment été testé dans un environnement personnel avec des postes Windows 10 et Windows 11.

## Installation et démarrage

Récupérer le dépôt, puis ouvrir un terminal PowerShell à la racine du projet :

```powershell
cd .\Support-Diagnostic-Toolkit
.\main.ps1
```

Si l'exécution des scripts est bloquée, consulter d'abord la politique en vigueur :

```powershell
Get-ExecutionPolicy -List
```

Ne pas modifier globalement la politique d'exécution d'une machine administrée sans autorisation.

### Menu principal

```text
========================================
       SUPPORT DIAGNOSTIC TOOLKIT
========================================
[1] Diagnostic local
[2] Diagnostic distant (WinRM)
[3] Generer un rapport local complet
[4] Generer un rapport distant complet
[5] Consulter les rapports existants
[0] Quitter
```

Les options 1 et 2 permettent de consulter les diagnostics ; les options 3 et 4 exécutent les diagnostics et génèrent un rapport complet.

## Diagnostic distant avec WinRM

Le poste cible doit autoriser la gestion à distance PowerShell et être accessible depuis le poste qui lance l'outil. La configuration exacte dépend de l'environnement (domaine Active Directory ou groupe de travail, pare-feu, réseau privé, droits des comptes).

Sur un poste cible **dont vous êtes administrateur et que vous êtes autorisé à configurer**, une commande couramment utilisée est :

```powershell
Enable-PSRemoting -Force
```

Dans un environnement sans domaine, l'utilisation d'une adresse IP peut nécessiter une configuration spécifique de `TrustedHosts` ou une connexion WinRM en HTTPS. **Ne pas utiliser `TrustedHosts = *` par facilité** : limiter les hôtes autorisés et privilégier une configuration authentifiée et sécurisée.

Pour tester une connexion avec des identifiants saisis de manière interactive :

```powershell
$cred = Get-Credential
Test-WSMan -ComputerName "192.168.1.198"
```

`Test-WSMan` vérifie la disponibilité du service WinRM, **pas** à lui seul la réussite de l'authentification ou l'autorisation d'exécuter des commandes. Une vérification complète peut être réalisée avec `Invoke-Command` dans un environnement autorisé.

Ne jamais inscrire de mot de passe en clair dans les scripts ou dans le dépôt Git.

## Génération des rapports

Depuis le menu, sélectionner l'option **3** (local) ou **4** (distant). Il est également possible d'utiliser directement les fonctions du générateur :

```powershell
. .\Report.ps1
New-SDTReport -Mode Local -OpenHtml
```

Exemple de diagnostic distant :

```powershell
. .\Report.ps1
$cred = Get-Credential
New-SDTReport -Mode Remote -ComputerName "192.168.1.198" -Credential $cred -OpenHtml
```

Les fichiers sont enregistrés sous `reports/`, dans un dossier propre à la machine et à l'exécution :

```text
reports/
└── NOM-DU-PC/
    └── AAAA-MM-JJ_HHMMSS_xxxxxx/
        ├── diagnostic.html
        └── diagnostic.json
```

- **HTML :** synthèse et tableaux lisibles ; certaines listes volumineuses sont repliées ou abrégées.
- **JSON :** données structurées et détails collectés, utiles pour une analyse ultérieure.

**Remarque :** selon le contexte d'exécution et la résolution du nom distant, un dossier peut être nommé d'après l'adresse IP utilisée pour la connexion. Cela n'implique pas nécessairement un échec du diagnostic.

## Sécurité et confidentialité

Les rapports peuvent contenir des noms de machines, adresses IP, comptes, services, processus et événements système. Ils ne doivent pas être publiés sans vérification et anonymisation.

Le dossier `reports/` est exclu du suivi Git par `.gitignore`. Les fichiers de configuration et secrets locaux doivent également rester hors du dépôt.

L'outil vise une **collecte en lecture seule**. Son exécution doit se faire uniquement sur des ordinateurs dont vous avez l'autorisation de diagnostic.

## Limites connues

- Outil en console PowerShell ; aucune interface graphique dédiée.
- Interface et rapports en français.
- Le diagnostic distant dépend de la disponibilité de WinRM, du réseau, du pare-feu et des permissions.
- Certains indicateurs sont des **instantanés** : ils ne suffisent pas à établir à eux seuls la cause d'un incident.
- La mention **« Exécuté »** indique qu'un module a renvoyé des données ; elle **ne garantit pas** que le poste est sain.
- Les rapports HTML peuvent limiter l'affichage des listes volumineuses ; consulter le JSON pour les détails.
- L'organisation des dossiers distants peut parfois reprendre l'adresse IP plutôt que le nom Windows.
- Le projet n'effectue pas de correction automatique des problèmes détectés.

## Évolutions envisagées

- Comparaison de deux rapports (avant/après intervention).
- Association des diagnostics à des tickets de support.
- Règles de détection et synthèse des anomalies.
- Tests automatisés des fonctions PowerShell.
- Éventuelle interface graphique et documentation anglaise.

## Contexte du projet

Projet personnel de mise en pratique de **PowerShell**, du **diagnostic Windows**, de **WinRM**, de la **structuration de scripts** et du **versionnement avec Git** dans une perspective de support informatique N1/N2.

---

*Support Diagnostic Toolkit — documentation de la version 3 du menu et de la génération de rapports.*
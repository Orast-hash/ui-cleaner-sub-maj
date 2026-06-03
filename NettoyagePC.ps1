<#
================================================================
  NettoyagePC - Outil de nettoyage systeme pour Windows
================================================================
  Outil leger, sans installation, a deployer sur les PC clients.
  Mode prudent : ne supprime que des fichiers reellement jetables
  (temporaires, caches navigateurs, corbeille, miniatures, etc.).
  Ne touche jamais aux documents, mots de passe ou parametres.

  Utilisation :
    1. Clic droit sur le fichier > "Executer avec PowerShell"
       (idealement en tant qu'administrateur pour le nettoyage complet)
    2. Coche les categories voulues
    3. "Analyser" pour estimer l'espace recuperable
    4. "Nettoyer" pour lancer

  Si Windows bloque le script :
    PowerShell (admin) > Set-ExecutionPolicy -Scope Process Bypass
================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# NETTOYAGEPC-SIGNATURE  (ne pas retirer : utilise par le lanceur pour valider la mise a jour)

# ---- Personnalisation ----
$NomEntreprise   = "Urgence Informatique"
$Version         = "1.4.1"
# Generer le rapport sur le Bureau apres nettoyage ? ($true / $false)
$GenererRapport  = $false
# Memoire virtuelle : taille calculee selon la RAM du poste.
#   taille (Mo) = RAM x facteur, bornee entre plancher et plafond.
$PageFileFacteur  = 1.5
$PageFilePlancher = 2048
$PageFilePlafond  = 8192
# URL du petit fichier version.txt (pour afficher le statut a jour / obsolete).
# Mets la meme adresse que dans Lanceur.ps1.
$UrlVersion    = "https://raw.githubusercontent.com/Orast-hash/ui-cleaner-sub-maj/refs/heads/main/version.txt"

# ---- Contrats de maintenance (licence) ----
# Liste des clients actifs hebergee sur GitHub (un ID par ligne, format ID;Nom)
$UrlClients = "https://raw.githubusercontent.com/ton-compte/ton-depot/main/clients.txt"
# Fichier contenant le numero du client, ecrit sur CE poste a l'installation
$FichierID  = "C:\ProgramData\Urgence Informatique\client.id"
# Tolerance hors-ligne (en jours) avant de bloquer si la liste est injoignable
$GraceJours = 14

# ---- État de santé : derniere version de Windows 11 connue ----
# A mettre a jour quand Microsoft publie une nouvelle version (env. 1x/an).
# Sert a indiquer "A JOUR" ou "mise a niveau disponible".
$DerniereVersionWin11 = "25H2"
# --------------------------

# Detection des droits administrateur
$EstAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$Journal = New-Object System.Collections.Generic.List[string]

# Calcule la taille conseillee de la memoire virtuelle d'apres la RAM du poste
function Get-TaillePageFile {
    $ramMo = 4096
    try {
        $ramMo = [math]::Round((Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    } catch { }
    $t = [math]::Round($ramMo * $PageFileFacteur)
    if ($t -lt $PageFilePlancher) { $t = $PageFilePlancher }
    if ($t -gt $PageFilePlafond)  { $t = $PageFilePlafond }
    return [int]$t
}
$PageFileMo = Get-TaillePageFile

# Espace libre (octets) sur le lecteur systeme - sert a mesurer le gain
# des operations qui ne se comptent pas fichier par fichier (DISM, etc.)
function Get-FreeBytes {
    try {
        $d = ($env:SystemDrive).TrimEnd(':')
        return (Get-PSDrive -Name $d -ErrorAction SilentlyContinue).Free
    } catch { return 0L }
}

# ================================================================
#  Definition des categories de nettoyage
#  Chaque categorie = un nom + une liste de chemins/dossiers
#  + un indicateur "admin requis"
# ================================================================
function Get-Categories {
    $local   = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    $temp    = $env:TEMP

    $cats = [ordered]@{}

    $cats["Fichiers temporaires (utilisateur)"] = @{
        Admin   = $false
        Chemins = @($temp)
    }

    $cats["Fichiers temporaires Windows"] = @{
        Admin   = $true
        Chemins = @("$env:WINDIR\Temp")
    }

    $cats["Corbeille"] = @{
        Admin     = $false
        Corbeille = $true
    }

    $cats["Cache miniatures (thumbnails)"] = @{
        Admin   = $false
        Chemins = @("$local\Microsoft\Windows\Explorer")
        Filtre  = "thumbcache_*.db"
    }

    $cats["Cache Google Chrome"] = @{
        Admin   = $false
        Chemins = @(
            "$local\Google\Chrome\User Data\*\Cache",
            "$local\Google\Chrome\User Data\*\Code Cache",
            "$local\Google\Chrome\User Data\*\GPUCache"
        )
    }

    $cats["Cache Microsoft Edge"] = @{
        Admin   = $false
        Chemins = @(
            "$local\Microsoft\Edge\User Data\*\Cache",
            "$local\Microsoft\Edge\User Data\*\Code Cache",
            "$local\Microsoft\Edge\User Data\*\GPUCache"
        )
    }

    $cats["Cache Mozilla Firefox"] = @{
        Admin   = $false
        Chemins = @("$local\Mozilla\Firefox\Profiles\*\cache2")
    }

    $cats["Cache Windows Update"] = @{
        Admin   = $true
        Chemins = @("$env:WINDIR\SoftwareDistribution\Download")
    }

    $cats["Rapports d'erreurs Windows"] = @{
        Admin   = $false
        Chemins = @(
            "$local\Microsoft\Windows\WER",
            "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
        )
    }

    $cats["Prefetch Windows"] = @{
        Admin   = $true
        Chemins = @("$env:WINDIR\Prefetch")
    }

    $cats["Désactiver la veille prolongée (libère de l'espace)"] = @{
        Admin       = $true
        Hibernation = $true
    }

    $cats["Mémoire virtuelle : taille fixée selon la RAM ($PageFileMo Mo)"] = @{
        Admin    = $true
        PageFile = $true
    }

    $cats["Nettoyer le composant Windows (WinSxS / maj obsolètes)"] = @{
        Admin  = $true
        WinSxS = $true
        Defaut = $false
    }

    $cats["Supprimer Windows.old (ancienne installation)"] = @{
        Admin      = $true
        WindowsOld = $true
        Defaut     = $false
    }

    return $cats
}

# ================================================================
#  Calcul de la taille recuperable d'une categorie (sans rien
#  supprimer). Retourne un nombre d'octets.
# ================================================================
function Measure-Categorie($cat) {
    $total = 0L

    if ($cat.Hibernation) {
        # Espace recuperable = taille du fichier hiberfil.sys
        $h = "$env:SystemDrive\hiberfil.sys"
        if (Test-Path $h) {
            try { return (Get-Item $h -Force -ErrorAction SilentlyContinue).Length } catch { return 0L }
        }
        return 0L
    }

    if ($cat.PageFile) {
        # Reglage de configuration : pas d'espace mesurable a l'analyse
        return 0L
    }

    if ($cat.WindowsOld) {
        # Taille approximative du dossier Windows.old s'il existe
        $wo = "$env:SystemDrive\Windows.old"
        if (Test-Path $wo) {
            try {
                return (Get-ChildItem $wo -Recurse -Force -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum).Sum
            } catch { return 0L }
        }
        return 0L
    }

    if ($cat.WinSxS) {
        # Operation systeme : le gain reel est mesure apres coup
        # (espace disque libere). Pas d'estimation fiable a l'analyse.
        return 0L
    }

    if ($cat.Corbeille) {
        # Estimation de la taille de la corbeille
        try {
            $shell = New-Object -ComObject Shell.Application
            $bin = $shell.NameSpace(0x0a)
            foreach ($item in $bin.Items()) {
                $total += [int64]$item.Size
            }
        } catch {}
        return $total
    }

    foreach ($pattern in $cat.Chemins) {
        $dossiers = Get-Item -Path $pattern -ErrorAction SilentlyContinue
        foreach ($d in $dossiers) {
            if (-not (Test-Path $d.FullName)) { continue }
            $filtre = if ($cat.Filtre) { $cat.Filtre } else { "*" }
            $fichiers = Get-ChildItem -Path $d.FullName -Filter $filtre `
                -Recurse -Force -File -ErrorAction SilentlyContinue
            $compteur = 0
            foreach ($f in $fichiers) {
                $total += $f.Length
                # Garde la fenetre reactive (sinon elle se "fige" quand un
                # antivirus ralentit fortement le parcours des fichiers)
                $compteur++
                if (($compteur % 100) -eq 0) {
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        }
    }
    return $total
}

# ================================================================
#  Lance un programme externe en gardant la fenetre reactive
#  (la fleche continue de tourner pendant que le programme tourne).
# ================================================================
function Invoke-ProcessReactif($fichier, $arguments) {
    try {
        $p = Start-Process -FilePath $fichier -ArgumentList $arguments `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
        }
        return $p.ExitCode
    } catch {
        return -1
    }
}

# ================================================================
#  Nettoyage effectif d'une categorie. Retourne les octets liberes.
# ================================================================
function Clear-Categorie($nom, $cat) {

    if ($cat.Hibernation) {
        $avant = Measure-Categorie $cat
        try {
            & "$env:WINDIR\System32\powercfg.exe" -h off | Out-Null
            Start-Sleep -Milliseconds 800
            $apres  = Measure-Categorie $cat
            $libere = [math]::Max(0, $avant - $apres)
            $Journal.Add("  [OK] Veille prolongée désactivée : $(Format-Taille $libere) libérés")
            return $libere
        } catch {
            $Journal.Add("  [!]  Veille prolongée : $($_.Exception.Message)")
            return 0L
        }
    }

    if ($cat.PageFile) {
        try {
            $cs = Get-WmiObject -Class Win32_ComputerSystem
            if ($cs.AutomaticManagedPagefile) {
                $cs.AutomaticManagedPagefile = $false
                [void]$cs.Put()
            }
            $pf = Get-WmiObject -Class Win32_PageFileSetting
            if (-not $pf) {
                Set-WmiInstance -Class Win32_PageFileSetting `
                    -Arguments @{ Name = "$env:SystemDrive\pagefile.sys" } | Out-Null
                $pf = Get-WmiObject -Class Win32_PageFileSetting
            }
            foreach ($p in $pf) {
                $p.InitialSize = $PageFileMo
                $p.MaximumSize = $PageFileMo
                [void]$p.Put()
            }
            $Journal.Add("  [OK] Mémoire virtuelle fixée à $PageFileMo Mo (effet au redémarrage)")
        } catch {
            $Journal.Add("  [!]  Mémoire virtuelle : $($_.Exception.Message)")
        }
        return 0L
    }

    if ($cat.WinSxS) {
        # Methode SURE et recommandee par Microsoft : DISM.
        # On ne supprime JAMAIS de fichiers a la main dans WinSxS.
        # Pas de /ResetBase (qui empecherait de desinstaller les maj).
        $libreAvant = Get-FreeBytes
        try {
            # DISM lance en arriere-plan : la fenetre et la fleche restent
            # actives meme si l'operation dure plusieurs minutes.
            Invoke-ProcessReactif "$env:WINDIR\System32\Dism.exe" `
                @("/Online", "/Cleanup-Image", "/StartComponentCleanup") | Out-Null
            $gagne = [math]::Max(0, (Get-FreeBytes) - $libreAvant)
            $Journal.Add("  [OK] Composant Windows nettoyé (DISM) : $(Format-Taille $gagne) libérés")
            return $gagne
        } catch {
            $Journal.Add("  [!]  Composant Windows (DISM) : $($_.Exception.Message)")
            return 0L
        }
    }

    if ($cat.WindowsOld) {
        $wo = "$env:SystemDrive\Windows.old"
        if (-not (Test-Path $wo)) {
            $Journal.Add("  [i]  Windows.old : absent (rien à supprimer)")
            return 0L
        }
        $libreAvant = Get-FreeBytes
        try {
            # Dossier protege (TrustedInstaller) : prise de possession requise.
            # "< nul" evite tout blocage sur une invite (Windows localise) ;
            # on cible le groupe Administrateurs par son SID (independant de la langue).
            & cmd.exe /c "takeown /F `"$wo`" /A /R /D Y < nul" 2>&1 | Out-Null
            & icacls "$wo" /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
            & cmd.exe /c "rd /s /q `"$wo`"" 2>&1 | Out-Null
            $gagne = [math]::Max(0, (Get-FreeBytes) - $libreAvant)
            if (Test-Path $wo) {
                $Journal.Add("  [!]  Windows.old : suppression partielle ($(Format-Taille $gagne))")
            } else {
                $Journal.Add("  [OK] Windows.old supprimé : $(Format-Taille $gagne) libérés")
            }
            return $gagne
        } catch {
            $Journal.Add("  [!]  Windows.old : $($_.Exception.Message)")
            return 0L
        }
    }

    if ($cat.Corbeille) {
        $avant = Measure-Categorie $cat
        try {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            $Journal.Add("  [OK] Corbeille vidée")
        } catch {
            $Journal.Add("  [!]  Corbeille : $($_.Exception.Message)")
        }
        return $avant
    }

    $libere   = 0L
    $compteur = 0
    foreach ($pattern in $cat.Chemins) {
        $dossiers = Get-Item -Path $pattern -ErrorAction SilentlyContinue
        foreach ($d in $dossiers) {
            if (-not (Test-Path $d.FullName)) { continue }
            $filtre = if ($cat.Filtre) { $cat.Filtre } else { "*" }
            # Une seule passe : on additionne la taille et on supprime dans la
            # foulee (plus rapide, et la fenetre reste reactive via DoEvents).
            Get-ChildItem -Path $d.FullName -Filter $filtre `
                -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $libere += $_.Length
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    $compteur++
                    if (($compteur % 100) -eq 0) {
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                }
            # Suppression des sous-dossiers vides (sauf le dossier racine)
            if (-not $cat.Filtre) {
                Get-ChildItem -Path $d.FullName -Recurse -Force -Directory `
                    -ErrorAction SilentlyContinue |
                    Sort-Object { $_.FullName.Length } -Descending |
                    ForEach-Object {
                        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }

    $Journal.Add("  [OK] $nom : $(Format-Taille $libere) libérés")
    return $libere
}

# Formatage lisible d'une taille en octets
function Format-Taille([int64]$octets) {
    if ($octets -ge 1GB) { return "{0:N2} Go" -f ($octets / 1GB) }
    if ($octets -ge 1MB) { return "{0:N1} Mo" -f ($octets / 1MB) }
    if ($octets -ge 1KB) { return "{0:N0} Ko" -f ($octets / 1KB) }
    return "$octets o"
}

# ================================================================
#  Verifie en ligne s'il existe une version plus recente et
#  renvoie un texte + une couleur pour l'afficher au lancement.
# ================================================================
function Get-StatutVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $brut = (Invoke-WebRequest -Uri $UrlVersion -UseBasicParsing -TimeoutSec 5).Content
        $distante = (($brut -split "`n")[0]).Trim()
        if ([version]$distante -gt [version]$Version) {
            return @{
                Texte   = "v$Version - MAJ DISPO ($distante)"
                Couleur = [System.Drawing.Color]::FromArgb(190, 90, 0)
            }
        } else {
            return @{
                Texte   = "v$Version - À JOUR"
                Couleur = [System.Drawing.Color]::FromArgb(20, 120, 70)
            }
        }
    } catch {
        return @{
            Texte   = "v$Version"
            Couleur = [System.Drawing.Color]::Gray
        }
    }
}

# ================================================================
#  Verification du contrat de maintenance (licence).
#  - ID du client present dans la liste distante -> autorise
#  - ID absent                                    -> bloque (contrat fini)
#  - liste injoignable (hors-ligne)               -> tolerance de
#    $GraceJours jours selon le dernier controle reussi
# ================================================================
function Test-Licence {
    $cacheLic = Join-Path $env:LOCALAPPDATA "NettoyagePC\licence.txt"

    # Pas de numero configure sur ce poste : on laisse passer mais on le note
    if (-not (Test-Path $FichierID)) {
        return @{ Bloque = $false; Note = "poste non enregistré" }
    }
    $id = ((Get-Content -Path $FichierID -TotalCount 1) -as [string]).Trim()
    if (-not $id) {
        return @{ Bloque = $false; Note = "poste non enregistré" }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $brut = (Invoke-WebRequest -Uri $UrlClients -UseBasicParsing -TimeoutSec 10).Content
        $actifs = $brut -split "`n" |
            Where-Object { $_ -and $_ -notmatch '^\s*#' } |
            ForEach-Object { (($_ -split ';')[0]).Trim() }

        if ($actifs -contains $id) {
            Set-Content -Path $cacheLic -Value ("actif;" + (Get-Date -Format "yyyy-MM-dd")) -Encoding UTF8
            return @{ Bloque = $false }
        } else {
            Set-Content -Path $cacheLic -Value ("inactif;" + (Get-Date -Format "yyyy-MM-dd")) -Encoding UTF8
            return @{ Bloque = $true; Raison = "contrat" }
        }
    } catch {
        # Hors-ligne : on s'appuie sur le dernier controle connu
        if (Test-Path $cacheLic) {
            $parts  = ((Get-Content $cacheLic -TotalCount 1) -split ';')
            $statut = $parts[0].Trim()
            $date   = $null
            try { $date = [datetime]::ParseExact($parts[1].Trim(), "yyyy-MM-dd", $null) } catch {}
            if ($statut -eq "inactif") {
                return @{ Bloque = $true; Raison = "contrat" }
            }
            if ($date -and ((Get-Date) - $date).Days -le $GraceJours) {
                return @{ Bloque = $false; Note = "hors-ligne" }
            }
            return @{ Bloque = $true; Raison = "verif" }
        }
        # Aucun controle anterieur : premier lancement hors-ligne, tolere
        return @{ Bloque = $false; Note = "hors-ligne" }
    }
}

# ================================================================
#  Enregistrement d'un rapport texte sur le Bureau.
#  Le rapport indique clairement au client qu'il est informatif
#  et qu'il peut etre supprime sans risque.
# ================================================================
function Write-Rapport($lignes, $total) {
    $horodatage  = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $dateLisible = Get-Date -Format "dd/MM/yyyy 'à' HH:mm"
    $bureau = [Environment]::GetFolderPath("Desktop")
    $chemin = Join-Path $bureau "Rapport-nettoyage_$horodatage.txt"
    $sep = "=" * 58

    $c = New-Object System.Collections.Generic.List[string]
    $c.Add($sep)
    $c.Add("   RAPPORT DE NETTOYAGE  -  $NomEntreprise")
    $c.Add($sep)
    $c.Add("")
    $c.Add("   >>> CE RAPPORT EST PUREMENT INFORMATIF <<<")
    $c.Add("")
    $c.Add("   Vous pouvez SUPPRIMER ce fichier sans aucun risque.")
    $c.Add("   Aucune action n'est requise de votre part.")
    $c.Add("   Il ne contient aucune donnée personnelle.")
    $c.Add("")
    $c.Add($sep)
    $c.Add("   Date du nettoyage : $dateLisible")
    $c.Add("   Ordinateur        : $env:COMPUTERNAME")
    $c.Add("   Session Windows   : $env:USERNAME")
    $c.Add($sep)
    $c.Add("")
    $c.Add("   Détail des opérations effectuées :")
    $c.Add("")
    foreach ($l in $lignes) { $c.Add("     $l") }
    $c.Add("")
    $c.Add($sep)
    $c.Add(("   ESPACE TOTAL LIBÉRÉ : {0}" -f (Format-Taille $total)))
    $c.Add($sep)
    $c.Add("")
    $c.Add("   Rappel : ce fichier n'est qu'un compte-rendu du")
    $c.Add("   nettoyage. Vous pouvez le jeter à la corbeille.")
    $c.Add("")
    $c.Add("   $NomEntreprise")

    try {
        $c | Out-File -FilePath $chemin -Encoding UTF8 -ErrorAction Stop
        return $chemin
    } catch {
        return $null
    }
}

# ================================================================
#  État de santé du PC : version Windows + a jour, disque, RAM,
#  sante des disques. Renvoie un texte multi-lignes.
# ================================================================
function Get-EtatSante {
    $lignes = New-Object System.Collections.Generic.List[string]

    # --- Windows : version et statut de mise a jour ---
    try {
        $rk = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        $p  = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
        $build = [int]$p.CurrentBuild
        $ubr   = $p.UBR
        $disp  = $p.DisplayVersion
        if (-not $disp) { $disp = $p.ReleaseId }
        $famille = if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }
        $verTxt  = "$famille $disp (build $build.$ubr)"

        if ($famille -eq "Windows 10") {
            $lignes.Add("Windows : $verTxt")
            $lignes.Add("   Windows 10 : fin de support depuis octobre 2025 (migration conseillée)")
        } else {
            $cur = 0; $last = 0
            if ($disp -match '^(\d+)H(\d+)$') { $cur  = [int]$matches[1]*10 + [int]$matches[2] }
            if ($DerniereVersionWin11 -match '^(\d+)H(\d+)$') { $last = [int]$matches[1]*10 + [int]$matches[2] }
            if ($cur -gt 0 -and $cur -ge $last) {
                $lignes.Add("Windows : $verTxt - À JOUR")
            } else {
                $lignes.Add("Windows : $verTxt")
                $lignes.Add("   Mise à niveau disponible (dernière version : $DerniereVersionWin11)")
            }
        }
    } catch {
        $lignes.Add("Windows : version indéterminée")
    }

    # --- Espace disque systeme ---
    try {
        $sysName = ($env:SystemDrive).TrimEnd(':')
        $dr = Get-PSDrive -Name $sysName -ErrorAction SilentlyContinue
        $libre = [int64]$dr.Free
        $total = [int64]$dr.Free + [int64]$dr.Used
        $pct = if ($total -gt 0) { [math]::Round(100 * $libre / $total) } else { 0 }
        $lignes.Add("Disque $($env:SystemDrive) : $(Format-Taille $libre) libres sur $(Format-Taille $total) ($pct% libre)")
    } catch {}

    # --- Memoire vive ---
    try {
        $ram = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
        if ($ram) { $lignes.Add("Mémoire vive (RAM) : $(Format-Taille $ram)") }
    } catch {}

    # --- Sante des disques (SMART simplifie) ---
    try {
        $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        foreach ($d in $disks) {
            $type = if ($d.MediaType) { "$($d.MediaType)" } else { "Disque" }
            $sante = switch ("$($d.HealthStatus)") {
                "Healthy"   { "Sain" }
                "Warning"   { "À surveiller" }
                "Unhealthy" { "Défaillant" }
                default     { "$($d.HealthStatus)" }
            }
            $lignes.Add("Disque ($($d.FriendlyName)) : $type - état $sante")
        }
    } catch {}

    return ($lignes -join "`r`n")
}

# ================================================================
#  Construction de l'interface graphique
# ================================================================
$categories = Get-Categories

# --- Controle du contrat de maintenance avant d'ouvrir l'outil ---
$licence = Test-Licence
if ($licence.Bloque) {
    if ($licence.Raison -eq "verif") {
        $msgLic = "Impossible de vérifier votre licence Urgence Informatique.`n`n" +
                  "Merci de connecter ce poste à internet, puis de relancer.`n`n" +
                  "Si le problème persiste, contactez-nous."
    } else {
        $msgLic = "Votre contrat de maintenance Urgence Informatique a pris fin.`n`n" +
                  "Ce logiciel est désormais désactivé.`n`n" +
                  "Contactez-nous pour renouveler votre souscription " +
                  "et réactiver le logiciel."
    }
    [System.Windows.Forms.MessageBox]::Show($msgLic, "Urgence Informatique - Licence", "OK", "Warning") | Out-Null
    return
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "NettoyagePC v$Version - $NomEntreprise"
$form.Size = New-Object System.Drawing.Size(520, 645)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Bandeau titre
$titre = New-Object System.Windows.Forms.Label
$titre.Text = "Nettoyage du système"
$titre.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$titre.ForeColor = [System.Drawing.Color]::FromArgb(30, 60, 110)
$titre.Location = New-Object System.Drawing.Point(20, 15)
$titre.Size = New-Object System.Drawing.Size(290, 32)
$form.Controls.Add($titre)

# Statut de version (a jour / mise a jour dispo), affiche au lancement
$statut = Get-StatutVersion
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = $statut.Texte
$lblVersion.ForeColor = $statut.Couleur
$lblVersion.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblVersion.TextAlign = "MiddleRight"
$lblVersion.Location = New-Object System.Drawing.Point(300, 22)
$lblVersion.Size = New-Object System.Drawing.Size(190, 22)
if ($licence.Note) { $lblVersion.Text = $lblVersion.Text + " - " + $licence.Note }
$form.Controls.Add($lblVersion)

# Avertissement droits admin
$lblAdmin = New-Object System.Windows.Forms.Label
if ($EstAdmin) {
    $lblAdmin.Text = "Mode administrateur : nettoyage complet disponible."
    $lblAdmin.ForeColor = [System.Drawing.Color]::FromArgb(20, 110, 70)
} else {
    $lblAdmin.Text = "Mode standard. Pour le nettoyage système complet, relancez en tant qu'administrateur."
    $lblAdmin.ForeColor = [System.Drawing.Color]::FromArgb(160, 80, 0)
}
$lblAdmin.Location = New-Object System.Drawing.Point(20, 48)
$lblAdmin.Size = New-Object System.Drawing.Size(470, 30)
$form.Controls.Add($lblAdmin)

# Zone des cases a cocher
$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(20, 82)
$panel.Size = New-Object System.Drawing.Size(470, 300)
$panel.BackColor = [System.Drawing.Color]::White
$panel.BorderStyle = "FixedSingle"
$panel.AutoScroll = $true
$form.Controls.Add($panel)

$checkboxes = @{}
$y = 10
foreach ($nom in $categories.Keys) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $nom
    $cb.Location = New-Object System.Drawing.Point(12, $y)
    $cb.Size = New-Object System.Drawing.Size(440, 24)
    $cb.Checked = $true
    # Categories sensibles (systeme) : decochees par defaut
    if ($categories[$nom].ContainsKey('Defaut') -and -not $categories[$nom].Defaut) {
        $cb.Checked = $false
    }

    if ($categories[$nom].Admin -and -not $EstAdmin) {
        $cb.Enabled = $false
        $cb.Checked = $false
        $cb.Text = "$nom  (admin requis)"
        $cb.ForeColor = [System.Drawing.Color]::Gray
    }

    $panel.Controls.Add($cb)
    $checkboxes[$nom] = $cb
    $y += 26
}

# Etiquette de resultat
$lblResultat = New-Object System.Windows.Forms.Label
$lblResultat.Text = ""
$lblResultat.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblResultat.ForeColor = [System.Drawing.Color]::FromArgb(30, 60, 110)
$lblResultat.Location = New-Object System.Drawing.Point(20, 392)
$lblResultat.Size = New-Object System.Drawing.Size(470, 26)
$lblResultat.TextAlign = "MiddleCenter"
$form.Controls.Add($lblResultat)

# Zone de journal
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object System.Drawing.Point(20, 422)
$txtLog.Size = New-Object System.Drawing.Size(470, 95)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$form.Controls.Add($txtLog)

# Barre de progression
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(20, 525)
$progress.Size = New-Object System.Drawing.Size(440, 18)
$form.Controls.Add($progress)

# Indicateur d'activite (petite fleche qui tourne) a cote de la barre
$script:spinAngle = 0
$spinner = New-Object System.Windows.Forms.Panel
$spinner.Location = New-Object System.Drawing.Point(468, 523)
$spinner.Size = New-Object System.Drawing.Size(22, 22)
$spinner.Visible = $false
$spinner.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(30, 110, 200), 3)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $rect = New-Object System.Drawing.Rectangle(3, 3, 15, 15)
    $g.DrawArc($pen, $rect, $script:spinAngle, 270)
    $pen.Dispose()
})
$form.Controls.Add($spinner)

$spinTimer = New-Object System.Windows.Forms.Timer
$spinTimer.Interval = 80
$spinTimer.Add_Tick({
    $script:spinAngle = ($script:spinAngle + 30) % 360
    $spinner.Invalidate()
})

# Demarre / arrete l'indicateur d'activite
function Start-Spinner {
    $spinner.Visible = $true
    $spinTimer.Start()
}
function Stop-Spinner {
    $spinTimer.Stop()
    $spinner.Visible = $false
}

# Boutons
$btnAnalyser = New-Object System.Windows.Forms.Button
$btnAnalyser.Text = "Analyser"
$btnAnalyser.Location = New-Object System.Drawing.Point(20, 553)
$btnAnalyser.Size = New-Object System.Drawing.Size(112, 36)
$btnAnalyser.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($btnAnalyser)

$btnSante = New-Object System.Windows.Forms.Button
$btnSante.Text = "État de santé"
$btnSante.Location = New-Object System.Drawing.Point(138, 553)
$btnSante.Size = New-Object System.Drawing.Size(112, 36)
$btnSante.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($btnSante)

$btnNettoyer = New-Object System.Windows.Forms.Button
$btnNettoyer.Text = "Nettoyer"
$btnNettoyer.Location = New-Object System.Drawing.Point(256, 553)
$btnNettoyer.Size = New-Object System.Drawing.Size(112, 36)
$btnNettoyer.BackColor = [System.Drawing.Color]::FromArgb(30, 110, 200)
$btnNettoyer.ForeColor = [System.Drawing.Color]::White
$btnNettoyer.FlatStyle = "Flat"
$form.Controls.Add($btnNettoyer)

$btnFermer = New-Object System.Windows.Forms.Button
$btnFermer.Text = "Fermer"
$btnFermer.Location = New-Object System.Drawing.Point(374, 553)
$btnFermer.Size = New-Object System.Drawing.Size(112, 36)
$btnFermer.BackColor = [System.Drawing.Color]::White
$btnFermer.Add_Click({ $form.Close() })
$form.Controls.Add($btnFermer)

# Bouton État de santé : affiche un bilan rapide du PC
$btnSante.Add_Click({
    $btnSante.Enabled = $false
    $ancien = $lblResultat.Text
    $lblResultat.Text = "Analyse de l'état du PC..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $bilan = Get-EtatSante
        [System.Windows.Forms.MessageBox]::Show($bilan, "État de santé du PC - $NomEntreprise",
            "OK", "Information") | Out-Null
        $lblResultat.Text = $ancien
    } finally {
        $btnSante.Enabled = $true
    }
})

# ---- Action : Analyser ----
$btnAnalyser.Add_Click({
    $txtLog.Clear()
    $Journal.Clear()
    $coches = $checkboxes.Keys | Where-Object { $checkboxes[$_].Checked }
    if (-not $coches) {
        [System.Windows.Forms.MessageBox]::Show("Aucune catégorie sélectionnée.", "Info")
        return
    }
    $btnAnalyser.Enabled = $false
    $btnNettoyer.Enabled = $false
    $btnFermer.Enabled   = $false
    $lblResultat.Text = "Analyse en cours..."
    Start-Spinner
    try {
        $progress.Maximum = @($coches).Count
        $progress.Value = 0
        $totalEstime = 0L
        foreach ($nom in $coches) {
            $taille = Measure-Categorie $categories[$nom]
            $totalEstime += $taille
            $txtLog.AppendText("$nom : $(Format-Taille $taille)`r`n")
            $progress.Value++
            [System.Windows.Forms.Application]::DoEvents()
        }
        $lblResultat.Text = "Espace récupérable estimé : $(Format-Taille $totalEstime)"
        $progress.Value = 0
    } finally {
        Stop-Spinner
        $btnAnalyser.Enabled = $true
        $btnNettoyer.Enabled = $true
        $btnFermer.Enabled   = $true
    }
})

# ---- Action : Nettoyer ----
$btnNettoyer.Add_Click({
    $coches = $checkboxes.Keys | Where-Object { $checkboxes[$_].Checked }
    if (-not $coches) {
        [System.Windows.Forms.MessageBox]::Show("Aucune catégorie sélectionnée.", "Info")
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Avant de lancer le nettoyage, fermez vos applications " +
        "et vos navigateurs (Chrome, Edge, Firefox...).`n`n" +
        "Enregistrez votre travail en cours, puis cliquez sur OK.`n`n" +
        "Si une application reste ouverte, son cache pourra ne pas " +
        "être entièrement nettoyé.",
        "Fermez vos applications", "OKCancel", "Warning")
    if ($confirm -ne "OK") { return }

    $txtLog.Clear()
    $Journal.Clear()

    $btnAnalyser.Enabled = $false
    $btnNettoyer.Enabled = $false
    $btnFermer.Enabled   = $false
    $lblResultat.Text = "Nettoyage en cours..."
    Start-Spinner
    try {
        $progress.Maximum = @($coches).Count
        $progress.Value = 0
        $totalLibere = 0L

        foreach ($nom in $coches) {
            if ($categories[$nom].WinSxS -or $categories[$nom].WindowsOld) {
                $lblResultat.Text = "Nettoyage : $nom (peut durer plusieurs minutes)..."
            } else {
                $lblResultat.Text = "Nettoyage : $nom..."
            }
            [System.Windows.Forms.Application]::DoEvents()
            $libere = Clear-Categorie $nom $categories[$nom]
            $totalLibere += $libere
            $progress.Value++
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Vidage du cache DNS (toujours sans risque)
        try { ipconfig /flushdns | Out-Null; $Journal.Add("  [OK] Cache DNS vide") } catch {}

        $txtLog.Text = ($Journal -join "`r`n")
        $lblResultat.Text = "Terminé. Espace libéré : $(Format-Taille $totalLibere)"
        $progress.Value = 0
    } finally {
        Stop-Spinner
        $btnAnalyser.Enabled = $true
        $btnNettoyer.Enabled = $true
        $btnFermer.Enabled   = $true
    }

    $cheminRapport = $null
    if ($GenererRapport) {
        $cheminRapport = Write-Rapport $Journal $totalLibere
    }

    # Un redemarrage est-il necessaire (memoire virtuelle modifiee) ?
    $redemarrage = ($Journal | Where-Object { $_ -match "Memoire virtuelle fixee" }).Count -gt 0
    $suffixe = if ($redemarrage) { "`n`nUn redémarrage est nécessaire pour appliquer la mémoire virtuelle." } else { "" }

    if ($cheminRapport) {
        [System.Windows.Forms.MessageBox]::Show(
            ("Nettoyage terminé.`nEspace libéré : {0}`n`n" -f (Format-Taille $totalLibere)) +
            "Un rapport a été enregistré sur le Bureau :`n$cheminRapport" + $suffixe,
            "$NomEntreprise", "OK", "Information")
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            ("Nettoyage terminé.`nEspace libéré : {0}" -f (Format-Taille $totalLibere)) + $suffixe,
            "$NomEntreprise", "OK", "Information")
    }
})

# Affichage
[void]$form.ShowDialog()

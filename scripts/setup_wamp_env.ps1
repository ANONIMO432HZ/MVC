<#
.SYNOPSIS
    Automates WAMP PHP CLI configuration, enables required extensions (zip, gd, mbstring, etc.),
    cleans conflicting PHP versions from both System (Machine) and User PATH, configures PowerShell profiles,
    verifies/creates MySQL database, creates pre-change backups, and provides automatic rollback capabilities.

.DESCRIPTION
    - Takes a snapshot of Machine PATH, User PATH, php.ini files, and PowerShell profiles before any modification.
    - Discovers WAMP and PHP installations across all drives agnostically.
    - Purges conflicting/outdated PHP paths from both Machine PATH and User PATH.
    - Prepend target PHP at position 0 to guarantee priority.
    - Configures php.ini and phpForApache.ini (extension_dir and required extensions).
    - Updates PowerShell profile ($PROFILE) as a secondary safety layer.
    - Verifies local MySQL connection and ensures the application database exists.
    - Runs composer install in the project root directory.
    - Broadcasts Windows WM_SETTINGCHANGE to notify running shells and Explorer.
    - Includes full -Rollback support to restore the previous state at any time.
    - Detailed persistent logging to setup_wamp_env.log.
#>

[CmdletBinding()]
param(
    [string]$WampPhpBaseDir = "",
    [string]$TargetPhpVersion = "",
    [switch]$RunComposerInstall,
    [switch]$NonInteractive,
    [switch]$NoElevate,
    [switch]$Rollback
)

Set-StrictMode -Off
$ErrorActionPreference = "Continue"

# --- 0. Self-Bypass Execution Policy ---
try {
    $policy = $null
    if (Get-Command Get-ExecutionPolicy -ErrorAction SilentlyContinue) {
        $policy = Get-ExecutionPolicy -Scope Process -ErrorAction SilentlyContinue
        if ($null -eq $policy -or $policy -eq 'Undefined') {
            $policy = Get-ExecutionPolicy -ErrorAction SilentlyContinue
        }
    }
    if ($policy -in @('Restricted', 'AllSigned')) {
        Write-Host "[*] Elevando ExecutionPolicy a Bypass para este script..." -ForegroundColor Cyan
        $processArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $args
        Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs -NoNewWindow -Wait
        exit $LASTEXITCODE
    }
} catch {}

# --- 1. Paths & Logging Setup ---
$scriptDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = Get-Location }

# Determine project root (checks current dir, parent, or where composer.json is located)
$projectRoot = $scriptDir
if (Test-Path -Path (Join-Path $scriptDir "composer.json")) {
    $projectRoot = $scriptDir
} elseif (Test-Path -Path (Join-Path (Split-Path -Parent $scriptDir) "composer.json")) {
    $projectRoot = Split-Path -Parent $scriptDir
} elseif (Test-Path -Path (Join-Path (Get-Location) "composer.json")) {
    $projectRoot = Get-Location
}

$logFile = Join-Path $scriptDir "setup_wamp_env.log"
$backupsBaseDir = Join-Path $scriptDir "backups"

$initHeader = @"
================================================================================
  WAMP PHP & Composer Environment Setup Log
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Host: $env:COMPUTERNAME | Usuario: $env:USERNAME | Modo: $(if ($Rollback) { 'ROLLBACK' } else { 'SETUP' })
================================================================================
"@
Set-Content -Path $logFile -Value $initHeader -Encoding utf8

function Write-SetupLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $logFile -Value $logEntry -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    Write-Host $Message -ForegroundColor $Color
}

function Send-WindowsEnvironmentBroadcast {
    try {
        $broadcastCode = @"
        using System;
        using System.Runtime.InteropServices;
        public class WinNotifier {
            [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
            public static extern IntPtr SendMessageTimeout(
                IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
                uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
        }
"@
        Add-Type -TypeDefinition $broadcastCode -ErrorAction SilentlyContinue
        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x001A
        $result = [UIntPtr]::Zero
        [WinNotifier]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 3000, [ref]$result) | Out-Null
        Write-SetupLog "[v] Notificacion de cambio de variables de entorno enviada al sistema de Windows." -Level "INFO" -Color Green
    } catch {}
}

# Check Administrator privileges
$isAdmin = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $isAdmin = $false
}

# ==============================================================================
# --- ROLLBACK MODE ---
# ==============================================================================
if ($Rollback) {
    Write-SetupLog "=== INICIANDO PROCESO DE ROLLBACK (RESTAURACION) ===" -Level "INFO" -Color Cyan

    $targetBackupDir = $null
    $latestPointer = Join-Path $backupsBaseDir "latest.txt"
    if (Test-Path -Path $latestPointer) {
        $candidate = (Get-Content -Path $latestPointer -Raw).Trim()
        if (Test-Path -Path $candidate) {
            $targetBackupDir = $candidate
        }
    }

    if (-not $targetBackupDir -and (Test-Path -Path $backupsBaseDir)) {
        $foundDirs = Get-ChildItem -Path $backupsBaseDir -Directory | Where-Object { $_.Name -match '^backup_' } | Sort-Object Name -Descending
        if ($foundDirs.Count -gt 0) {
            $targetBackupDir = $foundDirs[0].FullName
        }
    }

    if (-not $targetBackupDir -or -not (Test-Path -Path $targetBackupDir)) {
        Write-SetupLog "[-] No se encontro ningun respaldo previo en $backupsBaseDir para restaurar." -Level "ERROR" -Color Red
        exit 1
    }

    Write-SetupLog "[+] Directorio de respaldo seleccionado: $targetBackupDir" -Level "INFO" -Color Green
    $metaFile = Join-Path $targetBackupDir "backup_meta.json"
    if (-not (Test-Path -Path $metaFile)) {
        Write-SetupLog "[-] Falta el archivo de metadatos backup_meta.json en el respaldo." -Level "ERROR" -Color Red
        exit 1
    }

    $meta = Get-Content -Path $metaFile -Raw | ConvertFrom-Json

    # 1. Restore Machine PATH
    if ($meta.MachinePath) {
        if ($isAdmin) {
            try {
                [Environment]::SetEnvironmentVariable("Path", $meta.MachinePath, "Machine")
                Write-SetupLog "[v] Machine (System) PATH restaurado al valor del respaldo." -Level "INFO" -Color Green
            } catch {
                Write-SetupLog "[!] Error al restaurar Machine PATH: $_" -Level "WARN" -Color Yellow
            }
        } else {
            Write-SetupLog "[!] Sin permisos de Administrador: no se puede restaurar Machine PATH directamente." -Level "WARN" -Color Yellow
            Write-SetupLog "    Ejecuta rollback_wamp_env.bat (Aceptando UAC) para restaurar el PATH de Sistema." -Level "WARN" -Color Yellow
        }
    }

    # 2. Restore User PATH
    if ($meta.UserPath) {
        try {
            [Environment]::SetEnvironmentVariable("Path", $meta.UserPath, "User")
            Write-SetupLog "[v] User PATH restaurado al valor del respaldo." -Level "INFO" -Color Green
        } catch {
            Write-SetupLog "[!] Error al restaurar User PATH: $_" -Level "WARN" -Color Yellow
        }
    }

    # 3. Restore ini files
    if ($meta.IniFiles) {
        foreach ($item in $meta.IniFiles) {
            $backupFile = Join-Path $targetBackupDir $item.BackupName
            if (Test-Path -Path $backupFile) {
                try {
                    Copy-Item -Path $backupFile -Destination $item.OriginalPath -Force
                    Write-SetupLog "[v] Archivo .ini restaurado: $($item.OriginalPath)" -Level "INFO" -Color Green
                } catch {
                    Write-SetupLog "[!] Error restaurando $($item.OriginalPath): $_" -Level "WARN" -Color Yellow
                }
            }
        }
    }

    # 4. Restore PowerShell profile files
    if ($meta.ProfileFiles) {
        foreach ($item in $meta.ProfileFiles) {
            $backupFile = Join-Path $targetBackupDir $item.BackupName
            $targetOrig = [string]$item.OriginalPath
            if (Test-Path -Path $backupFile) {
                try {
                    Copy-Item -Path $backupFile -Destination $targetOrig -Force
                    Write-SetupLog "[v] Perfil PowerShell restaurado: $targetOrig" -Level "INFO" -Color Green
                } catch {
                    Write-SetupLog "[!] Error restaurando $targetOrig : $_" -Level "WARN" -Color Yellow
                }
            }
        }
    }

    # 5. Broadcast environment change
    Send-WindowsEnvironmentBroadcast

    Write-SetupLog "`n================================================================================" -Level "INFO" -Color Cyan
    Write-SetupLog "  ROLLBACK FINALIZADO CON EXITO" -Level "INFO" -Color Green
    Write-SetupLog "  El entorno fue restaurado al estado del respaldo: $($meta.Timestamp)" -Level "INFO" -Color Green
    Write-SetupLog "================================================================================" -Level "INFO" -Color Cyan
    exit 0
}

# ==============================================================================
# --- SETUP & CONFIGURATION MODE ---
# ==============================================================================

Write-SetupLog "=== WAMP PHP Environment Configuration Script ===" -Level "INFO" -Color Cyan
Write-SetupLog "[*] Directorio del proyecto: $projectRoot" -Level "INFO" -Color DarkCyan

if ($isAdmin) {
    Write-SetupLog "[+] Privilegios de Administrador: DETECTADOS (Permite modificar System PATH)" -Level "INFO" -Color Green
} else {
    Write-SetupLog "[!] Privilegios de Administrador: NO DETECTADOS (Se actualizara User PATH y PowerShell Profile)" -Level "WARN" -Color Yellow
}

# --- 2. Agnostic WAMP & PHP Discovery ---
if ([string]::IsNullOrWhiteSpace($WampPhpBaseDir)) {
    $candidateBases = @()
    try {
        $drives = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root
        foreach ($drive in $drives) {
            $candidateBases += (Join-Path $drive "wamp64\bin\php")
            $candidateBases += (Join-Path $drive "wamp\bin\php")
        }
    } catch {
        $candidateBases += "C:\wamp64\bin\php"
        $candidateBases += "C:\wamp\bin\php"
    }

    foreach ($candidate in $candidateBases) {
        if (Test-Path -Path $candidate) {
            $WampPhpBaseDir = $candidate
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($WampPhpBaseDir) -or -not (Test-Path -Path $WampPhpBaseDir)) {
    Write-SetupLog "[-] No se encontro la carpeta PHP de WAMP en las unidades del sistema." -Level "ERROR" -Color Red
    Write-SetupLog "    Verifica que WAMP este instalado o pasa la ruta con -WampPhpBaseDir 'C:\ruta\wamp64\bin\php'" -Level "ERROR" -Color Red
    exit 1
}

Write-SetupLog "[+] Directorio Base WAMP PHP encontrado: $WampPhpBaseDir" -Level "INFO" -Color Green

# Locate target PHP version
$targetDir = $null
if (-not [string]::IsNullOrWhiteSpace($TargetPhpVersion)) {
    $potentialPath = Join-Path $WampPhpBaseDir $TargetPhpVersion
    if (Test-Path -Path $potentialPath) {
        $targetDir = $potentialPath
    } else {
        Write-SetupLog "[-] La version especificada no existe: $potentialPath" -Level "ERROR" -Color Red
        exit 1
    }
} else {
    $allPhpDirs = Get-ChildItem -Path $WampPhpBaseDir -Directory | Where-Object { $_.Name -match '^php[78]\.' }
    if (-not $allPhpDirs -or $allPhpDirs.Count -eq 0) {
        $allPhpDirs = Get-ChildItem -Path $WampPhpBaseDir -Directory
    }

    if (-not $allPhpDirs -or $allPhpDirs.Count -eq 0) {
        Write-SetupLog "[-] No hay versiones de PHP instaladas en $WampPhpBaseDir." -Level "ERROR" -Color Red
        exit 1
    }

    # Prioritize stable PHP 8.2 (optimal compatibility for Composer & phpspreadsheet), then 8.3/8.4
    $stablePhp = $allPhpDirs | Where-Object { $_.Name -match '^php8\.[1-4]' } | Sort-Object Name -Descending
    if ($stablePhp -and $stablePhp.Count -gt 0) {
        $php82 = $stablePhp | Where-Object { $_.Name -match '^php8\.2' } | Select-Object -First 1
        if ($php82) {
            $targetDir = $php82.FullName
        } else {
            $targetDir = $stablePhp[0].FullName
        }
    } else {
        $sorted = $allPhpDirs | Sort-Object Name -Descending
        $targetDir = $sorted[0].FullName
    }
}

# Normalize targetDir
try {
    $targetDir = [System.IO.Path]::GetFullPath($targetDir).TrimEnd('\', '/')
} catch {}

Write-SetupLog "[+] Version de PHP seleccionada: $(Split-Path $targetDir -Leaf) ($targetDir)" -Level "INFO" -Color Green
$phpExe = Join-Path $targetDir "php.exe"
if (-not (Test-Path -Path $phpExe)) {
    Write-SetupLog "[-] php.exe no existe en: $phpExe" -Level "ERROR" -Color Red
    exit 1
}

# --- 3. PRE-CHANGE BACKUP (SNAPSHOT FOR ROLLBACK) ---
Write-SetupLog "[*] Creando respaldo de seguridad previo a los cambios..." -Level "INFO" -Color DarkCyan
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$currentBackupDir = Join-Path $backupsBaseDir "backup_$timestamp"
New-Item -ItemType Directory -Path $currentBackupDir -Force | Out-Null

$backupIniEntries = [System.Collections.Generic.List[object]]::new()
$backupProfileEntries = [System.Collections.Generic.List[object]]::new()

# Locate .ini files in target PHP directory
$iniFiles = Get-ChildItem -Path $targetDir -Filter "*.ini" | Where-Object { $_.Name -match '^php.*\.ini$' }

if (-not $iniFiles -or $iniFiles.Count -eq 0) {
    $prodIni = Join-Path $targetDir "php.ini-production"
    $devIni = Join-Path $targetDir "php.ini-development"
    $destIni = Join-Path $targetDir "php.ini"

    if (-not (Test-Path -Path $destIni)) {
        if (Test-Path -Path $prodIni) {
            Copy-Item -Path $prodIni -Destination $destIni
            Write-SetupLog "[+] Se creo php.ini a partir de php.ini-production" -Level "INFO" -Color Yellow
        } elseif (Test-Path -Path $devIni) {
            Copy-Item -Path $devIni -Destination $destIni
            Write-SetupLog "[+] Se creo php.ini a partir de php.ini-development" -Level "INFO" -Color Yellow
        }
    }
    $iniFiles = Get-ChildItem -Path $targetDir -Filter "php.ini"
}

# Backup each ini file before any change
foreach ($ini in $iniFiles) {
    $destFile = Join-Path $currentBackupDir $ini.Name
    Copy-Item -Path $ini.FullName -Destination $destFile -Force
    $backupIniEntries.Add(@{
        OriginalPath = $ini.FullName
        BackupName = $ini.Name
    })
}

# Backup PowerShell profile files
$profileCandidates = @()
if ($PROFILE) {
    try {
        if ($PROFILE.CurrentUserAllHosts) { $profileCandidates += [string]$PROFILE.CurrentUserAllHosts }
        if ($PROFILE.CurrentUserCurrentHost) { $profileCandidates += [string]$PROFILE.CurrentUserCurrentHost }
    } catch {
        $profileCandidates += [string]$PROFILE
    }
}
$profileCandidates = $profileCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

$profIndex = 1
foreach ($profPath in $profileCandidates) {
    $strProf = [string]$profPath
    if (Test-Path -Path $strProf) {
        $bName = "profile_$profIndex.ps1"
        $destFile = Join-Path $currentBackupDir $bName
        Copy-Item -Path $strProf -Destination $destFile -Force
        $backupProfileEntries.Add(@{
            OriginalPath = $strProf
            BackupName = $bName
        })
        $profIndex++
    }
}

# Capture current PATHs
$capturedMachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$capturedUserPath = [Environment]::GetEnvironmentVariable("Path", "User")

$metaData = [PSCustomObject]@{
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TargetPhpDir = $targetDir
    MachinePath = $capturedMachinePath
    UserPath = $capturedUserPath
    IniFiles = $backupIniEntries
    ProfileFiles = $backupProfileEntries
}

$metaData | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $currentBackupDir "backup_meta.json") -Encoding utf8
Set-Content -Path (Join-Path $backupsBaseDir "latest.txt") -Value $currentBackupDir -Encoding utf8

Write-SetupLog "[v] Respaldo de seguridad creado exitosamente en: $currentBackupDir" -Level "INFO" -Color Green

# --- 4. Configure php.ini & phpForApache.ini Extensions ---
$extensionsToEnable = @("zip", "gd", "mbstring", "curl", "fileinfo", "pdo_mysql", "openssl")
$extFolder = Join-Path $targetDir "ext"
$hasExtFolder = Test-Path -Path $extFolder

foreach ($iniFile in $iniFiles) {
    Write-SetupLog "[*] Configurando archivo: $($iniFile.Name)" -Level "INFO" -Color DarkCyan
    $content = Get-Content -Path $iniFile.FullName -Raw

    $modified = $false

    # Ensure extension_dir is active
    if ($hasExtFolder) {
        $normExtDir = ($extFolder -replace '\\', '/') + '/'
        if ($content -match '(?m)^\s*;\s*extension_dir\s*=\s*"ext"') {
            $content = [System.Text.RegularExpressions.Regex]::Replace($content, '(?m)^\s*;\s*(extension_dir\s*=\s*"ext")', 'extension_dir = "ext"')
            $modified = $true
            Write-SetupLog "    [v] extension_dir habilitado como `"ext`"" -Level "INFO" -Color Green
        } elseif ($content -notmatch '(?m)^\s*extension_dir\s*=') {
            $content += "`r`nextension_dir = `"$normExtDir`"`r`n"
            $modified = $true
            Write-SetupLog "    [+] extension_dir configurado a $normExtDir" -Level "INFO" -Color Green
        }
    }

    # Enable required extensions
    foreach ($ext in $extensionsToEnable) {
        $patternCommented = "(?m)^\s*;\s*(extension\s*=\s*(?:php_)?$ext(?:\.dll)?\s*)$"
        $patternActive = "(?m)^\s*(extension\s*=\s*(?:php_)?$ext(?:\.dll)?\s*)$"

        if ($content -match $patternCommented) {
            $content = [System.Text.RegularExpressions.Regex]::Replace($content, $patternCommented, "extension=$ext")
            Write-SetupLog "    [v] Extension habilitada: $ext" -Level "INFO" -Color Green
            $modified = $true
        } elseif ($content -match $patternActive) {
            Write-SetupLog "    [-] Extension ya activa: $ext" -Level "INFO" -Color Gray
        } else {
            $content += "`r`nextension=$ext`r`n"
            Write-SetupLog "    [+] Extension agregada al final: $ext" -Level "INFO" -Color Yellow
            $modified = $true
        }
    }

    if ($modified) {
        Set-Content -Path $iniFile.FullName -Value $content -NoNewline
        Write-SetupLog "    [v] Guardado $($iniFile.Name)" -Level "INFO" -Color Green
    }
}

# --- 5. Deep Clean & Align PATH (System & User) ---
Write-SetupLog "[*] Optimizando variables de entorno PATH (User y System)..." -Level "INFO" -Color DarkCyan

function Optimize-PathScope {
    param(
        [string]$TargetPhpDirectory,
        [string]$Scope # "Machine" or "User"
    )

    $rawPath = [Environment]::GetEnvironmentVariable("Path", $Scope)
    if ([string]::IsNullOrWhiteSpace($rawPath)) { return }

    $normTarget = ""
    try {
        $normTarget = [System.IO.Path]::GetFullPath($TargetPhpDirectory.Trim().Trim('"')).TrimEnd('\', '/')
    } catch {
        $normTarget = $TargetPhpDirectory.Trim().Trim('"').TrimEnd('\', '/')
    }

    $entries = $rawPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Trim()) }
    $cleanedEntries = [System.Collections.Generic.List[string]]::new()
    $removedList = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $entries) {
        $cleanEntry = $entry.Trim().Trim('"').TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($cleanEntry)) { continue }

        $fullEntry = ""
        try {
            $fullEntry = [System.IO.Path]::GetFullPath($cleanEntry).TrimEnd('\', '/')
        } catch {
            $fullEntry = $cleanEntry
        }

        # If this entry matches our target directory, remove it here so it is placed at index 0 without duplicates
        if ($fullEntry -ieq $normTarget) {
            continue
        }

        # Detect ANY conflicting PHP directory (previous WAMP versions, XAMPP, Laragon, standalone PHP)
        $isConflict = $false
        if ($fullEntry -match '(?i)(?:xampp|wamp(?:64)?|laragon)[\\/]bin[\\/]php|xampp[\\/]php|^[a-z]:[\\/]php[0-9]*$') {
            $isConflict = $true
        } elseif (Test-Path -Path (Join-Path $fullEntry "php.exe") -ErrorAction SilentlyContinue) {
            $isConflict = $true
        }

        if ($isConflict) {
            $removedList.Add($entry)
            Write-SetupLog "    [-] Removiendo version previa/conflicto de PHP en $Scope PATH: $entry" -Level "WARN" -Color Yellow
        } else {
            if (-not $cleanedEntries.Contains($entry)) {
                $cleanedEntries.Add($entry)
            }
        }
    }

    # Prepend target PHP directory to position 0 for absolute priority
    $cleanedEntries.Insert(0, $TargetPhpDirectory)

    $newPath = ($cleanedEntries -join ';')
    try {
        [Environment]::SetEnvironmentVariable("Path", $newPath, $Scope)
        Write-SetupLog "[v] $Scope PATH optimizado correctamente. (Target WAMP PHP al inicio, conflictos removidos: $($removedList.Count))" -Level "INFO" -Color Green
    } catch {
        Write-SetupLog "[!] No se pudo guardar cambios en $Scope PATH: $_" -Level "WARN" -Color Yellow
    }
}

# 5a. Check if Machine PATH has conflicts and handle elevation if non-admin
$machineConflicts = @()
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
    $entries = $machinePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Trim()) }
    foreach ($entry in $entries) {
        $fullEntry = $entry.Trim().Trim('"').TrimEnd('\', '/')
        try { $fullEntry = [System.IO.Path]::GetFullPath($fullEntry).TrimEnd('\', '/') } catch {}
        if ($fullEntry -ine $targetDir) {
            if ($fullEntry -match '(?i)(?:xampp|wamp(?:64)?|laragon)[\\/]bin[\\/]php|xampp[\\/]php|^[a-z]:[\\/]php[0-9]*$' -or (Test-Path -Path (Join-Path $fullEntry "php.exe") -ErrorAction SilentlyContinue)) {
                $machineConflicts += $entry
            }
        }
    }
}

if (-not $isAdmin -and $machineConflicts.Count -gt 0 -and -not $NoElevate -and -not $NonInteractive) {
    Write-SetupLog "[!] Se detectaron $($machineConflicts.Count) ruta(s) de PHP conflictivas en el PATH de Sistema (Machine):" -Level "WARN" -Color Yellow
    foreach ($c in $machineConflicts) {
        Write-SetupLog "    * $c" -Level "WARN" -Color Yellow
    }
    Write-SetupLog "[*] Solicitando permisos de Administrador para limpiar el PATH de Sistema..." -Level "INFO" -Color Cyan
    try {
        $elevateArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-NoElevate")
        if ($RunComposerInstall) { $elevateArgs += "-RunComposerInstall" }
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $elevateArgs -Verb RunAs -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            exit 0
        }
    } catch {
        Write-SetupLog "[!] UAC cancelado. Continuando configuracion en modo Usuario..." -Level "WARN" -Color Yellow
    }
}

# 5b. Execute PATH optimizations
if ($isAdmin) {
    Optimize-PathScope -TargetPhpDirectory $targetDir -Scope "Machine"
} else {
    if ($machineConflicts.Count -gt 0) {
        Write-SetupLog "[!] ADVERTENCIA: Hay rutas PHP en el PATH de Sistema que podrian interferir en consolas CMD sin privilegios." -Level "WARN" -Color Yellow
        Write-SetupLog "    Para limpiar Machine PATH ejecuta setup_wamp_env.bat (Aceptando la solicitud UAC)." -Level "WARN" -Color Yellow
    }
}

Optimize-PathScope -TargetPhpDirectory $targetDir -Scope "User"

# 5c. Update PowerShell Profiles
$profileSnippet = "`n# WAMP PHP CLI Priority`n`$env:PATH = '$targetDir;' + (`$env:PATH -replace [regex]::Escape('$targetDir')+';?','')`n"

foreach ($profPath in $profileCandidates) {
    $strProf = [string]$profPath
    try {
        $profDir = Split-Path -Parent $strProf
        if (-not (Test-Path -Path $profDir)) {
            New-Item -ItemType Directory -Path $profDir -Force | Out-Null
        }
        $profContent = ""
        if (Test-Path -Path $strProf) {
            $profContent = Get-Content -Path $strProf -Raw
        }
        if ($profContent -notmatch [regex]::Escape($targetDir)) {
            Add-Content -Path $strProf -Value $profileSnippet -Encoding utf8
            Write-SetupLog "[v] PowerShell Profile actualizado para priorizar WAMP PHP ($strProf)" -Level "INFO" -Color Green
        } else {
            Write-SetupLog "[-] PowerShell Profile ya contiene la ruta de WAMP PHP ($strProf)" -Level "INFO" -Color Gray
        }
    } catch {
        Write-SetupLog "[!] No se pudo escribir en el perfil de PowerShell ($strProf): $_" -Level "WARN" -Color Yellow
    }
}

# Update current process PATH immediately
$env:Path = "$targetDir;" + ($env:Path -replace [regex]::Escape($targetDir)+';?','')

# 5d. Broadcast Environment Change to Windows Shell
Send-WindowsEnvironmentBroadcast

# --- 6. Verification ---
Write-SetupLog "`n=== Verificacion del Entorno ===" -Level "INFO" -Color Cyan

# Check which PHP resolves first
Write-SetupLog "[*] Resolucion de 'where php':" -Level "INFO" -Color DarkCyan
$wherePhp = where.exe php 2>&1
$isPrimaryOk = $false
$firstLine = $true
foreach ($line in $wherePhp) {
    if ($firstLine) {
        $firstLine = $false
        if ($line -match [regex]::Escape($targetDir)) {
            Write-SetupLog "    -> $line (ACTIVO / PRIORIDAD 1) [OK]" -Level "INFO" -Color Green
            $isPrimaryOk = $true
        } else {
            Write-SetupLog "    -> $line (ACTIVO pero no es WAMP PHP) [CONFLICTO]" -Level "ERROR" -Color Red
        }
    } else {
        Write-SetupLog "    -> $line (Secundario/Inactivo)" -Level "INFO" -Color Gray
    }
}

if (-not $isPrimaryOk) {
    Write-SetupLog "[!] Advertencia: WAMP PHP no es la primera opcion activa en 'where php'. Reinicia la terminal para refrescar el PATH." -Level "WARN" -Color Yellow
}

# Verify PHP version
Write-SetupLog "`n[*] Version de PHP detectada:" -Level "INFO" -Color DarkCyan
$phpVer = & $phpExe -v 2>&1
$phpVerSummary = ($phpVer | Select-Object -First 2) -join "`n"
Write-SetupLog $phpVerSummary -Level "INFO" -Color Green

# Verify Extensions
Write-SetupLog "`n[*] Verificando extensiones obligatorias:" -Level "INFO" -Color DarkCyan
$loadedModules = & $phpExe -m 2>&1
$allExtensionsOk = $true
foreach ($ext in $extensionsToEnable) {
    if ($loadedModules -contains $ext) {
        Write-SetupLog "    [OK]   $ext" -Level "INFO" -Color Green
    } else {
        Write-SetupLog "    [FAIL] $ext (NO CARGADO)" -Level "ERROR" -Color Red
        $allExtensionsOk = $false
    }
}

if (-not $allExtensionsOk) {
    Write-SetupLog "`n[!] Alerta: Algunas extensiones no pudieron cargarse. Revisa $logFile." -Level "WARN" -Color Red
}

# Verify Composer
Write-SetupLog "`n[*] Verificando Composer:" -Level "INFO" -Color DarkCyan
$composerCmd = Get-Command composer -ErrorAction SilentlyContinue
if ($composerCmd) {
    $composerVer = composer --version 2>&1
    Write-SetupLog "    [OK] Composer detectado: $composerVer" -Level "INFO" -Color Green
} else {
    $commonComposer = @(
        "C:\composer\composer.bat",
        "C:\ProgramData\ComposerSetup\bin\composer.bat",
        "$env:APPDATA\Composer\vendor\bin\composer.bat"
    )
    $foundComposer = $false
    foreach ($compPath in $commonComposer) {
        if (Test-Path -Path $compPath) {
            $compDir = Split-Path -Parent $compPath
            $env:Path = "$compDir;$env:Path"
            Write-SetupLog "    [+] Composer localizado en $compPath y agregado al PATH temporal." -Level "INFO" -Color Green
            $foundComposer = $true
            break
        }
    }
    if (-not $foundComposer) {
        Write-SetupLog "    [!] Composer no se encuentra instalado en las rutas estandar." -Level "WARN" -Color Yellow
    }
}

# --- 7. Database Verification & Auto-Creation (tienda_virtual) ---
Write-SetupLog "`n[*] Verificando conexion a MySQL y base de datos 'tienda_virtual'..." -Level "INFO" -Color DarkCyan
$dbCreatePhp = "try { (new PDO('mysql:host=localhost;charset=utf8mb4', 'root', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]))->exec('CREATE DATABASE IF NOT EXISTS tienda_virtual CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'); echo 'DB_OK'; } catch (Exception `$e) { echo 'DB_ERROR: ' . `$e->getMessage(); }"
$dbResult = & $phpExe -r $dbCreatePhp 2>&1
if ($dbResult -match 'DB_OK') {
    Write-SetupLog "    [OK] Base de datos 'tienda_virtual' activa y lista en MySQL." -Level "INFO" -Color Green
} else {
    Write-SetupLog "    [!] No se pudo conectar a MySQL: $dbResult" -Level "WARN" -Color Yellow
    Write-SetupLog "        Asegurate de que WAMP este iniciado (icono verde / servicio MySQL activo)." -Level "WARN" -Color Yellow
}

# --- 8. Composer Install Prompt ---
$shouldRunComposer = $RunComposerInstall

if (-not $shouldRunComposer -and -not $NonInteractive) {
    Write-Host ""
    $answer = Read-Host "¿Deseas ejecutar 'composer install' ahora en esta carpeta? (S/n) [por defecto: S]"
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(s|si|y|yes)$') {
        $shouldRunComposer = $true
    }
}

if ($shouldRunComposer) {
    if (Get-Command composer -ErrorAction SilentlyContinue) {
        Write-SetupLog "`n[*] Ejecutando 'composer install' en $projectRoot..." -Level "INFO" -Color Cyan
        Push-Location $projectRoot
        $composerOutput = composer install 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location
        foreach ($cLine in $composerOutput) {
            Write-SetupLog "    $cLine" -Level "INFO" -Color White
        }
        if ($exitCode -eq 0) {
            Write-SetupLog "[v] 'composer install' finalizo EXITOSAMENTE sin errores!" -Level "INFO" -Color Green
        } else {
            Write-SetupLog "[!] 'composer install' termino con codigo de salida $exitCode." -Level "ERROR" -Color Red
        }
    } else {
        Write-SetupLog "[-] No se pudo ejecutar 'composer install': comando 'composer' no disponible." -Level "ERROR" -Color Red
    }
}

# --- 9. Final Summary ---
Write-SetupLog "`n================================================================================" -Level "INFO" -Color Cyan
Write-SetupLog "  PROCESO COMPLETADO" -Level "INFO" -Color Green
Write-SetupLog "  Respaldo para rollback guardado en: $currentBackupDir" -Level "INFO" -Color Green
Write-SetupLog "  Log detallado guardado en: $logFile" -Level "INFO" -Color Cyan
Write-SetupLog "  Para deshacer cambios en cualquier momento ejecuta: .\scripts\rollback_wamp_env.bat" -Level "INFO" -Color Yellow
Write-SetupLog "================================================================================" -Level "INFO" -Color Cyan

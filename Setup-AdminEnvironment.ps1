#Requires -Version 5.1
<#
.SYNOPSIS
    Automated setup script for a Microsoft 365 / Azure admin terminal environment.

.DESCRIPTION
    Installs and configures:
      - PowerShell 7 (latest stable)
      - Exchange Online Management
      - Microsoft Graph PowerShell SDK
      - Azure PowerShell (Az)
      - SharePoint Online Management Shell
      - Microsoft Teams PowerShell
      - Azure AD (AzureADPreview)
      - Windows Terminal (via winget)
      - PSReadLine, posh-git, oh-my-posh (optional quality-of-life)

    Designed for minimal interaction — runs with -Force / -AllowClobber throughout.
    Must be executed in an elevated (Administrator) PowerShell session.

.EXAMPLE
    # Run from a standard elevated PowerShell 5.1 prompt:
    Set-ExecutionPolicy Bypass -Scope Process -Force
    .\Setup-AdminEnvironment.ps1

.EXAMPLE
    # Skip optional quality-of-life tools:
    .\Setup-AdminEnvironment.ps1 -SkipOptional

.EXAMPLE
    # Skip Windows Terminal installation (e.g., already installed or on Server Core):
    .\Setup-AdminEnvironment.ps1 -SkipTerminal
#>

[CmdletBinding()]
param(
    [switch]$SkipOptional,   # Skip oh-my-posh, posh-git, PSReadLine
    [switch]$SkipTerminal,   # Skip Windows Terminal winget install
    [switch]$SkipPS7         # Skip PowerShell 7 install (if already present)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Message = 'Done.')
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    WARNING: $Message" -ForegroundColor Yellow
}

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-PSModule {
    param(
        [string]$Name,
        [string]$RequiredVersion,  # optional
        [switch]$AllowPrerelease
    )

    $installParams = @{
        Name            = $Name
        Force           = $true
        AllowClobber    = $true
        Scope           = 'AllUsers'
        Repository      = 'PSGallery'
        WarningAction   = 'SilentlyContinue'
    }

    if ($RequiredVersion)  { $installParams['RequiredVersion']  = $RequiredVersion  }
    if ($AllowPrerelease)  { $installParams['AllowPrerelease']  = $true             }

    Install-Module @installParams
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if (-not (Test-Admin)) {
    Write-Error 'This script must be run as Administrator. Right-click PowerShell -> Run as Administrator.'
    exit 1
}

Write-Step 'Pre-flight checks passed (running as Administrator).'

# Ensure TLS 1.2 for all web calls made by this session
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# 1. Trust PSGallery and update PowerShellGet / PackageManagement
# ---------------------------------------------------------------------------

Write-Step 'Configuring PSGallery and updating PowerShellGet...'

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Ensure we have a modern PowerShellGet (needed for Graph SDK v2+)
Install-Module -Name PowerShellGet    -Force -AllowClobber -Scope AllUsers -Repository PSGallery
Install-Module -Name PackageManagement -Force -AllowClobber -Scope AllUsers -Repository PSGallery

Write-Done 'PSGallery trusted, PowerShellGet updated.'

# ---------------------------------------------------------------------------
# 2. PowerShell 7
# ---------------------------------------------------------------------------

if (-not $SkipPS7) {
    Write-Step 'Installing PowerShell 7 (latest stable)...'

    $ps7Installed = $null -ne (Get-Command pwsh.exe -ErrorAction SilentlyContinue)

    if ($ps7Installed) {
        $currentVersion = (pwsh.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null).Trim()
        Write-Warn "PowerShell 7 already detected ($currentVersion). Attempting upgrade via winget."
    }

    # Try winget first (available on Windows 10 1709+ / Server 2019+)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue

    if ($winget) {
        winget install --id Microsoft.PowerShell --source winget --silent --accept-package-agreements --accept-source-agreements
        Write-Done 'PowerShell 7 installed/upgraded via winget.'
    } else {
        # Fallback: download and run the MSI installer silently
        Write-Warn 'winget not available — falling back to direct MSI download.'

        $ps7Release = (Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest').tag_name.TrimStart('v')
        $msiUrl     = "https://github.com/PowerShell/PowerShell/releases/download/v${ps7Release}/PowerShell-${ps7Release}-win-x64.msi"
        $msiPath    = "$env:TEMP\PowerShell7.msi"

        Write-Host "    Downloading PowerShell $ps7Release from GitHub..."
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

        $msiArgs = @('/i', $msiPath, '/quiet', '/norestart',
                     'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1',
                     'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1',
                     'ENABLE_PSREMOTING=1',
                     'REGISTER_MANIFEST=1')
        Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -NoNewWindow

        Remove-Item $msiPath -Force
        Write-Done "PowerShell $ps7Release installed via MSI."
    }
} else {
    Write-Step 'Skipping PowerShell 7 install (-SkipPS7 specified).'
}

# ---------------------------------------------------------------------------
# 3. Windows Terminal
# ---------------------------------------------------------------------------

if (-not $SkipTerminal) {
    Write-Step 'Installing Windows Terminal...'

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue

    if ($winget) {
        winget install --id Microsoft.WindowsTerminal --source winget --silent --accept-package-agreements --accept-source-agreements
        Write-Done 'Windows Terminal installed/upgraded.'
    } else {
        Write-Warn 'winget not available — skipping Windows Terminal. Install manually from the Microsoft Store.'
    }
} else {
    Write-Step 'Skipping Windows Terminal install (-SkipTerminal specified).'
}

# ---------------------------------------------------------------------------
# 4. Exchange Online Management
# ---------------------------------------------------------------------------

Write-Step 'Installing ExchangeOnlineManagement...'
Install-PSModule -Name ExchangeOnlineManagement
Write-Done 'ExchangeOnlineManagement installed.'

# ---------------------------------------------------------------------------
# 5. Microsoft Graph PowerShell SDK
# ---------------------------------------------------------------------------

Write-Step 'Installing Microsoft.Graph (full SDK — this may take a few minutes)...'

# Install the meta-module which pulls all sub-modules
Install-PSModule -Name Microsoft.Graph

# Also ensure the authentication module is explicitly present
Install-PSModule -Name Microsoft.Graph.Authentication

Write-Done 'Microsoft.Graph SDK installed.'

# ---------------------------------------------------------------------------
# 6. Azure PowerShell (Az)
# ---------------------------------------------------------------------------

Write-Step 'Installing Az (Azure PowerShell) — this may take several minutes...'
Install-PSModule -Name Az
Write-Done 'Az module installed.'

# ---------------------------------------------------------------------------
# 7. SharePoint Online Management Shell
# ---------------------------------------------------------------------------

Write-Step 'Installing Microsoft.Online.SharePoint.PowerShell...'
Install-PSModule -Name Microsoft.Online.SharePoint.PowerShell
Write-Done 'SharePoint Online Management Shell installed.'

# ---------------------------------------------------------------------------
# 8. Microsoft Teams
# ---------------------------------------------------------------------------

Write-Step 'Installing MicrosoftTeams...'
Install-PSModule -Name MicrosoftTeams
Write-Done 'MicrosoftTeams module installed.'

# ---------------------------------------------------------------------------
# 9. Azure AD (AzureADPreview — superset of AzureAD)
# ---------------------------------------------------------------------------

Write-Step 'Installing AzureADPreview...'

# Remove the non-preview version first to avoid conflicts
if (Get-Module -Name AzureAD -ListAvailable -ErrorAction SilentlyContinue) {
    Uninstall-Module -Name AzureAD -AllVersions -Force -ErrorAction SilentlyContinue
}

Install-PSModule -Name AzureADPreview
Write-Done 'AzureADPreview installed.'

# ---------------------------------------------------------------------------
# 10. MSOnline (legacy — still required for some tenant-level operations)
# ---------------------------------------------------------------------------

Write-Step 'Installing MSOnline...'
Install-PSModule -Name MSOnline
Write-Done 'MSOnline installed.'

# ---------------------------------------------------------------------------
# 11. Microsoft.Graph.Intune / Endpoint Management
# ---------------------------------------------------------------------------

Write-Step 'Installing Microsoft.Graph.Intune (Endpoint/Intune management)...'
Install-PSModule -Name Microsoft.Graph.DeviceManagement
Install-PSModule -Name Microsoft.Graph.DeviceManagement.Administration
Write-Done 'Intune/Endpoint Graph modules installed.'

# ---------------------------------------------------------------------------
# 12. Optional quality-of-life modules
# ---------------------------------------------------------------------------

if (-not $SkipOptional) {
    Write-Step 'Installing quality-of-life terminal modules (PSReadLine, posh-git, oh-my-posh)...'

    # PSReadLine — syntax highlighting, history search, predictive IntelliSense
    Install-PSModule -Name PSReadLine

    # posh-git — Git status in prompt
    Install-PSModule -Name posh-git

    # oh-my-posh — prompt theming engine (binary installed via winget if available)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        winget install --id JanDeDobbeleer.OhMyPosh --source winget --silent --accept-package-agreements --accept-source-agreements
        Write-Done 'oh-my-posh installed via winget.'
    } else {
        Install-PSModule -Name oh-my-posh
        Write-Done 'oh-my-posh installed via PSGallery.'
    }

    # Terminal-Icons — file/folder icons in the terminal
    Install-PSModule -Name Terminal-Icons

    Write-Done 'Quality-of-life modules installed.'
} else {
    Write-Step 'Skipping optional modules (-SkipOptional specified).'
}

# ---------------------------------------------------------------------------
# 13. Emit a PowerShell 7 profile snippet
# ---------------------------------------------------------------------------

Write-Step 'Generating recommended $PROFILE snippet for PowerShell 7...'

$profileSnippet = @'
# ── Microsoft 365 / Azure Admin Profile ────────────────────────────────────

# PSReadLine – history-based predictions & syntax highlighting
if (Get-Module -Name PSReadLine -ListAvailable) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle ListView
    Set-PSReadLineOption -EditMode Windows
}

# Terminal-Icons – coloured icons in Get-ChildItem / ls
if (Get-Module -Name Terminal-Icons -ListAvailable) {
    Import-Module Terminal-Icons
}

# posh-git – Git status in prompt
if (Get-Module -Name posh-git -ListAvailable) {
    Import-Module posh-git
}

# oh-my-posh – prompt theme  (requires oh-my-posh binary in PATH)
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh | Invoke-Expression
}

# Quick-connect aliases
function Connect-M365 {
    <# Connect to Exchange Online + Graph + SharePoint + Teams in one shot #>
    param(
        [string]$AdminUPN,
        [string]$SharePointAdminUrl  # e.g. https://contoso-admin.sharepoint.com
    )
    Connect-ExchangeOnline  -UserPrincipalName $AdminUPN -ShowProgress $true
    Connect-MgGraph         -Scopes 'Directory.ReadWrite.All','User.ReadWrite.All','Group.ReadWrite.All'
    Connect-MicrosoftTeams  -AccountId $AdminUPN
    if ($SharePointAdminUrl) {
        Connect-SPOService  -Url $SharePointAdminUrl
    }
}

function Disconnect-M365 {
    <# Disconnect all active M365 sessions #>
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Disconnect-MgGraph                         -ErrorAction SilentlyContinue
    Disconnect-MicrosoftTeams                  -ErrorAction SilentlyContinue
    Disconnect-SPOService                      -ErrorAction SilentlyContinue
    Write-Host 'All M365 sessions disconnected.' -ForegroundColor Green
}

# ── End Microsoft 365 / Azure Admin Profile ────────────────────────────────
'@

$snippetPath = "$env:TEMP\PS7_Profile_Snippet.ps1"
$profileSnippet | Out-File -FilePath $snippetPath -Encoding utf8 -Force

Write-Done "Profile snippet saved to: $snippetPath"
Write-Host "    To apply it, run:" -ForegroundColor White
Write-Host "      pwsh -NoProfile -Command `"Add-Content -Path `$PROFILE -Value (Get-Content '$snippetPath' -Raw)`"" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host '  Setup complete! Modules installed (AllUsers scope):' -ForegroundColor Magenta
Write-Host '============================================================' -ForegroundColor Magenta

$modules = @(
    'ExchangeOnlineManagement',
    'Microsoft.Graph',
    'Az',
    'Microsoft.Online.SharePoint.PowerShell',
    'MicrosoftTeams',
    'AzureADPreview',
    'MSOnline',
    'Microsoft.Graph.DeviceManagement',
    'PSReadLine',
    'posh-git',
    'Terminal-Icons'
)

foreach ($mod in $modules) {
    $installed = Get-Module -Name $mod -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    $status    = if ($installed) { "v$($installed.Version)" } else { 'not found (check above for errors)' }
    Write-Host ("  {0,-50} {1}" -f $mod, $status)
}

Write-Host ''
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '    1. Open a NEW PowerShell 7 (pwsh) session.'
Write-Host '    2. Apply the profile snippet at: ' -NoNewline
Write-Host $snippetPath -ForegroundColor Yellow
Write-Host '    3. Connect with: Connect-M365 -AdminUPN you@domain.com -SharePointAdminUrl https://contoso-admin.sharepoint.com'
Write-Host ''

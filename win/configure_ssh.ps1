Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' not found. Install the Windows OpenSSH Client feature and try again."
    }
}

function Invoke-SshCommand {
    param(
        [Parameter(Mandatory)][string[]]$SshOpts,
        [Parameter(Mandatory)][string]$Command
    )

    & ssh @SshOpts $Command *> $null
    return ($LASTEXITCODE -eq 0)
}

function Install-SshPublicKey {
    param(
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][string[]]$SshOpts
    )

    $pubKey = (Get-Content -Path $PublicKeyPath -Raw).Trim()

    & ssh @SshOpts -o PubkeyAuthentication=no "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$pubKey' ~/.ssh/authorized_keys || echo '$pubKey' >> ~/.ssh/authorized_keys"
    if ($LASTEXITCODE -ne 0) { throw "Failed to install SSH public key on the remote server." }
}

function Update-SshConfigEntry {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$IdentityFile
    )

    if (-not (Test-Path $ConfigPath)) {
        New-Item -ItemType File -Path $ConfigPath -Force | Out-Null
    }

    [string[]]$existing = @(Get-Content -Path $ConfigPath -ErrorAction SilentlyContinue)

    [string[]]$entry = @(
        "Host $HostName",
        "    HostName $Ip",
        "    Port $Port",
        "    User $User",
        "    AddKeysToAgent yes",
        "    IdentityFile `"$IdentityFile`""
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $found = $false

    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i].Trim() -eq "Host $HostName") {
            $found = $true
            $result.AddRange($entry)
            $i++
            while ($i -lt $existing.Count -and $existing[$i] -match '^\s' -and $existing[$i].Trim() -ne "") { $i++ }
            # Also skip trailing blank lines within the block
            while ($i -lt $existing.Count -and $existing[$i].Trim() -eq "") { $i++ }
            $i--
            continue
        }
        $result.Add($existing[$i])
    }

    if (-not $found) {
        if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne "") { $result.Add("") }
        $result.AddRange($entry)
    }

    Set-Content -Path $ConfigPath -Value $result -Encoding ascii
}

# --- Main ---

Assert-CommandExists "ssh"

Write-Host ""
Write-Host "SSH Client Setup"
Write-Host "================"
Write-Host "Configures this Windows machine to connect to a remote SSH server."
Write-Host ""

# Collect connection details (pre-set $h/$u/$p variables are used if available)
$Ip   = if (Get-Variable h -ValueOnly -ErrorAction SilentlyContinue) { "$h" }   else { Read-Host "IP address or hostname" }
$User = if (Get-Variable u -ValueOnly -ErrorAction SilentlyContinue) { "$u" } else { Read-Host "Username" }
$Port = 22

$presetPort = Get-Variable p -ValueOnly -ErrorAction SilentlyContinue
if ($presetPort -and "$presetPort".Trim() -ne "") {
    $Port = [int]"$presetPort"
} elseif (-not (Get-Variable h -ValueOnly -ErrorAction SilentlyContinue)) {
    $portInput = Read-Host "Port [22]"
    if ($portInput -ne "") { $Port = [int]$portInput }
}

if ([string]::IsNullOrWhiteSpace($Ip))        { throw "Invalid address/hostname." }
if ([string]::IsNullOrWhiteSpace($User))       { throw "Invalid username." }
if ($Port -lt 1 -or $Port -gt 65535)           { throw "Invalid port: $Port" }

Write-Host ""

# Paths
$sshDir     = Join-Path $env:USERPROFILE ".ssh"
$privateKey = Join-Path $sshDir "id_ed25519"
$publicKey  = "$privateKey.pub"
$configPath = Join-Path $sshDir "config"

New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

# Shared SSH options
$dest = "$User@$Ip"
[string[]]$sshOpts = @(
    '-i', $privateKey,
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=10',
    '-p', "$Port",
    $dest
)
# Non-batch opts for interactive commands (key install, password prompts)
[string[]]$sshInteractiveOpts = @(
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=10',
    '-p', "$Port",
    $dest
)

# Generate key pair if needed
if (-not (Test-Path $privateKey)) {
    Write-Host "Generating SSH key pair..."
    echo y | & ssh-keygen -t ed25519 -f $privateKey -q
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate SSH key." }
}

# Install key on remote if not already authorized
if (-not (Invoke-SshCommand -SshOpts $sshOpts -Command "true")) {
    Write-Host "Copying SSH key to remote server..."
    Install-SshPublicKey -PublicKeyPath $publicKey -SshOpts $sshInteractiveOpts

    if (-not (Invoke-SshCommand -SshOpts $sshOpts -Command "true")) {
        throw "Failed to verify SSH key installation."
    }
}

Write-Host "SSH key authorized."

# Update local SSH config
$hostAlias = "$Ip-$User"
Update-SshConfigEntry -ConfigPath $configPath -HostName $hostAlias -Ip $Ip -User $User -Port $Port -IdentityFile $privateKey
Write-Host "SSH config updated for host '$hostAlias'."

# Offer to disable password auth
$pwdDisabled = Invoke-SshCommand -SshOpts $sshOpts `
    -Command "grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config"

if (-not $pwdDisabled) {
    $r = Read-Host "Disable password-based auth for security? [Y/n]"
    if ($r -notmatch '^[nN]$') {
        $ok = Invoke-SshCommand -SshOpts $sshOpts `
            -Command "sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo systemctl restart ssh"
        Write-Host $(if ($ok) { "Password auth disabled." } else { "Failed to disable password auth." })
    }
} else {
    Write-Host "Password auth already disabled."
}

# Done
Write-Host ""
Write-Host "Done! Connect using: ssh $hostAlias"
Write-Host ""

$r = Read-Host "Open SSH session now? [Y/n]"
if ($r -notmatch '^[nN]$') {
    & ssh $hostAlias
}

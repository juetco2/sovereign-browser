<#
  STAI Cybershield - launcher + website list (Windows)

  Runs either way:
    - as a script:      right-click -> Run with PowerShell
    - as an .exe:       compiled by build-exe.ps1

  If the Google Cloud CLI isn't installed, the app installs it for you and
  tracks the install on a progress bar. If you aren't signed in, it opens the
  sign-in flow for you. The website list is yours to edit.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------- remote bits --
# Deliberately free of > | & " % so nothing gets mangled passing through
# gcloud.cmd on Windows. $B64 is substituted at call time.
#
# Both of these finish with `bash setup.sh` rather than `docker restart`. A
# restart keeps the container's filesystem, so a stale X lock left behind by the
# previous run makes Xvfb refuse to start ("Server is already active for display
# 1") and the session comes back with a blank screen. setup.sh removes and
# re-creates the container, and it also re-generates policies.json and the hub
# page from the list that was just written, so the page and the policy can never
# drift apart. If the session is gone entirely (Cloud Shell recycled the VM), the
# same call rebuilds it.
$RemotePushStart = 'python3 $HOME/cybershield/write_policy.py $B64; bash $HOME/cybershield/setup.sh > $HOME/cybershield/launch.log 2>&1; for i in $(seq 1 45); do s=$(docker inspect -f {{.State.Health.Status}} cybershield); test $s = healthy && break; sleep 2; done; echo CYBERSHIELD_HOST=$WEB_HOST'
$RemotePushReset = 'python3 $HOME/cybershield/write_policy.py $B64; bash $HOME/cybershield/setup.sh > $HOME/cybershield/launch.log 2>&1; echo CYBERSHIELD_RESET=ok'

$CloudSdkInstaller = 'https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe'

$script:ps          = $null
$script:handle      = $null
$script:marker      = ''
$script:lastUrl     = ''
$script:Gcloud      = $null
$script:SetupAction = 'install'
$script:Account     = ''

# Progress is published from the worker runspace and read here on the UI
# thread, so it has to be a shared, thread-safe object.
$script:Progress = [hashtable]::Synchronized(@{
    phase   = ''
    detail  = ''
    percent = -1
    read    = 0
    total   = 0
})

$script:JobStart   = Get-Date
$script:LastSample = Get-Date
$script:LastRead   = 0
$script:SpeedBps   = 0
$script:MarqueePos = -140

# ------------------------------------------------------------ gcloud lookup -
function Find-Gcloud {
    # Prefer gcloud.cmd / gcloud.exe, and deliberately NEVER gcloud.ps1.
    # The SDK installer puts its bin folder on PATH, and that folder ships
    # gcloud, gcloud.cmd AND gcloud.ps1 - PowerShell's Get-Command prefers the
    # .ps1. Handing a .ps1 to Start-Process goes to the file association, which
    # on a machine with no .ps1 association is a "How do you want to open this
    # file?" dialog rather than a gcloud run.
    foreach ($dir in @($env:Path -split ';')) {
        if (-not $dir) { continue }
        $d = $dir.Trim().Trim('"')
        if (-not $d -or $d.Contains('%')) { continue }   # skip unexpanded %VARS%
        foreach ($n in @('gcloud.cmd', 'gcloud.exe')) {
            try {
                $p = Join-Path $d $n
                if (Test-Path $p) { return $p }
            } catch { }
        }
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
    foreach ($r in $roots) {
        if (-not $r) { continue }
        foreach ($rel in @('Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd',
                           'Google\CloudSDK\google-cloud-sdk\bin\gcloud.cmd')) {
            $p = Join-Path $r $rel
            if (Test-Path $p) { return $p }
        }
    }

    # last resort: whatever the shell resolves, as long as it is not a .ps1
    $cmd = @(Get-Command gcloud -ErrorAction SilentlyContinue) |
           Where-Object { $_.Source -and $_.Source -notlike '*.ps1' } |
           Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Refresh-Path {
    try {
        $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $u = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($m -or $u) { $env:Path = "$m;$u" }
    } catch { }
}

# winget downloads the package into %TEMP%\WinGet before installing it. Watching
# that folder gives a real "bytes downloaded" number even though winget itself
# keeps its own progress bar to itself.
function Get-WingetBytes {
    $t = Join-Path $env:TEMP 'WinGet'
    if (-not (Test-Path $t)) { return 0 }
    try {
        $sum = (Get-ChildItem $t -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { return [int64]$sum }
    } catch { }
    return 0
}

# ------------------------------------------------------ local config file ---
$base = $PSScriptRoot
if (-not $base) {
    $exe = $null
    try { $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if ($exe -and (Split-Path -Leaf $exe) -notmatch '^powershell(_ise)?\.exe$') {
        $base = Split-Path -Parent $exe
    }
}
if (-not $base) { $base = $env:USERPROFILE }
$script:CfgPath = Join-Path $base 'cybershield-sites.json'
$script:LogPath = Join-Path $base 'cybershield.log'

# A plain-text record of every action, next to the .exe, so a demo failure can be
# explained afterwards instead of guessed at. Written from both the UI thread and
# the worker runspace, hence the lock; logging must never be able to crash the
# app, so every failure here is swallowed on purpose.
$script:LogLock = New-Object object

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        [Threading.Monitor]::Enter($script:LogLock)
        try {
            $line = '{0}  {1,-5}  {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        }
        finally { [Threading.Monitor]::Exit($script:LogLock) }
    } catch { }
}

function Normalize-Site([string]$s) {
    $s = $s.Trim().ToLower()
    $s = $s -replace '^[a-z]+://', ''   # strip https://
    $s = $s -replace '/.*$', ''         # strip path
    $s = $s -replace '^www\.', ''       # wildcard covers www anyway
    $s = $s.Trim('.')
    return $s
}

# ------------------------------------------------------------------- UI -----
$form = New-Object Windows.Forms.Form
$form.Text = 'STAI Cybershield'
$form.ClientSize = New-Object Drawing.Size(560, 540)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [Drawing.Color]::FromArgb(11, 16, 32)
$form.ForeColor = [Drawing.Color]::FromArgb(232, 236, 247)
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

$title = New-Object Windows.Forms.Label
$title.Text = 'STAI Cybershield'
$title.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(126, 242, 168)
$title.Location = New-Object Drawing.Point(20, 16)
$title.AutoSize = $true

$btnSetup = New-Object Windows.Forms.Button
$btnSetup.Text = 'Install Google CLI'
$btnSetup.Location = New-Object Drawing.Point(386, 20)
$btnSetup.Size = New-Object Drawing.Size(152, 30)
$btnSetup.FlatStyle = 'Flat'
$btnSetup.FlatAppearance.BorderSize = 0
$btnSetup.BackColor = [Drawing.Color]::FromArgb(24, 30, 50)
$btnSetup.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)

$sub = New-Object Windows.Forms.Label
$sub.Text = 'Pick the websites this session can reach.'
$sub.ForeColor = [Drawing.Color]::FromArgb(139, 151, 184)
$sub.Location = New-Object Drawing.Point(22, 50)
$sub.AutoSize = $true

$lblSites = New-Object Windows.Forms.Label
$lblSites.Text = 'Websites'
$lblSites.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)
$lblSites.Location = New-Object Drawing.Point(22, 84)
$lblSites.AutoSize = $true

$list = New-Object Windows.Forms.ListBox
$list.Location = New-Object Drawing.Point(22, 106)
$list.Size = New-Object Drawing.Size(516, 170)
$list.BackColor = [Drawing.Color]::FromArgb(17, 22, 40)
$list.ForeColor = [Drawing.Color]::FromArgb(232, 236, 247)
$list.BorderStyle = 'FixedSingle'

$txtSite = New-Object Windows.Forms.TextBox
$txtSite.Location = New-Object Drawing.Point(22, 288)
$txtSite.Size = New-Object Drawing.Size(330, 26)
$txtSite.BackColor = [Drawing.Color]::FromArgb(17, 22, 40)
$txtSite.ForeColor = [Drawing.Color]::FromArgb(232, 236, 247)
$txtSite.BorderStyle = 'FixedSingle'

$btnAdd = New-Object Windows.Forms.Button
$btnAdd.Text = 'Add'
$btnAdd.Location = New-Object Drawing.Point(362, 286)
$btnAdd.Size = New-Object Drawing.Size(80, 30)
$btnAdd.FlatStyle = 'Flat'
$btnAdd.FlatAppearance.BorderSize = 0
$btnAdd.BackColor = [Drawing.Color]::FromArgb(24, 30, 50)
$btnAdd.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)

$btnRemove = New-Object Windows.Forms.Button
$btnRemove.Text = 'Remove'
$btnRemove.Location = New-Object Drawing.Point(452, 286)
$btnRemove.Size = New-Object Drawing.Size(86, 30)
$btnRemove.FlatStyle = 'Flat'
$btnRemove.FlatAppearance.BorderSize = 0
$btnRemove.BackColor = [Drawing.Color]::FromArgb(24, 30, 50)
$btnRemove.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)

$rbAllow = New-Object Windows.Forms.RadioButton
$rbAllow.Text = 'Allow only these sites'
$rbAllow.Location = New-Object Drawing.Point(22, 328)
$rbAllow.AutoSize = $true
$rbAllow.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)

$rbBlock = New-Object Windows.Forms.RadioButton
$rbBlock.Text = 'Allow everything except these'
$rbBlock.Location = New-Object Drawing.Point(230, 328)
$rbBlock.AutoSize = $true
$rbBlock.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)

$hint = New-Object Windows.Forms.Label
$hint.Text = 'e.g. khanacademy.org, or paste a full link'
$hint.ForeColor = [Drawing.Color]::FromArgb(120, 130, 155)
$hint.Location = New-Object Drawing.Point(24, 354)
$hint.AutoSize = $true

$btnLaunch = New-Object Windows.Forms.Button
$btnLaunch.Text = 'Launch session'
$btnLaunch.Location = New-Object Drawing.Point(22, 384)
$btnLaunch.Size = New-Object Drawing.Size(200, 48)
$btnLaunch.FlatStyle = 'Flat'
$btnLaunch.FlatAppearance.BorderSize = 0
$btnLaunch.BackColor = [Drawing.Color]::FromArgb(18, 51, 31)
$btnLaunch.ForeColor = [Drawing.Color]::FromArgb(126, 242, 168)

$btnReset = New-Object Windows.Forms.Button
$btnReset.Text = 'Reset session'
$btnReset.Location = New-Object Drawing.Point(234, 384)
$btnReset.Size = New-Object Drawing.Size(140, 48)
$btnReset.FlatStyle = 'Flat'
$btnReset.FlatAppearance.BorderSize = 0
$btnReset.BackColor = [Drawing.Color]::FromArgb(24, 30, 50)
$btnReset.ForeColor = [Drawing.Color]::FromArgb(200, 208, 230)

$status = New-Object Windows.Forms.Label
$status.Text = 'Ready.'
$status.Location = New-Object Drawing.Point(22, 438)
$status.Size = New-Object Drawing.Size(516, 60)
$status.ForeColor = [Drawing.Color]::FromArgb(180, 190, 215)

# hand-drawn progress bar - the themed WinForms one looks wrong on a dark form
$barTrough = New-Object Windows.Forms.Panel
$barTrough.Location = New-Object Drawing.Point(22, 504)
$barTrough.Size = New-Object Drawing.Size(516, 12)
$barTrough.BackColor = [Drawing.Color]::FromArgb(26, 33, 54)
$barTrough.Visible = $false

$barFill = New-Object Windows.Forms.Panel
$barFill.Location = New-Object Drawing.Point(0, 0)
$barFill.Size = New-Object Drawing.Size(0, 12)
$barFill.BackColor = [Drawing.Color]::FromArgb(126, 242, 168)
$barFill.Visible = $false
$barTrough.Controls.Add($barFill)

$form.Controls.AddRange(@($title, $btnSetup, $sub, $lblSites, $list, $txtSite,
                          $btnAdd, $btnRemove, $rbAllow, $rbBlock, $hint,
                          $btnLaunch, $btnReset, $status, $barTrough, $barFill))
$form.AcceptButton = $btnAdd

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

# ---------------------------------------------------------- install tracker --
function Reset-Progress {
    param([string]$Phase)
    $script:Progress['phase']   = $Phase
    $script:Progress['detail']  = ''
    $script:Progress['percent'] = -1
    $script:Progress['read']    = 0
    $script:Progress['total']   = 0
    $script:JobStart   = Get-Date
    $script:LastSample = Get-Date
    $script:LastRead   = 0
    $script:SpeedBps   = 0
    $script:MarqueePos = -140
}

function Format-Size {
    param([int64]$bytes)
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

function Render-Tracker {
    $p = $script:Progress

    # winget keeps its download in %TEMP%\WinGet - read it while we wait
    if ($script:marker -eq 'CYBERSHIELD_INSTALL' -and [int]$p['percent'] -lt 0) {
        $b = Get-WingetBytes
        if ($b -gt 0) { $p['detail'] = "$(Format-Size $b) downloaded" }
    }

    $barTrough.Visible = $true
    $barFill.Visible   = $true

    if ([int]$p['total'] -gt 0) {
        # determinate: we know the size, so show speed as well
        $now = Get-Date
        $dt = ($now - $script:LastSample).TotalSeconds
        if ($dt -gt 0.1) {
            $delta = [int64]$p['read'] - $script:LastRead
            if ($delta -ge 0) { $script:SpeedBps = [int64]($delta / $dt) }
            $script:LastRead = [int64]$p['read']
            $script:LastSample = $now
        }
        $pct = [int][Math]::Min(100, [Math]::Max(0, [int]$p['percent']))
        $barFill.Left  = 0
        $barFill.Width = [int]($barTrough.Width * $pct / 100)

        $detail = "$pct%  -  $(Format-Size ([int64]$p['read'])) / $(Format-Size ([int64]$p['total']))"
        if ($script:SpeedBps -gt 0) { $detail += "  -  $(Format-Size $script:SpeedBps)/s" }
    }
    else {
        # indeterminate: slide a block so there is always visible motion
        $script:MarqueePos += 14
        if ($script:MarqueePos -gt ($barTrough.Width + 140)) { $script:MarqueePos = -140 }
        $barFill.Width = 140
        $barFill.Left  = $script:MarqueePos
        $detail = "$($p['detail'])"
    }

    $secs = [int]((Get-Date) - $script:JobStart).TotalSeconds
    $elapsed = '{0}:{1:00}' -f [int]($secs / 60), ($secs % 60)

    $lines = @()
    if ($p['phase']) { $lines += "$($p['phase'])" }
    if ($detail.Trim()) { $lines += "   $detail" }
    $lines += "   elapsed $elapsed"
    $status.Text = ($lines -join "`r`n")
}

function Stop-Tracker {
    $barTrough.Visible = $false
    $barFill.Visible   = $false
}

# ----------------------------------------------------------- UI state -------
function Update-Ui {
    $script:Gcloud = Find-Gcloud
    $has = [bool]$script:Gcloud
    $btnLaunch.Enabled = $has
    $btnReset.Enabled  = $has

    # Any finished job disables this button, so it MUST be re-enabled here or it
    # stays greyed out forever after the first install/sign-in attempt.
    $btnSetup.Enabled = $true

    if ($has) {
        $script:SetupAction = 'auth'
        if ($script:Account) { $btnSetup.Text = 'Sign in again' }
        else                 { $btnSetup.Text = 'Sign in to Google' }
    } else {
        $script:SetupAction = 'install'
        $btnSetup.Text = 'Install Google CLI'
    }
    $lblSites.Text = "Websites ($($list.Items.Count))"
}

# ------------------------------------------------------- config handling ----
function Save-Config {
    $cfg = [ordered]@{
        mode  = $(if ($rbBlock.Checked) { 'block' } else { 'allow' })
        sites = @($list.Items | ForEach-Object { "$_" })
    }
    try {
        ($cfg | ConvertTo-Json -Depth 4) | Set-Content -Path $script:CfgPath -Encoding UTF8
    } catch { }
    $lblSites.Text = "Websites ($($list.Items.Count))"
}

function Load-Config {
    if (Test-Path $script:CfgPath) {
        try {
            $cfg = Get-Content $script:CfgPath -Raw | ConvertFrom-Json
            $list.Items.Clear()
            foreach ($s in @($cfg.sites)) { if ($s) { [void]$list.Items.Add("$s") } }
            if ($cfg.mode -eq 'block') { $rbBlock.Checked = $true } else { $rbAllow.Checked = $true }
        } catch { }
    }
    else {
        foreach ($s in @('wikipedia.org', 'khanacademy.org')) { [void]$list.Items.Add($s) }
        $rbAllow.Checked = $true
    }
    $lblSites.Text = "Websites ($($list.Items.Count))"
}

function Get-PolicyBlob {
    $cfg = [ordered]@{
        mode  = $(if ($rbBlock.Checked) { 'block' } else { 'allow' })
        sites = @($list.Items | ForEach-Object { "$_" })
    }
    $json = $cfg | ConvertTo-Json -Depth 4 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

# ------------------------------------------------------------- plumbing -----
$timer.Add_Tick({
    try {
        if ($null -eq $script:handle) { return }

        if (-not $script:handle.IsCompleted) {
            Render-Tracker
            return
        }

        $timer.Stop()
        Stop-Tracker

        $out = ''
        try { $out = ($script:ps.EndInvoke($script:handle) | Out-String) } catch { $out = "$_" }
        if ($script:ps.Streams.Error.Count -gt 0) { $out += ($script:ps.Streams.Error | Out-String) }
        $script:ps.Dispose()
        $script:ps = $null
        $script:handle = $null

        switch ($script:marker) {

            'CYBERSHIELD_HOST' {
                Update-Ui
                $m = [regex]::Match($out, 'CYBERSHIELD_HOST=(\S+)')
                if ($m.Success) {
                    $webHost = $m.Groups[1].Value
                    $script:lastUrl = "https://6080-$webHost/?quality=2&compression=1&scalingMode=scale&clipToWindow=true&dotCursor=true"
                    $status.Text = 'Session ready - opening browser...'
                    Write-Log "Launch OK - $($list.Items.Count) sites, url $($script:lastUrl)"
                    Write-Log "reply tail: $(($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / ')"
                    Start-Process $script:lastUrl
                    $status.Text = "Running with $($list.Items.Count) sites. Reopen: $($script:lastUrl)"
                } else {
                    Write-Log "Launch FAILED - no CYBERSHIELD_HOST in the reply" 'ERROR'
                    Write-Log "reply: $(($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' / ')" 'ERROR'
                    $status.Text = 'Could not reach the session. Check Cloud Shell: bash ~/cybershield/setup.sh'
                }
            }

            'CYBERSHIELD_RESET' {
                Update-Ui
                if ($out -match 'CYBERSHIELD_RESET=ok') {
                    $status.Text = "Session reset - blank machine, $($list.Items.Count) sites applied."
                    Write-Log "Reset OK - $($list.Items.Count) sites"
                    if ($script:lastUrl) { Start-Process $script:lastUrl }
                } else {
                    Write-Log "Reset FAILED - reply: $(($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' / ')" 'ERROR'
                    $status.Text = 'Reset failed - is the container running?'
                }
            }

            'CYBERSHIELD_INSTALL' {
                Refresh-Path
                Update-Ui
                if ($script:Gcloud) {
                    Write-Log "Install OK - gcloud at $($script:Gcloud)"
                    $status.Text = "Google Cloud CLI installed.`r`n   Click 'Sign in to Google' to finish."
                } else {
                    $tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join "`r`n"
                    Write-Log "Install FAILED - $tail" 'ERROR'
                    $status.Text = "Install did not complete.`r`n$tail`r`nManual install: https://cloud.google.com/sdk/docs/install"
                }
            }

            'CYBERSHIELD_AUTH' {
                $m2 = [regex]::Match($out, 'CYBERSHIELD_AUTH=(.*)')
                if ($m2.Success) { $script:Account = $m2.Groups[1].Value.Trim() }
                Update-Ui
                if ($script:Account) {
                    Write-Log "Sign-in OK - $($script:Account)"
                    $status.Text = "Signed in as $($script:Account).`r`n   Click Launch session."
                } else {
                    Write-Log 'Sign-in FAILED - nobody signed in afterwards' 'ERROR'
                    $status.Text = "Sign-in did not complete.`r`n   Run it by hand if you need to: gcloud auth login"
                }
            }

            'CYBERSHIELD_AUTHCHECK' {
                $m2 = [regex]::Match($out, 'CYBERSHIELD_AUTH=(.*)')
                if ($m2.Success) { $script:Account = $m2.Groups[1].Value.Trim() }
                Update-Ui
                if ($script:Account) {
                    Write-Log "Sign-in check OK - $($script:Account)"
                    $status.Text = "Ready. Signed in as $($script:Account)"
                } else {
                    Write-Log 'Sign-in check - nobody signed in'
                    $status.Text = 'Google Cloud CLI found, but nobody is signed in. Click "Sign in to Google".'
                }
            }
        }
    }
    catch {
        $timer.Stop()
        Stop-Tracker
        if ($script:ps) { $script:ps.Dispose(); $script:ps = $null }
        $script:handle = $null
        Update-Ui
        Write-Log "Exception - $($_.Exception.Message)" 'ERROR'
        $status.Text = "Error: $($_.Exception.Message)"
    }
})

function Start-Job2 {
    param([scriptblock]$Body, [object[]]$Arguments, [string]$Marker, [string]$Phase)

    $btnLaunch.Enabled = $false
    $btnReset.Enabled  = $false
    $btnSetup.Enabled  = $false
    $script:marker = $Marker
    Reset-Progress $Phase
    Write-Log "$Marker started - $Phase"

    # In-process runspace: keeps the window responsive, and works without a
    # console, which matters once this is compiled to an .exe.
    $script:ps = [PowerShell]::Create()
    [void]$script:ps.AddScript($Body)
    foreach ($a in $Arguments) { [void]$script:ps.AddArgument($a) }
    $script:handle = $script:ps.BeginInvoke()
    $timer.Start()
}

# Start-Remote runs one command inside Cloud Shell and returns everything it
# printed. It is written the long way on purpose, because the obvious version
# (just calling gcloud and reading the output) hangs forever on Windows:
#
#   * `gcloud cloud-shell ssh` does not talk SSH itself on Windows, it drives
#     PuTTY's plink through a local websocket tunnel. It has three connection
#     attempts, and EACH attempt opens a NEW random local port. PuTTY caches
#     host keys per host:port, so every attempt looks like a brand new server
#     and asks the "Store key in cache? (y/n)" question. That question goes to
#     the console and is read from stdin. With no console - which is exactly how
#     a captured, windowless call behaves - it blocks there for good. That is
#     the famous "stuck on Listening on local port [N]." hang.
#   * `--ssh-flag="-legacy-stdio-prompts"` moves the question onto the standard
#     streams, where we can see it and answer it.
#   * The answer has to keep coming. plink swallows the whole stdin pipe into
#     its own buffer on the first prompt, so a single "y" is spent on attempt 1
#     (which always fails anyway - it asks for publickey auth) and attempt 2
#     then reads EOF and gives up with "Connection abandoned." So we keep
#     writing "y" until the process actually exits. Attempt 2, over the tunnel's
#     port 2222, is the one that succeeds.
#
# The call also goes through a one-line .cmd shim rather than a PowerShell
# argument list, for the same reason the sign-in does: gcloud is a .cmd, and
# cmd.exe eats quotes and meaning from `>`, `|`, `&`. The batch file keeps the
# remote command intact.
function Start-Remote {
    param([string]$Template, [string]$Marker, [string]$Phase)
    $command = $Template.Replace('$B64', (Get-PolicyBlob))
    $exe = $script:Gcloud
    $prog = $script:Progress
    Start-Job2 -Marker $Marker -Phase $Phase -Arguments @($exe, $command, $prog) -Body {
        param($gcloudExe, $c, $prog)

        # gcloud is a python program, and python block-buffers its output when it
        # is not attached to a console. Unbuffered keeps Cloud Shell's progress
        # visible while it works instead of dumping it all at the end.
        $env:PYTHONUNBUFFERED = '1'
        $env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'

        $dir = Join-Path $env:TEMP 'cybershield-remote'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bat = Join-Path $dir 'run.cmd'
        Set-Content -LiteralPath $bat -Encoding ASCII -Value @(
            '@echo off',
            ('call "' + $gcloudExe + '" cloud-shell ssh --authorize-session --quiet ' +
             '--ssh-flag="-legacy-stdio-prompts" --command "' + $c + '"')
        )

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $env:ComSpec
        $psi.Arguments              = '/c "' + $bat + '"'
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.WorkingDirectory       = $dir

        $prog['detail'] = 'connecting to Cloud Shell'
        $p = [System.Diagnostics.Process]::Start($psi)

        # Reading line by line (rather than ReadToEnd) is what feeds the tracker,
        # so the window shows what Cloud Shell is doing the whole time.
        $outTask = $p.StandardOutput.ReadLineAsync()
        $errTask = $p.StandardError.ReadLineAsync()

        $sb = New-Object System.Text.StringBuilder
        $sw = [Diagnostics.Stopwatch]::StartNew()

        while (-not $p.HasExited -and $sw.Elapsed.TotalMinutes -lt 45) {
            try { $p.StandardInput.Write("y`n"); $p.StandardInput.Flush() } catch { }

            if ($outTask.IsCompleted) {
                $l = $outTask.Result
                if ($null -ne $l) {
                    [void]$sb.AppendLine($l)
                    $t = $l.Trim()
                    if ($t) {
                        if ($t.Length -gt 110) { $t = $t.Substring(0, 110) }
                        $prog['detail'] = $t
                    }
                }
                $outTask = $p.StandardOutput.ReadLineAsync()
            }
            if ($errTask.IsCompleted) {
                $l = $errTask.Result
                if ($null -ne $l) {
                    [void]$sb.AppendLine($l)
                    $t = $l.Trim()
                    if ($t) {
                        if ($t.Length -gt 110) { $t = $t.Substring(0, 110) }
                        $prog['detail'] = $t
                    }
                }
                $errTask = $p.StandardError.ReadLineAsync()
            }

            Start-Sleep -Milliseconds 200
        }

        $timedOut = -not $p.HasExited
        if ($timedOut) { try { $p.Kill() } catch { } }
        Start-Sleep -Milliseconds 500

        # Whatever was still in flight when the process ended.
        try { [void]$sb.Append($p.StandardOutput.ReadToEnd()) } catch { }
        try { [void]$sb.Append($p.StandardError.ReadToEnd()) } catch { }
        try { $p.Dispose() } catch { }
        try { Remove-Item -LiteralPath $bat -Force } catch { }

        $text = $sb.ToString()
        if ($timedOut) {
            $text += "`nCYBERSHIELD: Cloud Shell did not answer within $([int]$sw.Elapsed.TotalSeconds) seconds."
        }
        $text
    }
}

# --------------------------------------------------- install / sign-in job --
$InstallGoogleCli = {
    param($url, $prog)

    $ErrorActionPreference = 'Continue'
    $ok = $false

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $prog['phase']  = 'Installing via winget'
        $prog['detail'] = 'resolving Google.CloudSDK'
        $prog['percent'] = -1
        & winget install --id Google.CloudSDK -e --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $ok = $true }
        else { $prog['detail'] = "winget exited with code $LASTEXITCODE - falling back" }
    }

    if (-not $ok) {
        # Download the official installer ourselves so the byte count is real.
        $prog['phase']   = 'Downloading the official installer'
        $prog['percent'] = 0
        $dest = Join-Path $env:TEMP 'GoogleCloudSDKInstaller.exe'

        try { Add-Type -AssemblyName System.Net.Http } catch { }
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(30)
        $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $resp.EnsureSuccessStatusCode() | Out-Null

        $total = $resp.Content.Headers.ContentLength
        if (-not $total) { $total = 0 }
        $prog['total'] = [int64]$total
        $prog['read']  = 0

        $in  = $resp.Content.ReadAsStreamAsync().Result
        $out = [IO.File]::Create($dest)
        $buf = New-Object byte[] 131072
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $prog['read'] = [int64]($prog['read'] + $n)
            if ($total -gt 0) {
                $prog['percent'] = [int](100 * $prog['read'] / $total)
            }
        }
        $out.Close(); $out.Dispose()
        $in.Close();  $in.Dispose()
        $client.Dispose()

        $prog['percent'] = 100
        $prog['phase']   = 'Running the installer'
        $prog['detail']  = 'approve the Windows prompt - click through the wizard'
        Start-Sleep -Milliseconds 400
        $prog['total'] = 0
        $prog['percent'] = -1
        Start-Process -FilePath $dest -Wait
    }

    $prog['phase']  = 'Finishing up'
    $prog['detail'] = 'checking the install'
    $prog['total'] = 0
    $prog['percent'] = -1

    'CYBERSHIELD_INSTALL=ok'
}

# Sign-in runs in its own visible console window on purpose: gcloud prints the
# login URL there, so if the browser does not open by itself you can still read
# and copy the URL, instead of watching a bar that never moves. Afterwards we ask
# gcloud who is actually signed in, so the window reports a fact, not a guess.
$SignInJob = {
    param($gcloudExe, $prog, $mode)

    if ($mode -eq 'login') {
        $prog['phase']  = 'Signing in to Google'
        $prog['detail'] = 'finish the sign-in in the cmd window that just opened'

        # Run it in a real cmd window. A batch wrapper rather than quoting the
        # path on cmd's own command line, because the Cloud SDK often lives under
        # "C:\Program Files (x86)\..." and cmd strips the quotes around a path
        # like that. The wrapper also holds the window open when the sign-in
        # fails, so the error stays on screen instead of flashing past.
        # `call` is essential: invoking a .cmd without it hands control over
        # permanently, so the wrapper's own error handling below would never run.
        $exeLine = 'call "' + $gcloudExe + '" auth login'
        $bat = Join-Path $env:TEMP 'cybershield-signin.cmd'
        try {
            Set-Content -LiteralPath $bat -Encoding ASCII -Value @(
                '@echo off'
                'title Cybershield - Google sign-in'
                'echo Opening your browser for the Google sign-in...'
                'echo.'
                $exeLine
                'if errorlevel 1 ('
                '    echo.'
                '    echo Sign-in did not complete - the message above says why.'
                '    echo.'
                '    pause'
                ')'
            )
            Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'cybershield-signin.cmd' `
                          -WorkingDirectory $env:TEMP -Wait
        }
        catch {
            $prog['detail'] = "could not start the sign-in: $($_.Exception.Message)"
        }
    }

    $prog['phase']  = 'Checking the sign-in'
    $prog['detail'] = 'asking gcloud who is signed in'

    $account = ''
    try {
        # No --filter=status:ACTIVE here: gcloud emits a confusing "filter keys
        # were not present in any resource" warning when the account list is
        # empty. Asking for every credentialed account is warning-free and is the
        # same answer for our purposes ("is anyone signed in?").
        $raw = (& $gcloudExe auth list '--format=value(account)' 2>&1 | Out-String)
        $account = ($raw -split "`n" |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -match '@' } |
                    Select-Object -Last 1)
    }
    catch { }

    if ($account) { $prog['detail'] = "signed in as $account" }
    "CYBERSHIELD_AUTH=$account"
}

$btnSetup.Add_Click({
    if ($script:SetupAction -eq 'install') {
        Start-Job2 -Marker 'CYBERSHIELD_INSTALL' -Phase 'Starting the install' `
                   -Arguments @($CloudSdkInstaller, $script:Progress) -Body $InstallGoogleCli
    }
    else {
        $status.Text = 'A console window is opening for the sign-in...'
        $g = $script:Gcloud
        Start-Job2 -Marker 'CYBERSHIELD_AUTH' -Phase 'Signing in to Google' `
                   -Arguments @($g, $script:Progress, 'login') -Body $SignInJob
    }
})

# ---------------------------------------------------------------- events ----
$btnAdd.Add_Click({
    $s = Normalize-Site $txtSite.Text
    if ($s -and -not $list.Items.Contains($s)) { [void]$list.Items.Add($s) }
    $txtSite.Clear()
    Save-Config
})

$txtSite.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $s = Normalize-Site $txtSite.Text
        if ($s -and -not $list.Items.Contains($s)) { [void]$list.Items.Add($s) }
        $txtSite.Clear()
        Save-Config
        $_.SuppressKeyPress = $true
    }
})

$btnRemove.Add_Click({
    if ($list.SelectedIndex -ge 0) { $list.Items.RemoveAt($list.SelectedIndex) }
    Save-Config
})

$rbAllow.Add_CheckedChanged({ Save-Config })
$rbBlock.Add_CheckedChanged({ Save-Config })

$btnLaunch.Add_Click({
    Write-Log "Launch clicked - mode=$(if ($rbBlock.Checked) { 'block' } else { 'allow' }) sites=$(@($list.Items) -join ',')"
    Start-Remote $RemotePushStart 'CYBERSHIELD_HOST' 'Provisioning the Cloud Shell session'
})

$btnReset.Add_Click({
    Write-Log "Reset clicked - mode=$(if ($rbBlock.Checked) { 'block' } else { 'allow' }) sites=$(@($list.Items) -join ',')"
    Start-Remote $RemotePushReset 'CYBERSHIELD_RESET' 'Applying the website list and restarting'
})

# ------------------------------------------------------------------ init ----
Write-Log "app start - $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)"
Load-Config
Update-Ui
Write-Log "config loaded - $($list.Items.Count) sites, mode $(if ($rbBlock.Checked) { 'block' } else { 'allow' }), file $script:CfgPath"
if ($script:Gcloud) {
    Write-Log "gcloud found - $($script:Gcloud)"
    # Ask gcloud up front, so the window tells you whether you are signed in
    # rather than letting you find out when Launch fails.
    $g = $script:Gcloud
    $status.Text = 'Google Cloud CLI found. Checking the sign-in...'
    Start-Job2 -Marker 'CYBERSHIELD_AUTHCHECK' -Phase 'Checking the sign-in' `
               -Arguments @($g, $script:Progress, 'check') -Body $SignInJob
} else {
    Write-Log 'gcloud not found - install needed'
    $status.Text = 'Google Cloud CLI not found. Click "Install Google CLI" to install it (~100 MB, one time).'
}

try {
    [void]$form.ShowDialog()
}
catch {
    [void][Windows.Forms.MessageBox]::Show("$($_.Exception.Message)", 'STAI Cybershield')
}

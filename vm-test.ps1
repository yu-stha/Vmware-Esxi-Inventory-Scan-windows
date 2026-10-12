# ESXi VM inventory
# Run with:  irm <url-to-this-file> | iex
# Everything runs inside a script block so no variables leak into your session.

& {
    # ---- Install PowerCLI only if no PowerCLI module is present ----
    $hasPowerCLI = (Get-Module -ListAvailable -Name VMware.PowerCLI) -or
                   (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)

    if (-not $hasPowerCLI) {
        Write-Host "PowerCLI not found. Installing VMware.PowerCLI for the current user (can take several minutes)..." -ForegroundColor Yellow
        try {
            # PSGallery requires TLS 1.2 (older Windows PowerShell 5.1 defaults to less)
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

            # Install-Module needs the NuGet provider
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
            }

            # -Force skips the "untrusted repository" prompt
            Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "PowerCLI installed." -ForegroundColor Green
        } catch {
            Write-Host "Could not install PowerCLI: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Check internet/proxy access to PSGallery, or install it manually: Install-Module VMware.PowerCLI -Scope CurrentUser" -ForegroundColor Red
            return
        }
    }

    # ---- Load PowerCLI (works with the old MSI install or the PSGallery bundle) ----
    try {
        if (Get-Module -ListAvailable -Name VMware.PowerCLI) {
            Import-Module VMware.PowerCLI -ErrorAction Stop
        } else {
            Import-Module VMware.VimAutomation.Core -ErrorAction Stop
        }
    } catch {
        Write-Host "PowerCLI is not installed or failed to load: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # Self-signed ESXi certs: ignore the error for this session only
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

    # ---- Ask for hosts (comma, semicolon or space separated) ----
    $raw = Read-Host "Enter ESXi IPs/hostnames (separate multiple with commas)"
    $hosts = @($raw -split '[,;\s]+' | Where-Object { $_ } | Select-Object -Unique)
    if ($hosts.Count -eq 0) {
        Write-Host "No hosts entered. Exiting." -ForegroundColor Red
        return
    }

    # ---- Credentials: shared for all hosts, or one prompt per host ----
    $useShared = $true
    if ($hosts.Count -gt 1) {
        $answer = Read-Host "Use the same credentials for all hosts? (Y/N, default Y)"
        if ($answer -match '^[Nn]') { $useShared = $false }
    }
    if ($useShared) {
        $sharedCred = Get-Credential -Message "ESXi credentials (use a read-only account)"
        if (-not $sharedCred) { return }
    }

    # ---- Collect ----
    $inventory = New-Object System.Collections.Generic.List[object]

    foreach ($h in $hosts) {
        if ($useShared) {
            $hostCred = $sharedCred
        } else {
            $hostCred = Get-Credential -Message "Credentials for $h"
        }

        $connected = $false
        while (-not $connected) {
            if (-not $hostCred) { break }
            try {
                Connect-VIServer -Server $h -Credential $hostCred -ErrorAction Stop | Out-Null
                $connected = $true
            } catch {
                Write-Warning "Cannot connect to ${h}: $($_.Exception.Message)"
                $retry = Read-Host "Retry $h with different credentials? (Y/N)"
                if ($retry -match '^[Yy]') {
                    $hostCred = Get-Credential -Message "Credentials for $h"
                } else {
                    break
                }
            }
        }
        if (-not $connected) { continue }

        try {
            $vms = @(Get-VM -Server $h)
            Write-Host "$h : $($vms.Count) VMs"

            foreach ($vm in $vms) {
                $disks = @(Get-HardDisk -VM $vm -Server $h)
                $nics  = @(Get-NetworkAdapter -VM $vm -Server $h)
                $ds    = @(Get-Datastore -RelatedObject $vm -Server $h)

                $allocated = ($disks | Measure-Object CapacityGB -Sum).Sum
                if (-not $allocated) { $allocated = 0 }
                $used = $vm.UsedSpaceGB
                if (-not $used) { $used = 0 }

                $inventory.Add([pscustomobject][ordered]@{
                    ESXi            = $h
                    Name            = $vm.Name
                    PowerState      = $vm.PowerState
                    NumCpu          = $vm.NumCpu
                    MemoryGB        = $vm.MemoryGB
                    IP              = ($vm.Guest.IPAddress -join ',')
                    UUID            = $vm.ExtensionData.Config.InstanceUuid
                    DiskCount       = $disks.Count
                    DiskAllocatedGB = [math]::Round($allocated, 1)
                    DatastoreUsedGB = [math]::Round($used, 1)
                    Datastore       = ($ds.Name -join ',')
                    Network         = ($nics.NetworkName -join ',')
                    MAC             = ($nics.MacAddress -join ',')
                    NicType         = ($nics.Type -join ',')
                })
            }
        } catch {
            Write-Warning "Error while collecting from ${h}: $($_.Exception.Message)"
        } finally {
            Disconnect-VIServer -Server $h -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    if ($inventory.Count -eq 0) {
        Write-Host "No VMs collected." -ForegroundColor Yellow
        return
    }

    # ---- Export with timestamp ----
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvPath   = Join-Path (Get-Location).Path "vm-inventory-$timestamp.csv"
    $inventory | Export-Csv -Path $csvPath -NoTypeInformation

    # ---- Display ----
    $inventory | Sort-Object ESXi, Name |
        Select-Object ESXi, Name, PowerState, DiskAllocatedGB, Datastore, Network, IP |
        Format-Table -AutoSize

    $inventory | Group-Object ESXi | Select-Object @{n='ESXi';e={$_.Name}}, Count | Format-Table -AutoSize

    Write-Host "Saved: $csvPath" -ForegroundColor Green
}
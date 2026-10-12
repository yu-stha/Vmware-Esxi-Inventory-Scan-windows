# VMware ESXi Inventory Scan (Windows)

A PowerShell script that connects to one or more standalone ESXi hosts, pulls every VM on each host, and saves the result to a timestamped CSV. Use it to keep an asset inventory current when VMs are frequently added or deleted.

## What it collects

For each VM:

| Column | Description |
|---|---|
| ESXi | Host the VM was read from |
| Name | VM name |
| PowerState | PoweredOn / PoweredOff / Suspended |
| NumCpu, MemoryGB | Allocated vCPU and RAM |
| IP | Guest IP addresses (empty if VMware Tools is not running) |
| UUID | VM instance UUID (stable key; names can be reused) |
| DiskCount | Number of virtual disks |
| DiskAllocatedGB | Sum of all virtual disk sizes |
| DatastoreUsedGB | Space the VM actually uses on the datastore (includes snapshots and swap) |
| Datastore | Datastore(s) holding the VM |
| Network, MAC, NicType | Port group, MAC address and adapter type per NIC, in NIC order |

The script also prints a per-host VM count and a summary table.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Network access to the ESXi hosts (HTTPS, port 443)
- VMware PowerCLI. If it is missing, the script installs `VMware.PowerCLI` for the current user. This needs internet access to PSGallery and takes several minutes the first time.
- An ESXi account. A **read-only** account is enough and recommended.

## Usage

### Run directly from GitHub

```powershell
irm https://raw.githubusercontent.com/yu-stha/Vmware-Esxi-Inventory-Scan-windows/main/Get-VMInventory.ps1 | iex
```

`iex` executes whatever is at that URL. Review the script before running it, and pin the URL to a commit hash if you share it with others.

### Run the downloaded file

```powershell
Unblock-File .\Get-VMInventory.ps1
.\Get-VMInventory.ps1
```

`Unblock-File` is only needed for files downloaded from the internet when your execution policy is `RemoteSigned`. To run once without changing anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-VMInventory.ps1
```

### What you will be asked

1. **ESXi IPs or hostnames**, comma-separated, for example `10.10.101.11,10.10.101.12`.
2. **Same credentials for all hosts?** (only asked when you enter more than one host). Answer `N` to be prompted per host.
3. **Credentials** via a popup. If a login fails, you are offered a retry with different credentials for that host.

## Output

A file named `vm-inventory-<yyyyMMdd-HHmmss>.csv` is written to the folder you ran the script from, for example `vm-inventory-20261012-153045.csv`. The full path is printed at the end.

Run it from a folder you can write to (not `C:\WINDOWS\system32`).

## Security notes

- The script never stores or hardcodes passwords. Credentials are prompted for and used in memory only.
- Use a read-only ESXi account.
- Certificate validation is disabled for the current PowerShell session only, because ESXi hosts use self-signed certificates by default.
- **The output CSV contains internal IPs, MAC addresses and VM names. Do not commit it to Git.** Add this to `.gitignore`:

  ```
  vm-inventory-*.csv
  ```

- Repeated failed logins can lock an ESXi account (5 failures for about 15 minutes by default). Check the password before retrying more than once.

## Troubleshooting

| Problem | Fix |
|---|---|
| `running scripts is disabled` or `not digitally signed` | Use `Unblock-File`, or the `irm \| iex` method, which is not affected by execution policy |
| `Cannot connect to <host>` | Check the IP, port 443 reachability, and the credentials |
| SSL/TLS or secure-connection error on connect | Old PowerCLI (6.5) against a newer ESXi. Upgrade: `Install-Module VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber` |
| `Install-Module` fails | Check access to PSGallery (proxy or firewall), or install PowerCLI manually |
| Empty `IP` column | VMware Tools is not running in that VM. Use `MAC` and `Network` instead |
| Every host shows the same VM count | Stale sessions are open. Run `Disconnect-VIServer -Server * -Confirm:$false` and rerun |

## Limitations

- Standalone ESXi hosts only. With vCenter, a single connection to vCenter is a better approach.
- Templates and powered-off VMs are included. Filter on `PowerState` if you do not want them.
- Several PowerCLI calls are made per VM, so very large environments will be slow.
# Powershell script for Zabbix agents (Updated for Zabbix Agent 2)
# Version 2.5 - separate full OS string (inv.WinOSFull) and install date (inv.OSInstallDate)
#
# Sends every value with zabbix_sender. Each "inv.*" key needs a matching
# "Zabbix trapper" item on the host (see key list at the bottom).

# ------------------------------------------------------------------------- #
# Settings
# ------------------------------------------------------------------------- #

# Location lookup changes machine-wide Windows location settings.
# Leave $false unless you really want it.
$UseGeolocation = $false


# ------------------------------------------------------------------------- #
# Variables & Path Detection
# ------------------------------------------------------------------------- #

if (Test-Path "$Env:Programfiles\Zabbix Agent 2") {
    $ZabbixInstallPath = "$Env:Programfiles\Zabbix Agent 2"
    $ConfigFile = "$ZabbixInstallPath\zabbix_agent2.conf"
} else {
    $ZabbixInstallPath = "$Env:Programfiles\Zabbix Agent"
    $ConfigFile = "$ZabbixInstallPath\zabbix_agentd.conf"
}

$Sender         = "$ZabbixInstallPath\zabbix_sender.exe"
$TempOutputFile = Join-Path $env:TEMP "wininvstatus.txt"

if (-not (Test-Path $Sender)) {
    Write-Output "ERROR: zabbix_sender.exe not found at $Sender"
    exit 1
}

# Build one sender line: - key "value" (hostname "-" = Hostname from agent config)
$Lines = New-Object System.Collections.Generic.List[string]
function Add-Inv {
    param([string]$Key, $Value)
    $v = ([string]$Value) -replace '[\r\n]+', ' '
    $v = $v -replace '\\', '\\'
    $v = $v -replace '"', '\"'
    $Lines.Add("- $Key ""$v""")
}


# ------------------------------------------------------------------------- #
# Gather Full System Information
# ------------------------------------------------------------------------- #

# Operating System
$OSInfo        = Get-CimInstance Win32_OperatingSystem
$WinOS         = $OSInfo.Caption
$Winarch       = $OSInfo.OSArchitecture
$WinBuild      = $OSInfo.BuildNumber
$OSInstallDate = $OSInfo.InstallDate.ToString("d")
$LastBoot      = $OSInfo.LastBootUpTime.ToString("yyyy-MM-dd HH:mm")
$CurVer        = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$WinVersion    = $CurVer.DisplayVersion
$WinBuildFull  = if ($CurVer.UBR -ne $null) { "$WinBuild.$($CurVer.UBR)" } else { $WinBuild }
$WinOSFull     = "$WinOS $WinVersion (build $WinBuildFull) $Winarch | Installed: $OSInstallDate"

# System & Computer
$CSInfo        = Get-CimInstance Win32_ComputerSystem
$SystemName    = $CSInfo.Name
$ModelNum      = $CSInfo.Model
$Manuf         = $CSInfo.Manufacturer
$WinDomain     = $CSInfo.Domain
$Owner         = $CSInfo.PrimaryOwnerName
$Loggedon      = $CSInfo.UserName

# Signed-in users (any session with an explorer.exe: console, RDP, disconnected)
try {
    $UserNames = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
        $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        if ($o.User) { "$($o.Domain)\$($o.User)" }
    } | Sort-Object -Unique
} catch {
    $UserNames = @()
}
$UserCount = @($UserNames).Count
$UserList  = if ($UserCount -gt 0) { @($UserNames) -join ', ' } else { 'none' }

# BIOS & Motherboard
$BIOS          = Get-CimInstance Win32_BIOS
$SerialNum     = $BIOS.SerialNumber
$BIOSDate      = if ($BIOS.ReleaseDate) { $BIOS.ReleaseDate.ToString("d") } else { "" }
$Board         = Get-CimInstance Win32_BaseBoard
$MoboModel     = "$($Board.Manufacturer) $($Board.Product)"

# Processor (CPU)
$CPU           = Get-CimInstance Win32_Processor | Select-Object -First 1
$CPUName       = $CPU.Name.Trim()
$CPUCores      = "$($CPU.NumberOfCores) Cores / $($CPU.NumberOfLogicalProcessors) Threads"

# Memory (RAM)
$TotalRAMGB    = [math]::Round($CSInfo.TotalPhysicalMemory / 1GB, 2)
$FreeRAMGB     = [math]::Round($OSInfo.FreePhysicalMemory / 1MB, 2)
$RAMSpeed      = (Get-CimInstance Win32_PhysicalMemory | Select-Object -ExpandProperty ConfiguredClockSpeed -First 1)

# Graphics (GPU)
$GPU           = Get-CimInstance Win32_VideoController | Select-Object -First 1
$GPUName       = $GPU.Name


# ------------------------------------------------------------------------- #
# Multi-Drive Storage & Media Type Detection
# ------------------------------------------------------------------------- #

# 1. Detect media types (NVMe, SSD, HDD) - BusType is used for NVMe,
#    anything the OS can't identify is reported as Unknown, not guessed as SSD.
try {
    $Types = Get-PhysicalDisk | ForEach-Object {
        $media = [string]$_.MediaType
        $bus   = [string]$_.BusType
        if     ($bus -eq 'NVMe')                { 'NVMe' }
        elseif ($media -in 'SSD', 'HDD', 'SCM') { $media }
        else                                    { 'Unknown' }
    } | Sort-Object -Unique
    $DiskType = if ($Types) { $Types -join " + " } else { "Unknown" }
} catch {
    $DiskType = "Unknown"
}

# 2. Enumerate all fixed local disks (DriveType = 3)
$LogicalDisks   = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
$StorageSummary = @()

foreach ($d in $LogicalDisks) {
    $TotalGB = [math]::Round($d.Size / 1GB, 2)
    $FreeGB  = [math]::Round($d.FreeSpace / 1GB, 2)
    $StorageSummary += "$($d.DeviceID) $TotalGB GB (Free: $FreeGB GB)"
}

$AllStorageString = $StorageSummary -join " | "


# ------------------------------------------------------------------------- #
# Network Configuration
# ------------------------------------------------------------------------- #

$NetAdapter    = Get-CimInstance Win32_NetworkAdapterConfiguration |
                 Where-Object { $_.IPEnabled -eq $true -and $_.DefaultIPGateway -ne $null } |
                 Select-Object -First 1
$IPAddress     = $NetAdapter.IPAddress | Select-Object -First 1
$IPGateway     = $NetAdapter.DefaultIPGateway | Select-Object -First 1
$PrimDNSServer = $NetAdapter.DNSServerSearchOrder | Select-Object -First 1
$MAC           = $NetAdapter.MACAddress


# ------------------------------------------------------------------------- #
# Location Information (optional)
# ------------------------------------------------------------------------- #

$Latitude  = $null
$Longitude = $null

if ($UseGeolocation) {
    try {
        $LocKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
        if (!(Test-Path $LocKey)) { New-Item -Path $LocKey -Force | Out-Null }
        Set-ItemProperty -Path $LocKey -Name "Value" -Type String -Value "Allow" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" -Name "SensorPermissionState" -Type DWord -Value 1 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" -Name "Status" -Type DWord -Value 1 -ErrorAction SilentlyContinue

        Add-Type -AssemblyName System.Device -ErrorAction SilentlyContinue
        $GeoWatcher = New-Object System.Device.Location.GeoCoordinateWatcher
        $GeoWatcher.Start()

        $timeout = 0
        while (($GeoWatcher.Status -ne 'Ready') -and ($GeoWatcher.Permission -ne 'Denied') -and ($timeout -lt 20)) {
            Start-Sleep -Milliseconds 100
            $timeout++
        }

        if ($GeoWatcher.Permission -ne 'Denied' -and $GeoWatcher.Status -eq 'Ready') {
            $Latitude  = $GeoWatcher.Position.Location.Latitude
            $Longitude = $GeoWatcher.Position.Location.Longitude
        }
    } catch {
        # leave location empty
    }
}


# ------------------------------------------------------------------------- #
# Format and Write to File
# ------------------------------------------------------------------------- #

Add-Inv "inv.Name"          $SystemName
Add-Inv "inv.Type"          $DiskType
Add-Inv "inv.WinOS"         $WinOS
Add-Inv "inv.WinArch"       $Winarch
Add-Inv "inv.WinBuild"      $WinBuild
Add-Inv "inv.ModelNum"      $ModelNum
Add-Inv "inv.Manuf"         $Manuf
Add-Inv "inv.SerialNum"     $SerialNum
Add-Inv "inv.WinDomain"     $WinDomain
Add-Inv "inv.Owner"         $Owner
Add-Inv "inv.Loggedon"      $Loggedon
Add-Inv "inv.UsersCount"    $UserCount
Add-Inv "inv.UsersNames"    $UserList
Add-Inv "inv.IPAddress"     $IPAddress
Add-Inv "inv.IPGateway"     $IPGateway
Add-Inv "inv.PrimDNSServer" $PrimDNSServer
Add-Inv "inv.MAC"           $MAC
Add-Inv "inv.BIOSDate"      $BIOSDate
Add-Inv "inv.WinOSFull"     $WinOSFull
Add-Inv "inv.OSInstallDate" $OSInstallDate
Add-Inv "inv.LastBoot"      $LastBoot

if ($null -ne $Latitude -and $null -ne $Longitude) {
    Add-Inv "inv.Latitude"  $Latitude
    Add-Inv "inv.Longitude" $Longitude
}

Add-Inv "inv.Hardware"      "Total RAM: $TotalRAMGB GB ($RAMSpeed MHz) | Free: $FreeRAMGB GB"
Add-Inv "inv.HardwareFull"  "CPU: $CPUName ($CPUCores) | Mobo: $MoboModel"
Add-Inv "inv.GPU"     "GPU: $GPUName"
Add-Inv "inv.Storage"     $AllStorageString

# ASCII without BOM (a BOM would corrupt the first key for zabbix_sender)
Set-Content -Path $TempOutputFile -Value $Lines -Encoding ASCII


# ------------------------------------------------------------------------- #
# Send Data to Zabbix
# ------------------------------------------------------------------------- #

& $Sender -vv -c $ConfigFile -i $TempOutputFile 2>&1
exit $LASTEXITCODE


# ------------------------------------------------------------------------- #
# Trapper items needed on the host (type: Zabbix trapper, information: Text)
# ------------------------------------------------------------------------- #
# inv.Name            -> Name                      inv.IPAddress      -> Host networks
# inv.Type            -> Type                      inv.IPGateway      -> Host router
# inv.WinOS           -> OS                        inv.PrimDNSServer  -> Software application C
# inv.WinBuild        -> OS (short)                inv.MAC            -> MAC address A
# inv.WinOSFull       -> OS (full details)         inv.BIOSDate       -> Software application D
# inv.WinArch         -> HW architecture           inv.OSInstallDate  -> Date HW installed
# inv.ModelNum        -> Model                     inv.LastBoot       -> Software application E
# inv.Manuf           -> Vendor                    inv.Hardware       -> Hardware
# inv.SerialNum       -> Serial number A           inv.HardwareFull   -> Hardware (full details)
# inv.WinDomain       -> Location                  inv.SoftwareA      -> Software application A
# inv.Owner           -> Contact                   inv.SoftwareB      -> Software application B
# inv.Loggedon        -> Alias                     inv.Latitude/Longitude -> Location latitude/longitude
# inv.UsersCount      -> (no inventory field; numeric item for graphs/triggers)
# inv.UsersNames      -> POC 1 name

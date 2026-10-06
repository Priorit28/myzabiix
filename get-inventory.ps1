# Powershell script for Zabbix agents (Updated for Zabbix Agent 2)
# Version 2.3 - Multi-Drive Storage & Type Detection

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

$Sender = "$ZabbixInstallPath\zabbix_sender.exe"
$Senderarg1 = '-vv'
$Senderarg2 = '-c'
$Senderarg3 = $ConfigFile
$Senderarg4 = '-i'
$TempOutputFile = Join-Path $env:TEMP "wininvstatus.txt"


# ------------------------------------------------------------------------- #
# Gather Full System Information
# ------------------------------------------------------------------------- #

# Operating System
$OSInfo        = Get-CimInstance Win32_OperatingSystem
$WinOS         = $OSInfo.Caption
$Winarch       = $OSInfo.OSArchitecture
$WinBuild      = $OSInfo.BuildNumber
$OSInstallDate = $OSInfo.InstallDate.ToString("d")

# System & Computer
$CSInfo        = Get-CimInstance Win32_ComputerSystem
$SystemName    = $CSInfo.Name
$ModelNum      = $CSInfo.Model
$Manuf         = $CSInfo.Manufacturer
$WinDomain     = $CSInfo.Domain
$Owner         = $CSInfo.PrimaryOwnerName
$Loggedon      = $CSInfo.UserName

# BIOS & Motherboard
$BIOS          = Get-CimInstance Win32_BIOS
$SerialNum     = $BIOS.SerialNumber
$BIOSDate      = $BIOS.ReleaseDate.ToString("d")
$Board         = Get-CimInstance Win32_BaseBoard
$MoboModel     = "$($Board.Manufacturer) $($Board.Product)"

# Processor (CPU)
$CPU           = Get-CimInstance Win32_Processor | Select-Object -First 1
$CPUName       = $CPU.Name.Trim()
$CPUCores      = "$($CPU.NumberOfCores) Cores / $($CPU.NumberOfLogicalProcessors) Threads"

# Memory (RAM)
$TotalRAMGB    = [math]::round($CSInfo.TotalPhysicalMemory / 1GB, 2)
$FreeRAMGB     = [math]::round($OSInfo.FreePhysicalMemory / 1MB, 2)
$RAMSpeed      = (Get-CimInstance Win32_PhysicalMemory | Select-Object -ExpandProperty ConfiguredClockSpeed -First 1)

# Graphics (GPU)
$GPU           = Get-CimInstance Win32_VideoController | Select-Object -First 1
$GPUName       = $GPU.Name


# ------------------------------------------------------------------------- #
# Multi-Drive Storage & Media Type Detection
# ------------------------------------------------------------------------- #

# 1. Detect Media Types (SSD, HDD, NVMe, Hybrid)
try {
    $PhysDisks = Get-PhysicalDisk
    $Types = @()
    foreach ($disk in $PhysDisks) {
        $media = $disk.MediaType
        if ($media -eq "Unspecified" -or [string]::IsNullOrWhiteSpace($media)) {
            $media = "SSD/NVMe"
        }
        if ($Types -notcontains $media) { $Types += $media }
    }
    $DiskType = $Types -join " + "
} catch {
    $DiskType = "Unknown"
}

# 2. Enumerate All Fixed Local Hard Disks (DriveType = 3)
$LogicalDisks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
$StorageSummary = @()

foreach ($d in $LogicalDisks) {
    $TotalGB = [math]::round($d.Size / 1GB, 2)
    $FreeGB  = [math]::round($d.FreeSpace / 1GB, 2)
    $StorageSummary += "$($d.DeviceID) $TotalGB GB (Free: $FreeGB GB)"
}

$AllStorageString = $StorageSummary -join " | "


# ------------------------------------------------------------------------- #
# Network Configuration
# ------------------------------------------------------------------------- #

$NetAdapter    = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.DefaultIPGateway -ne $null } | Select-Object -First 1
$IPAddress     = $NetAdapter.IPAddress | Select-Object -First 1
$IPGateway     = $NetAdapter.DefaultIPGateway | Select-Object -First 1
$PrimDNSServer = $NetAdapter.DNSServerSearchOrder | Select-Object -First 1


# ------------------------------------------------------------------------- #
# Location Information
# ------------------------------------------------------------------------- #

try {
    if (!(Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location")) {
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Type String -Value "Allow" -ErrorAction SilentlyContinue
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

    if ($GeoWatcher.Permission -eq 'Denied' -or $GeoWatcher.Status -ne 'Ready') {
        $Latitude = '0'
        $Longitude = '0'
    } else {
        $Latitude = $GeoWatcher.Position.Location.Latitude
        $Longitude = $GeoWatcher.Position.Location.Longitude
    }
} catch {
    $Latitude = '0'
    $Longitude = '0'
}

$outputGeoLocation = "- inv.Geolocation ""$Latitude $Longitude"""


# ------------------------------------------------------------------------- #
# Format and Write to File
# ------------------------------------------------------------------------- #

$outputSystemName     = "- inv.Name ""$SystemName"""
$outputType           = "- inv.Type ""$DiskType"""
$outputWinOS          = "- inv.WinOS ""$WinOS"""
$outputModelNum       = "- inv.ModelNum ""$ModelNum"""
$outputManuf          = "- inv.Manuf ""$Manuf"""
$outputWinDomain      = "- inv.WinDomain ""$WinDomain"""
$outputOwner          = "- inv.Owner ""$Owner"""
$outputLoggedon       = "- inv.Loggedon ""$Loggedon"""
$outputOSInstallDate  = "- inv.OSInstallDate ""$OSInstallDate"""
$outputBIOSDate       = "- inv.BIOSDate ""$BIOSDate"""

$outputRAM            = "- inv.Hardware ""Total RAM: $TotalRAMGB GB ($RAMSpeed MHz) | Free: $FreeRAMGB GB"""
$outputHardwareFull   = "- inv.HardwareFull ""CPU: $CPUName ($CPUCores) | Mobo: $MoboModel"""
$outputGPU            = "- inv.SoftwareA ""GPU: $GPUName"""
$outputStorage        = "- inv.SoftwareB ""$AllStorageString"""

Write-Output "- inv.WinArch $Winarch" | Out-File -Encoding "ASCII" -FilePath $TempOutputFile
Add-Content $TempOutputFile $outputSystemName
Add-Content $TempOutputFile $outputType
Add-Content $TempOutputFile $outputWinOS
Add-Content $TempOutputFile "- inv.WinBuild $WinBuild"
Add-Content $TempOutputFile $outputModelNum
Add-Content $TempOutputFile $outputManuf
Add-Content $TempOutputFile "- inv.SerialNum $SerialNum"
Add-Content $TempOutputFile $outputWinDomain
Add-Content $TempOutputFile $outputOwner
Add-Content $TempOutputFile $outputLoggedon
Add-Content $TempOutputFile "- inv.IPAddress $IPAddress"
Add-Content $TempOutputFile "- inv.IPGateway $IPGateway"
Add-Content $TempOutputFile "- inv.PrimDNSServer $PrimDNSServer"
Add-Content $TempOutputFile $outputBIOSDate
Add-Content $TempOutputFile $outputOSInstallDate
Add-Content $TempOutputFile $outputGeoLocation

# Append System Information Items
Add-Content $TempOutputFile $outputRAM
Add-Content $TempOutputFile $outputHardwareFull
Add-Content $TempOutputFile $outputGPU
Add-Content $TempOutputFile $outputStorage


# ------------------------------------------------------------------------- #
# Send Data to Zabbix
# ------------------------------------------------------------------------- #

& $Sender $Senderarg1 $Senderarg2 $Senderarg3 $Senderarg4 $TempOutputFile

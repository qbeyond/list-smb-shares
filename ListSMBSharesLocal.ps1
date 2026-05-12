# List SMB Shares with Active Directory V 1.1.0
#
# Command to start the programm: .\ListSMBSharesLocal.ps1 -OutDir ".\ShareInventory" -IncludeAdminShares -WithLocal -WithNfsShares
# 
# Requirements:
# - Server who runs the script needs the following:
#   - AD DS and AD LDS Tools installed on Machine for running the Script
#   - Login with a Domain Admin
#   - Machine is joined the AD
#
# - Server who recieve the Script:
#   - Machine is joined the AD
#
# Parameters (Input):
# - IncludeAdminShares (optional): If its set to true, the programm will include the default admin shares into the summary
# - NoDetails (optional): If set to true, the programm will only create a summary, no detailed files of NTFS and Shares
# - WithLocal (optional): If set to true, the programm will also run the script on the local machine and include it in the summary
# - WithNfsShares (optional): If set to true, the programm will also include NFS Shares in the summary
#
# Input txt file: (If Path field is empty, he will use Active Directory to find server)
# The file consist of the hostnames of the server.
# Example:
# vm-testShare2
# vm-testShareAD
# vm-testShare3
#
# Output:
# The programm will create three CSV files in the selected folder. If the flag "NoDetails" is set to true, the programm will only create one summary file.
# The Structure looks as following:
#
# ShareSummary.csv: Summarize per Share
# ServerName, FQDNS, IP Address, OS, OS Version, ShareName, Description, Path, SharePermission (if it is SMB Share), NFS Permission (if it is NFS Share), NTFS Share Permission, PSComputerName, RunspaceId, PSShowComputerName
# Share Permission are summarized in an string with the following structure:
# "AccountName:AccessRight:AccessControlType | AccountName:AccessRight:AccessControlType"
# NFS Share Permission are summarized in an String with the following structure:
# "ClientName:Permission:AllowRootAccess | ClientName:Permission:AllowRootAccess"
# NTFS Share Permission are summarized in an String with the following structure:
# "IdentityReference:FileSystemRights:AccessControlType:IsInherited | IdentityReference:FileSystemRights:AccessControlType:IsInherited"
# 
# ShareACE.csv: Summarize per Account/ClientName
# ServerName, ShareName, Path, Account, Right, Type, PSComputerName, RunspaceId, PSShowComputerName
#
# NtfsACE.csv: Summarize per Account/ClientName
# ServerName, ShareName, Path, Identity, FileSystemRights, AccessControlType, IsInherited, InheritanceFlags, PropagationFlags, PSComputerName, RunspaceId, PSShowComputerName
#

[CmdletBinding()]
param(
    [string]$OutDir = ".\ShareInventory",   # Dirctory for the CSV Files

    [switch]$IncludeAdminShares,    # Include normal Admin Shares in the Analysis

    [switch]$NoDetails,  # Give only the summary, no detailed files

    [switch]$WithLocal,  # Also includes the local machine in the summary

    [switch]$WithNfsShares  # Includes also the NFS Shares into the summary
)

Import-Module NFS

# Set up export files
$null = New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction SilentlyContinue
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

$summaryCsv = Join-Path $OutDir "ShareSummary_$stamp.csv"
$shareAceCsv = Join-Path $OutDir "ShareACE_$stamp.csv"
$ntfsAceCsv  = Join-Path $OutDir "NtfsACE_$stamp.csv"

# --- Remote ScriptBlock: Summary collection ---
$sbSummary = {
    param(
        [bool]$IncludeAdminShares,
        [bool]$WithNfsShares
    )

    function Join-NonEmpty {
        param([object[]]$Items, [string]$Sep = ' | ')
        $clean = $Items | Where-Object { $_ -ne $null -and "$_" -ne '' }
        if ($clean) { ($clean -join $Sep) } else { $null }
    }

    $computerName = $env:COMPUTERNAME
    $fqdn = try { ([System.Net.Dns]::GetHostByName($computerName)).HostName } catch { $null }

    # OS Info
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osCaption = $os.Caption
    $osVersion = $os.Version
    $osBuild   = $os.BuildNumber

    # IPs (IPv4, without Link-Local)
    $ips = Get-NetIPAddress -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceAlias -eq "Ethernet" -and
            $_.IPAddress -notlike 'fe80::*'
        } |
        Select-Object -ExpandProperty IPAddress
    $ipJoined = $ips -join ';'

    # Shares
    $shares = @(Get-SmbShare -ErrorAction SilentlyContinue)
    if (-not $IncludeAdminShares) {
        $shares = $shares | Where-Object { $_.Name -notlike '*$' }
    }

    foreach ($sh in $shares) {
        # Share ACEs -> as String
        $shareAces = @()
        try {
            $shareAces = Get-SmbShareAccess -Name $sh.Name -ErrorAction Stop |
                ForEach-Object {
                    "{0}:{1}:{2}" -f $_.AccountName, $_.AccessRight, $_.AccessControlType
                }
        } catch {
            $shareAces = @("ERROR: $($_.Exception.Message)")
        }
        $sharePermStr = Join-NonEmpty -Items $shareAces

        # NTFS ACEs -> as String
        $ntfsPermStr = $null
        if ($sh.Path -and (Test-Path $sh.Path)) {
            try {
                $acl = Get-Acl -Path $sh.Path -ErrorAction Stop
                $ntfsAces = $acl.Access | ForEach-Object {
                    "{0}:{1}:{2}{3}" -f $_.IdentityReference,
                        $_.FileSystemRights,
                        $_.AccessControlType,
                        ($(if ($_.IsInherited) { ':Inherited' } else { '' }))
                }
                $ntfsPermStr = Join-NonEmpty -Items $ntfsAces
            } catch {
                $ntfsPermStr = "ERROR: $($_.Exception.Message)"
            }
        } else {
            $ntfsPermStr = "Path not accessible"
        }
        # Save summarized information
        [pscustomobject]@{
            ServerName       = $computerName
            FQDN             = $fqdn
            IPAddresses      = $ipJoined
            OS               = $osCaption
            OSVersion        = $osVersion
            OSBuild          = $osBuild
            ShareName        = $sh.Name
            Description      = $sh.Description
            Path             = $sh.Path
            SharePermissions = $sharePermStr
            NFSPermissions   = $null
            NTFSPermissions  = $ntfsPermStr
        }
    }

    if($WithNfsShares){

        $nfsShares = @(Get-NfsShare -ErrorAction SilentlyContinue)

        foreach($nfs in $nfsShares){

            # NFS ACEs -> as String
            $nfsAces = @()
            try {
                $nfsAces = Get-NfsSharePermission -Name $nfs.Name -ErrorAction Stop |
                ForEach-Object{
                    "{0}:{1}:{2}" -f $_.ClientName, $_.Permission, $_.AllowRootAccess
                } 
            }
            catch {
                $nfsAces = @("ERROR: $($_.Exception.Message)")
            }

            $nfsSharePermStr = Join-NonEmpty -Items $nfsAces

            # NTFS ACEs -> as String
            $ntfsPermStr = $null
            if ($nfs.Path -and (Test-Path $nfs.Path)) {
                try {
                    $aclNfs = Get-Acl -Path $nfs.Path -ErrorAction Stop
                    $ntfsAcesNfs = $aclNfs.Access | ForEach-Object {
                        "{0}:{1}:{2}{3}" -f $_.IdentityReference,
                            $_.FileSystemRights,
                            $_.AccessControlType,
                            ($(if ($_.IsInherited) { ':Inherited' } else { '' }))
                    }
                    $ntfsPermStrNfs = Join-NonEmpty -Items $ntfsAcesNfs
                } catch {
                    $ntfsPermStrNfs = "ERROR: $($_.Exception.Message)"
                }
            } else {
                $ntfsPermStrNfs = "Path not accessible"
            }

            [pscustomobject]@{
                ServerName       = $computerName
                FQDN             = $fqdn
                IPAddresses      = $ipJoined
                OS               = $osCaption
                OSVersion        = $osVersion
                OSBuild          = $osBuild
                ShareName        = $nfs.Name
                Description      = $nfs.Description
                Path             = $nfs.Path
                SharePermissions = $null
                NFSPermissions   = $nfsSharePermStr
                NTFSPermissions  = $ntfsPermStrNfs
            }
        }
    }
}

$summary = @()

# Running Command Block on local machine
$localResult = & $sbSummary $IncludeAdminShares.IsPresent $WithNfsShares.IsPresent
$summary += $localResult


# --- Export Summary ---
$summary | Sort-Object ServerName, ShareName |
    Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8
Write-Host "Summary CSV: $summaryCsv" -ForegroundColor Green

if(-not $NoDetails){
    # --- Optional: Detailed ACEs ---
    $sbDetail = {
        param(
            [bool]$IncludeAdminShares,
            [bool]$WithNfsShares
        )

        $computerName = $env:COMPUTERNAME

        $shares = @(Get-SmbShare -ErrorAction SilentlyContinue)
        if (-not $IncludeAdminShares) {
            $shares = $shares | Where-Object { $_.Name -notlike '*$' }
        }

        foreach ($sh in $shares) {
            # Share ACEs: one line per ACE
            try {
                Get-SmbShareAccess -Name $sh.Name -ErrorAction Stop |
                    Select-Object @{n='ServerName';e={$computerName}},
                                    @{n='ShareName';e={$sh.Name}},
                                    @{n='Path';e={$sh.Path}},
                                    @{n='Account';e={$_.AccountName}},
                                    @{n='Right';e={$_.AccessRight}},
                                    @{n='Type';e={$_.AccessControlType}}
            } catch {
                [pscustomobject]@{
                    ServerName = $computerName
                    ShareName  = $sh.Name
                    Path       = $sh.Path
                    Account    = $null
                    Right      = $null
                    Type       = "ERROR: $($_.Exception.Message)"
                }
            }

            # NTFS ACEs: one line per ACE
            if ($sh.Path -and (Test-Path $sh.Path)) {
                try {
                    (Get-Acl -Path $sh.Path -ErrorAction Stop).Access |
                        Select-Object @{n='ServerName';e={$computerName}},
                                        @{n='ShareName';e={$sh.Name}},
                                        @{n='Path';e={$sh.Path}},
                                        @{n='Identity';e={$_.IdentityReference}},
                                        @{n='FileSystemRights';e={$_.FileSystemRights}},
                                        @{n='AccessControlType';e={$_.AccessControlType}},
                                        @{n='IsInherited';e={$_.IsInherited}},
                                        @{n='InheritanceFlags';e={$_.InheritanceFlags}},
                                        @{n='PropagationFlags';e={$_.PropagationFlags}}
                } catch {
                    [pscustomobject]@{
                        ServerName       = $computerName
                        ShareName        = $sh.Name
                        Path             = $sh.Path
                        Identity         = $null
                        FileSystemRights = $null
                        AccessControlType= "ERROR"
                        IsInherited      = $null
                        InheritanceFlags = $null
                        PropagationFlags = $null
                    }
                }
            } else {
                [pscustomobject]@{
                    ServerName       = $computerName
                    ShareName        = $sh.Name
                    Path             = $sh.Path
                    Identity         = $null
                    FileSystemRights = $null
                    AccessControlType= "Path not accessible"
                    IsInherited      = $null
                    InheritanceFlags = $null
                    PropagationFlags = $null
                }
            }
        }

        if($WithNfsShares){

            $nfsShares = @(Get-NfsShare -ErrorAction SilentlyContinue)

            # NFS ACEs -> as String
            foreach($nfs in $nfsShares){
                
                try {
                    Get-NfsSharePermission -Name $nfs.Name -ErrorAction Stop |
                        Select-Object @{n='ServerName';e={$computerName}},
                                        @{n='ShareName';e={$nfs.Name}},
                                        @{n='Path';e={$nfs.Path}},
                                        @{n='Account';e={$_.ClientName}},
                                        @{n='Right';e={$_.Permission}},
                                        @{n='Type';e={$_.ClientType}}
                } catch {
                    [pscustomobject]@{
                        ServerName = $computerName
                        ShareName  = $nfs.Name
                        Path       = $nfs.Path
                        Account    = $null
                        Right      = $null
                        Type       = "ERROR: $($_.Exception.Message)"
                    }
                }

                # NTFS ACEs: one line per ACE
                if ($nfs.Path -and (Test-Path $nfs.Path)) {
                    try {
                        (Get-Acl -Path $nfs.Path -ErrorAction Stop).Access |
                            Select-Object @{n='ServerName';e={$computerName}},
                                            @{n='ShareName';e={$nfs.Name}},
                                            @{n='Path';e={$nfs.Path}},
                                            @{n='Identity';e={$_.IdentityReference}},
                                            @{n='FileSystemRights';e={$_.FileSystemRights}},
                                            @{n='AccessControlType';e={$_.AccessControlType}},
                                            @{n='IsInherited';e={$_.IsInherited}},
                                            @{n='InheritanceFlags';e={$_.InheritanceFlags}},
                                            @{n='PropagationFlags';e={$_.PropagationFlags}}
                    } catch {
                        [pscustomobject]@{
                            ServerName       = $computerName
                            ShareName        = $nfs.Name
                            Path             = $nfs.Path
                            Identity         = $null
                            FileSystemRights = $null
                            AccessControlType= "ERROR"
                            IsInherited      = $null
                            InheritanceFlags = $null
                            PropagationFlags = $null
                        }
                    }
                } else {
                    [pscustomobject]@{
                        ServerName       = $computerName
                        ShareName        = $nfs.Name
                        Path             = $nfs.Path
                        Identity         = $null
                        FileSystemRights = $null
                        AccessControlType= "Path not accessible"
                        IsInherited      = $null
                        InheritanceFlags = $null
                        PropagationFlags = $null
                    }
                }
            }
        }
    }

    $detail = @()

    # Running Command Block on local machine
    $localDetail = & $sbDetail $IncludeAdminShares.IsPresent $WithNfsShares.IsPresent
    $detail += $localDetail

    # Split by shape (Share ACE vs NTFS ACE)
    $shareAce = $detail | Where-Object { $_.PSObject.Properties.Name -contains 'Account' }
    $ntfsAce  = $detail | Where-Object { $_.PSObject.Properties.Name -contains 'Identity' }

    # Export details into CSV files
    $shareAce | Sort-Object ServerName, ShareName, Account |
        Export-Csv -Path $shareAceCsv -NoTypeInformation -Encoding UTF8
    $ntfsAce  | Sort-Object ServerName, ShareName, Identity |
        Export-Csv -Path $ntfsAceCsv -NoTypeInformation -Encoding UTF8

    Write-Host "Share ACE CSV: $shareAceCsv" -ForegroundColor Green
    Write-Host "NTFS  ACE CSV: $ntfsAceCsv"  -ForegroundColor Green
}

# --- Cleanup ---
Write-Host "Finished." -ForegroundColor Cyan
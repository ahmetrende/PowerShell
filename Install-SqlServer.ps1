<#PSScriptInfo

.SYNOPSIS
    Install-SqlServer: SQL Server Unattended Installation
    
.DESCRIPTION
    This script provides installing a SQL engine service, cumulative update and management studio to a local or remote server.
    You may need to tweak the script for your environment.

    Requirements:
    - PowerShell 5.1 or above
    - dbatools module (https://dbatools.io)
    - CredSSP authentication
    - Standard folder structure*
    - Active directory environment

    *The folder structure should be like this:
    <YourSetupFolderPath>
        -VersionNumber
            -Iso files
            -Cumulative update setup files
        -Tools
            -SSMS setup files.
    
    My folder structure for SQL Server 2019
        C:\Setup\2019\SqlServer2019.ISO
        C:\Setup\2019\SQLServer2019-KB4548597-x64.exe
        C:\Setup\Tools\SSMS-Setup-ENU.exe

.EXAMPLE
    #With this example, you can install a SQL engine, cumulative update and management studio on "SqlServer01".

    $CredEngine = Get-Credential
    $CredSa     = Get-Credential 'sa'
    $Params     = @{
        DestinationServer = "SqlServer01"
        SetupFilesPath = "C:\Setup"
        Version = 2019
        InstallEngine = $true
        InstallCU = $true
        InstallSSMS = $true
        SqlCollation = "Latin1_General_CI_AS"
        InstancePath = "C:\Program Files\Microsoft SQL Server"
        DataPath = "D:\Data"
        LogPath = "L:\Log"
        TempPath = "T:\TempDB"
        BackupPath = "B:\Backup"
        EngineCredential = $CredEngine
        AgentCredential = $CredEngine
        SaCredential = $CredSa
        Credential = $CredEngine
        AdminAccount = "$($env:userdomain)\DBAdmin"
        Restart = $true
        WhatIf = $false
        VerboseCommand = $false
        EnableException = $true
    }
    Install-SqlServer @Params 
    
.NOTES
    Version     : 1.0 (2020-05-31)
    File Name   : Install-SqlServer.ps1
    Author      : Ahmet Rende (ahmet@ahmetrende.com) 
    GitHub      : https://github.com/ahmetrende

#>

function Install-SqlServer {
    [CmdletBinding()]
    param (
         [string]$DestinationServer = $env:COMPUTERNAME
        ,[string]$SetupFilesPath = "C:\Setup"
        ,[int]$Version = 2019
        ,[switch]$InstallEngine
        ,[switch]$InstallCU
        ,[switch]$InstallSSMS
        ,[string]$SqlCollation = "Latin1_General_CI_AS" #"Turkish_CI_AS"
        ,[string]$InstancePath = "C:\Program Files\Microsoft SQL Server"
        ,[string]$DataPath = "C:\Data"
        ,[string]$LogPath = "C:\Log"
        ,[string]$TempPath = "C:\TempDB"
        ,[string]$BackupPath = "C:\Backup"
        ,[Parameter(Mandatory=$true)][pscredential]$EngineCredential
        ,[pscredential]$AgentCredential
        ,[Parameter(Mandatory=$true)][pscredential]$SaCredential
        ,[pscredential]$Credential
        ,[string]$AdminAccount = "$($env:userdomain)\$($env:USERNAME)"
        ,[switch]$Restart
        ,[switch]$WhatIf
        ,[switch]$VerboseCommand
        ,[switch]$EnableException
    )

    $ErrorActionPreference = 'Stop'
    Write-Host "### SQL Server Unattended Installation for [$DestinationServer] ###" -ForegroundColor Yellow

    if(!$InstallEngine -and !$InstallCU -and !$InstallSSMS) {
        Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] No action.'") -ForegroundColor Gray
    }
    else {
    
        #region Internal Params
        if(!$EngineCredential) { $EngineCredential = Get-Credential }
        if(!$AgentCredential) { $AgentCredential = $EngineCredential }
        if(!$Credential) { $Credential = $EngineCredential }

        $RemoteSetupFilesPath = "$($InstancePath.SubString(0,1)):\SqlServerSetup"
        $RemoteSetupFilesPathUnc = "\\$DestinationServer\$RemoteSetupFilesPath" -replace ':', '$'
        #endregion Internal Params
    
        #region CredSSP
        Enable-WSManCredSSP -DelegateComputer '*' -Force -Role Client > $null
        Enable-WSManCredSSP -Force -Role Server > $null
    
        Invoke-Command -ComputerName $DestinationServer -Credential $Credential -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            Enable-WSManCredSSP -DelegateComputer '*' -Force -Role Client > $null
            Enable-WSManCredSSP -Force -Role Server > $null
        }
        Test-WSMan -ComputerName $DestinationServer -Credential $Credential -Authentication Credssp > $null
        #endregion CredSSP
    
        #region dbatools
        if (Get-Module -ListAvailable -Name dbatools) {
            Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] dbatools module exists. Skipping this command.'") -ForegroundColor Gray
            Import-Module dbatools
        }
        else {
            Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] dbatools module does not exist. Downloading... '") -NoNewline
            Install-PackageProvider -Name NuGet -Force -Confirm:$false > $null 
            Install-module dbatools -Force -Confirm:$false
            Import-Module dbatools
            Write-Host "OK" -ForegroundColor Green
        }
        #endregion dbatools
   
    }

    #region InstallEngine
    if ($InstallEngine) {
        $IsoFileName = Get-ChildItem -Path "$SetupFilesPath\$Version" -Filter "*$Version*.ISO" | 
            Sort-Object @{Expression = {$_.VersionInfo.ProductBuildPart}; Descending = $true} | Select-Object -First 1 -ExpandProperty Name
    
        Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] Mounting ISO file... '") -NoNewline
        $mountResult = Mount-DiskImage -ImagePath "$SetupFilesPath\$Version\$IsoFileName" -PassThru 
        $volumeInfo = $mountResult | Get-Volume
        $driveInfo = Get-PSDrive -Name $volumeInfo.DriveLetter
        Write-Host "OK" -ForegroundColor Green
        
            Start-Sleep -Seconds 1

        Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] Extracting ISO files to remote folder... '") -NoNewline
        Remove-Item -Path ("$RemoteSetupFilesPathUnc\$IsoFileName").Replace(".ISO", "\") -Force -ErrorAction SilentlyContinue -Recurse -Confirm:$false 
        Copy-Item -Path $driveInfo.Root -Destination ("$RemoteSetupFilesPathUnc\$IsoFileName").Replace(".ISO", "\") -Recurse
        Dismount-DiskImage -ImagePath "$SetupFilesPath\$Version\$IsoFileName"
        Write-Host "OK" -ForegroundColor Green
       
        #Custom Config
        $config = @{
            AGTSVCSTARTUPTYPE = "Automatic"
            SQLCOLLATION = $SqlCollation
            SQLTEMPDBFILESIZE = 1024
            SQLTEMPDBFILEGROWTH = 512
            SQLTEMPDBLOGFILESIZE = 1024
            SQLTEMPDBLOGFILEGROWTH = 256
            #SQLMAXDOP = 1
        }
    
        $InstallParams = @{
            SqlInstance = $DestinationServer
            Version = $Version
            Feature = "Engine"
            SaCredential = $SaCredential
            Path = ("$RemoteSetupFilesPath\$IsoFileName").Replace(".ISO", "\") 
            DataPath = $DataPath 
            LogPath = $LogPath 
            TempPath = $TempPath 
            BackupPath = $BackupPath
            AdminAccount = $AdminAccount 
            AuthenticationMode = "Mixed" 
            EngineCredential = $EngineCredential 
            AgentCredential = $AgentCredential 
            Credential = $Credential 
            PerformVolumeMaintenanceTasks = $true
            Restart = $Restart 
            Verbose = $VerboseCommand 
            WhatIf = $WhatIf 
            InstancePath = $InstancePath 
            Configuration = $config 
            Confirm = $false 
            EnableException = $EnableException
        }
    
        #Install Engine
        Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] Installing engine... '") 
        Install-DbaInstance @InstallParams
    
    }
    #endregion InstallEngine
    
    #region InstallCU
    if ($InstallCU) {
        
        $CuFilePath = "\\$env:COMPUTERNAME\" + (Get-ChildItem -Path $SetupFilesPath\$Version -Filter "SQLServer$Version*" | 
                Sort-Object @{Expression = {$_.VersionInfo.ProductBuildPart}; Descending = $true} | Select-Object -First 1 -ExpandProperty FullName).Replace(':', '$')
        #Install CU
        $UpdateParams = @{
            ComputerName = $DestinationServer
            Path = $CuFilePath
            Credential = $Credential 
            ExtractPath = $RemoteSetupFilesPath
            Restart = $Restart 
            Verbose = $VerboseCommand 
            WhatIf = $WhatIf 
            Confirm = $false 
            EnableException = $EnableException
        }
    
        Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] Installing CU... '")
        Update-DbaInstance @UpdateParams 

    }
    #endregion InstallCU
    
    #region InstallSSMS
    if ($InstallSSMS) {
        #Copy SSMS exe
        Copy-Item -Path "$SetupFilesPath\Tools\SSMS-Setup-ENU.exe" -Destination $RemoteSetupFilesPathUnc -Force
    
        Write-Host (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff '[$DestinationServer] Installing SSMS... '") -NoNewline
        $ArgList = "/install /quiet /norestart /log $RemoteSetupFilesPath\Log\ssms.log"
    
        Invoke-Command -ComputerName $DestinationServer -Authentication Credssp -Credential $Credential -ScriptBlock {
            Param($RemoteSetupFilesPath, $ArgList)
                if(!(Test-Path -Path "$RemoteSetupFilesPath\Log\" )){New-Item -ItemType Directory -Path "$RemoteSetupFilesPath\Log" -ErrorAction SilentlyContinue > $null}
                Start-Process "$RemoteSetupFilesPath\SSMS-Setup-ENU.exe" $ArgList -Wait 
        } -ArgumentList $RemoteSetupFilesPath, $ArgList -Verbose:$VerboseCommand
    
        if (Get-Content -Path "$RemoteSetupFilesPathUnc\Log\ssms.log" -Tail 1 | Select-String "Exit code: 0x0, restarting" -Quiet) {
            Write-Host "OK" -ForegroundColor Green
        }
        else {
            Write-Host "Failed" -ForegroundColor Red
        }
    }
    #endregion InstallSSMS

    Write-Host "### SQL Server Unattended Installation for [$DestinationServer] ###" -ForegroundColor Green

}

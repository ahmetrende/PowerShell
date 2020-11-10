<#PSScriptInfo
.SYNOPSIS
    Move Couchbase data to SQL Server.
    
.DESCRIPTION
    This function move your Couchbase data to SQL Server.

    Requirements:
    - PowerShell 5.1 or above
    - dbatools module (https://dbatools.io)
    - SQL Server 2016 (13.x) or above (for the older version, you should remove the COMPRESSION function)
    - Couchbase N1QL Service with api support
    
.EXAMPLE
    $Params = @{
        CbQueryNode = "<Server Address>";
        CbCredential = (Get-Credential -Message "Credential for Couchbase");
        CbBucketName = "<Bucket Name>"
        CbQuery = "<N1QL Query>";
        SqlInstance = "<Sql Instance Address>";
        SqlDatabase = "<Sql Database Name>";
        SqlTable = "<Sql Table Name>";
        SqlCredential = (Get-Credential -Message "Credential for SQL Server");
        Initialize = <$true or $false>;
    }
    Invoke-CouchbaseArchiver @Params 
    
.NOTES
    Version     : 1.0 (2020-11-10)
    File Name   : Invoke-CouchbaseArchiver.ps1
    Author      : Ahmet Rende (ahmet@ahmetrende.com) 
    GitHub      : https://github.com/ahmetrende
#>

function Invoke-CouchbaseArchiver {
    [CmdletBinding()]
    param (
         [Parameter(Mandatory=$true)][string]$CbQueryNode
        ,[PSCredential]$CbCredential
        ,[Parameter(Mandatory=$true)][string]$CbBucketName
        ,[Parameter(Mandatory=$true)][string]$CbQuery
        ,[int]$CbQueryPort = 8093
        ,[int]$CbRetryCount = 3 
        ,[int]$CbRetryDelayMs = 500
        ,[int]$CbDepthForJson = 20

        ,[Parameter(Mandatory=$true)][string]$SqlInstance
        ,[Parameter(Mandatory=$true)][string]$SqlDatabase
        ,[string]$SqlSchema = "dbo"
        ,[Parameter(Mandatory=$true)][string]$SqlTable
        ,[PSCredential]$SqlCredential
        ,[switch]$Initialize
    )

    begin {
        $ErrorActionPreference = 'stop'
        Import-Module dbatools -Force

        #region Check SQL table
        try {
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master `
                -Query "SELECT TOP (0) id, JsonDocument, ArchiveInsertDate, DeleteStatus FROM [$SqlDatabase].[$SqlSchema].[$SqlTable]" -EnableException -As SingleValue
        }
        catch {
            if ($_.Exception.InnerException.Number -eq 208 -and $_.Exception.InnerException.Class -eq 16 -and !$Initialize) {
                $WarningMessage = "The archive table [$SqlDatabase].[$SqlSchema].[$SqlTable] cannot found. Please use -Initialize parameter. This parameter will create objects on the server [$SqlInstance]`nException: $($_.Exception.Message)"
                Write-Warning $WarningMessage
                exit;
            }
            elseif ($_.Exception.InnerException.Number -eq 208 -and $_.Exception.InnerException.Class -eq 16 -and $Initialize) {
                $CreateSqlObjectsQuery = "CREATE TABLE [$SqlSchema].[$SqlTable]
                                          (
	                                           id NVARCHAR(128) PRIMARY KEY CLUSTERED
	                                          ,JsonDocument VARBINARY(MAX) NOT NULL
	                                          ,ArchiveInsertDate DATETIME2 NOT NULL DEFAULT (SYSDATETIME())
	                                          ,DeleteStatus BIT NOT NULL DEFAULT (0)
                                              ,INDEX IX_DeleteStatus (DeleteStatus)
                                          )
                                          GO
                                          
                                          CREATE TYPE [$SqlSchema].[type_$CbBucketName] AS TABLE
                                          (
	                                          id NVARCHAR(128) NOT NULL PRIMARY KEY CLUSTERED,
	                                          JsonDocument NVARCHAR(MAX) NOT NULL
                                          )
                                          GO
                                          
                                          CREATE PROC [$SqlSchema].[Insert_$CbBucketName] @table [$SqlSchema].[type_$CbBucketName] READONLY
                                          AS
                                          INSERT INTO [$SqlSchema].[$SqlTable] (id, JsonDocument)
                                          SELECT id, COMPRESS(JsonDocument) FROM @table
                                          GO"

                New-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Name $SqlDatabase -EnableException > $null
                Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $SqlDatabase -Query $CreateSqlObjectsQuery -EnableException
            }
            else {
                throw $_
            }
        }
        #endregion Check SQL table

        #region Params
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f ($CbCredential.UserName), ($CbCredential.GetNetworkCredential().Password) )))  
        $Uri =  "http://$($CbQueryNode):$CbQueryPort/query/service"
        $CbGetRetryCount = $CbRetryCount
        $CbDeleteRetryCount = $CbRetryCount
        #endregion Params

        #region Fix encoding problem
        Function Get-DecodedString { 
            [cmdletbinding()]Param (
                [parameter(ValueFromPipeline)]$wrong_string
            )
            
            if ([System.Text.Encoding]::Default.CodePage -ne 65001){
                $utf8 = [System.Text.Encoding]::GetEncoding(65001) 
                $iso88591 = [System.Text.Encoding]::GetEncoding('ISO-8859-9')
                $wrong_bytes = $utf8.GetBytes($wrong_string)
                $right_bytes = [System.Text.Encoding]::Convert($utf8,$iso88591,$wrong_bytes) #Look carefully 
                $right_string = $utf8.GetString($right_bytes) #Look carefully 
                $right_string
            }
            else {$wrong_string}
        }
        #endregion Fix encoding problem
    }
    
    process {
        #region Get data from Couchbase

        $IfExists = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $SqlDatabase -Query "SELECT TOP 1 CAST(1 AS BIT) FROM [$SqlSchema].[$SqlTable] WITH (NOLOCK) WHERE DeleteStatus = 0" -EnableException -As SingleValue

        while (!$IfExists) {
            try {
                $ApiResult = Invoke-RestMethod -Uri $Uri -Method Post -Body @{statement = $CbQuery} -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)}
                break;
            }
            catch {
                if ($CbGetRetryCount -gt 0) {
                    $CbGetRetryCount--
                    Start-Sleep -Milliseconds $CbRetryDelayMs
                 }
                 else { throw $_ }
            }
        }
        #endregion Get data from Couchbase

        #region Insert data to SQL Server
        if ($ApiResult.status -eq "success" -and ($ApiResult.results)) {
    
            $DataTable = $ApiResult | Select-Object -ExpandProperty results | Select-Object id, @{N='JsonDocument'; E={$_ | ConvertTo-Json -Depth $CbDepthForJson | Get-DecodedString}} | 
                                                                                ConvertTo-DbaDataTable -EnableException 

            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $SqlDatabase -Query "[$SqlSchema].[Insert_$CbBucketName]" -CommandType StoredProcedure -SqlParameters @{ table = $DataTable } -EnableException -QueryTimeout 0
        }
        #endregion Insert data to SQL Server

        #region Prepare Ids for delete
        $Ids = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $SqlDatabase -Query "SELECT id FROM [$SqlSchema].[$SqlTable] WITH (NOLOCK) WHERE DeleteStatus = 0" -EnableException -As SingleValue 
    
        $Ids_in = "'$($Ids -join "', `r`n'")'"
        $CbDeleteQuery  = "DELETE FROM ``$CbBucketName`` USE KEYS [$Ids_in];"
        $SqlUpdateQuery = "UPDATE [$SqlSchema].[$SqlTable] SET DeleteStatus = 1 WHERE id IN ($Ids_in);"
        #endregion Prepare Ids for delete

        #region Delete data from Couchbase
        while ($true) {
            try {
                $ApiResult = Invoke-RestMethod -Uri $Uri -Method Post -Body @{statement = $CbDeleteQuery} -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)}
                break;
            }
            catch {
                if ($CbDeleteRetryCount -gt 0) {
                    $CbDeleteRetryCount--
                    Start-Sleep -Milliseconds $CbRetryDelayMs
                 }
                 else { throw $_ }
            }
        }
        #endregion Delete data from Couchbase

        #region Update DeleteStatus to true
        Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $SqlDatabase -Query "UPDATE [$SqlSchema].[$SqlTable] SET DeleteStatus = 1 WHERE id IN ($Ids_in)" -EnableException -As SingleValue 
        #endregion Update DeleteStatus to true

    }
    
    end {
        #Garbage collection
        [system.gc]::Collect();
    }
}

<#PSScriptInfo

.SYNOPSIS
    Invoke-CbQuery
    
.DESCRIPTION
    Execute N1QL query on Couchbase using N1QL rest-api.

.EXAMPLE
    #
    
.NOTES
    Version     : 1.3 (2020-12-05)
    File Name   : Invoke-CbQuery.ps1
    Author      : Ahmet Rende (ahmet@ahmetrende.com) 
    GitHub      : https://github.com/ahmetrende

#>
Function Invoke-CbQuery {
    [CmdletBinding()]
    param (
         [Parameter(Mandatory=$true)][string]$CbServer
        ,[Parameter(Mandatory=$true)][string]$Query
        ,[PSCredential]$CbCredential
        ,[string]$UserName
        ,[string]$Password
        ,[int]$N1qlPort = 8093
        ,[ValidateSet("Default", "Json", "PSCustomObject", "OnlyStatus")][string]$As = "Default"
        ,[int]$DepthForJson = 50
        ,[int]$RetryCount = 5
        ,[int]$RetryDelayMs = 500
    )

    $ErrorActionPreference = 'stop'
    #region Params
    if ($CbCredential) {
        $UserName = $CbCredential.UserName
        $Password = $CbCredential.GetNetworkCredential().Password
    }
  
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $UserName, $Password)))  
    $Uri =  "http://$($CbServer):$N1qlPort/query/service"
    $Body = @{
        statement = $Query;
        timeout = "-1s";
    }
    $Headers = @{
        Authorization = ("Basic {0}" -f $base64AuthInfo)
    } 
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

    while ($true) {
        try {
            $ApiResult = Invoke-RestMethod -Uri $Uri -Method Post -Body $Body -Headers $Headers -DisableKeepAlive
            break;
        }
        catch {
            if ($RetryCount -gt 0) {
                $RetryCount -= 1
                Start-Sleep -Milliseconds $RetryDelayMs
             }
             else { throw $_ }
        }
    }
   
    if ($As -eq "Default") {
        $ApiResult
    }
    elseif ($As -eq "Json" -and ($ApiResult.results)) {
        $ApiResult | select -ExpandProperty results | ConvertTo-Json -Depth $DepthForJson | Get-DecodedString
    }
    elseif ($As -eq "PSCustomObject" -and ($ApiResult.results)) {
        $ApiResult | select -ExpandProperty results | ConvertTo-Json -Depth $DepthForJson | Get-DecodedString | ConvertFrom-Json
    }
     elseif ($As -eq "OnlyStatus" -and ($ApiResult.status)) {
        $ApiResult | select -ExpandProperty status
    }
}

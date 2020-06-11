Function Invoke-CbQuery {
    [CmdletBinding()]
    param (
         [string]$CbServer
        ,[Parameter(Mandatory=$true)][string]$Query
        ,[PSCredential]$CbCredential
        ,[string]$UserName
        ,[string]$Password
        ,[int]$N1qlPort = 8093
        #,[int]$Timeout = 600
        ,[ValidateSet("Default", "Json", "PSCustomObject", "OnlyStatus")][string]$As = "Default"
        ,[int]$DepthForJson = 50
        ,[int]$RetryCount = 3 
        ,[int]$RetryDelayMs = 1000
    )

    #region Params
    if ($CbCredential) {
        $UserName = $CbCredential.UserName
        $Password = $CbCredential.GetNetworkCredential().Password
    }
  
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $UserName, $Password)))  
    $Uri =  "http://$($CbServer):$N1qlPort/query/service"
    $Body = @{
        statement = $Query;
        #timeout="$($Timeout)s"      
    }
    $Headers = @{
        Authorization = ("Basic {0}" -f $base64AuthInfo)
    } 

    #endregion Params

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
    elseif ($As -eq "Json" -and !([string]::IsNullOrEmpty($ApiResult.results))) {
        $ApiResult | select -ExpandProperty results | ConvertTo-Json -Depth $DepthForJson | Get-DecodedString
    }
    elseif ($As -eq "PSCustomObject" -and !([string]::IsNullOrEmpty($ApiResult.results))) {
        $ApiResult | select -ExpandProperty results | ConvertTo-Json -Depth $DepthForJson | Get-DecodedString | ConvertFrom-Json
    }
     elseif ($As -eq "OnlyStatus" -and !([string]::IsNullOrEmpty($ApiResult.status))) {
        $ApiResult | select -ExpandProperty status
    }

}


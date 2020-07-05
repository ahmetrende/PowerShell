<#PSScriptInfo
.SYNOPSIS
    Get Couchbase cluster information.
    
.DESCRIPTION
    This function retrieves some cluster informations.
    Also included Test-Port function for testing port access.
    
.EXAMPLE
    $Cred = Get-Credential
    Get-CbServer -CbServer "<SERVERADDRESS>" -Port 8091 -CbCredential $Cred -GetAllNodes
    
.NOTES
    Version     : 1.0 (2020-07-05)
    File Name   : Get-CbServer.ps1
    Author      : Ahmet Rende (ahmet@ahmetrende.com) 
    GitHub      : https://github.com/ahmetrende
#>
function Get-CbServer {
    [CmdletBinding()] 
    param(
         [string]$CbServer
        ,[int]$Port = 8091
        ,[switch]$GetAllNodes
        ,[PSCredential]$CbCredential
        ,[string]$UserName
        ,[string]$Password
        )
  
    $ErrorActionPreference = 'Stop'
    #region Params
    if ($CbCredential) {
        $UserName = $CbCredential.UserName
        $Password = $CbCredential.GetNetworkCredential().Password
    }
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $UserName, $Password)))  
    #endregion Params

    try {
        $PingResult = Test-Connection $CbServer -Count 1 -Quiet -ErrorAction SilentlyContinue
        if($PingResult -or (Test-Connection $CbServer -Quiet -ErrorAction SilentlyContinue)){
            if (Test-Port -ComputerName $CbServer -Port $Port -Timeout 200 -Slient){
                Remove-Variable -Name result -Force -Confirm:$false -ErrorAction SilentlyContinue
               
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    Get-TypeData -TypeName System.Array -ErrorAction SilentlyContinue | Remove-TypeData -ErrorAction SilentlyContinue
                }

                $cluster = Invoke-RestMethod "http://$($CbServer):$($Port)/pools" -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} 
                $buckets = Invoke-RestMethod "http://$($CbServer):$($Port)/pools/default/buckets" -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} 
                $clusterName = Invoke-RestMethod "http://$($CbServer):$($Port)/pools/default" -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} 
                $nodes   = Invoke-RestMethod "http://$($CbServer):$($Port)/pools/nodes" -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)} 
                $xdcr    = Invoke-RestMethod "http://$($CbServer):$($Port)/pools/default/remoteClusters" -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo)}
                
                $buckets = $buckets | sort -Property name | select @{N='BucketName'; E={$_.name}} | select -ExpandProperty BucketName 
                $xdcr = ($xdcr | sort -Property name | select  @{N='Xdcr'; E={$_.name + " (" + $_.hostname + ")"}}).Xdcr
              
                $result = $nodes.nodes | where {$_.hostname -like "*$CbServer*" -or $GetAllNodes -eq $true} | select `
                                            @{N='CbServer'; E={($_.hostname).Replace(":$($Port)","")}} `
                                            ,services `
                                            ,status `
                                            ,clusterMembership `
                                            ,@{N='bucket'; E={$buckets}} `
                                            ,@{N='xdcr'; E={$xdcr.Replace(":$($Port)","")}} `
                                            ,@{N='uuid'; E={$cluster.uuid}} `
                                            ,@{N='clusterName'; E={$clusterName.clusterName}} `
                                            ,@{N='CollectionDate'; E={((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))}}
                
            }
            else {
                $result = [PSCustomObject]@{
                    CbServer = $CbServer
                    Notes  = "Port $Port is not reachable."
                    CollectionDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                }
            }
        }
        else {
            $result = [PSCustomObject]@{
                CbServer = $CbServer
                Notes  = "Cannot access the server. (No ping)"
                CollectionDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
    }
    catch {
        $ExceptionMsg = ($_.Exception.Message | Out-String).Trim()
        if ($ExceptionMsg -like "*404*") {$ExceptionMsg = "Server is not configured."}
        $result = [PSCustomObject]@{
            CbServer = $CbServer
            Notes  = $ExceptionMsg
            CollectionDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    $result | ConvertTo-Json -Depth 50 | select @{N='Json'; E={$_}} | select -ExpandProperty Json
}
Function Test-Port {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, HelpMessage = 'Could be suffixed by :Port')]
        [String[]]$ComputerName,

        [Parameter(HelpMessage = 'Will be ignored if the port is given in the param ComputerName')]
        [Int]$Port = 1433,

        [Parameter(HelpMessage = 'Timeout in millisecond. Increase the value if you want to test Internet resources.')]
        [Int]$Timeout = 1000,

        [Parameter(HelpMessage = 'Will be return only true or false.')]
        [switch]$Slient
    )

    begin {
        $result = [System.Collections.ArrayList]::new()
    }

    process {
        foreach ($originalComputerName in $ComputerName) {
            $remoteInfo = $originalComputerName.Split(":")
            if ($remoteInfo.count -eq 1) {
                # In case $ComputerName in the form of 'host'
                $remoteHostname = $originalComputerName
                $remotePort = $Port
            } elseif ($remoteInfo.count -eq 2) {
                # In case $ComputerName in the form of 'host:port',
                # we often get host and port to check in this form.
                $remoteHostname = $remoteInfo[0]
                $remotePort = $remoteInfo[1]
            } else {
                $msg = "Got unknown format for the parameter ComputerName: " `
                    + "[$originalComputerName]. " `
                    + "The allowed formats is [hostname] or [hostname:port]."
                Write-Error $msg
                return
            }

            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $portOpened = $tcpClient.ConnectAsync($remoteHostname, $remotePort).Wait($Timeout)
         
            $null = $result.Add([PSCustomObject]@{
                RemoteHostname       = $remoteHostname
                RemotePort           = $remotePort
                PortOpened           = $portOpened
                TimeoutInMillisecond = $Timeout
                SourceHostname       = $env:COMPUTERNAME
                OriginalComputerName = $originalComputerName
                })
        }
    }

    end {

        if ($Slient) {
            return $result.PortOpened
        }
        else {
            return $result
        }
    }
}

<#PSScriptInfo
.SYNOPSIS
    Returns query result from PostgreSQL with ODBC.
    
.DESCRIPTION
    This function returns a query result with PostgreSQL ODBC driver.
    You can download odbc driver from https://odbc.postgresql.org
    
.EXAMPLE
    Get-PgOdbcData -Servername "server1" -Database "postgres" -Query "SELECT now() as datetime;" -UserName "<UserName>" -Password "<Password>" -Port 5432
    
.NOTES
    Version     : 1.0 (2020-08-04)
    File Name   : Get-PgOdbcData.ps1
    Author      : Ahmet Rende (ahmet@ahmetrende.com) 
    GitHub      : https://github.com/ahmetrende
#>

function Get-PgOdbcData {
    [CmdletBinding()]
    param (
         $Servername
        ,$Database
        ,$Query
        ,$UserName
        ,$Password
        ,$Port = 5432
        ,$DriverName = "PostgreSQL Unicode(x64)"
    )
 
    $ErrorActionPreference = 'Stop'
    
    $OdbcName = "PG_" + (Get-Date -Format "FileDateTime") + "_" + $pid
    Add-OdbcDsn -Name $OdbcName -DriverName $DriverName -DsnType User -SetPropertyValue @("Servername=$Servername", "Database=$Database", "Username=$UserName", "Password=$Password", "Port=$Port", "MaxLongVarcharSize=-4", "BoolsAsChar=0" ) > $null 
    
    $Conn = New-Object System.Data.Odbc.OdbcConnection
    $Conn.ConnectionString = "DSN=$OdbcName;"
    $Conn.Open()
    $Cmd = New-object System.Data.Odbc.OdbcCommand($Query,$Conn)
    $Dt = New-Object System.Data.DataTable
    $Reader = $Cmd.ExecuteReader()

    try {
        $Dt.Load($Reader)
    }
    catch {
        if ($_.Exception.Message -notlike "*Failed to enable constraints*"){
            throw $_
        }
    }
    finally{
        $Conn.Dispose()
        $Conn.Close()
        Remove-OdbcDsn -Name $OdbcName -DsnType User > $null 
    }
        
    $Dt

}


<#
	Runs the reproduction page several times against one or more of the four test servers and
	prints a table.

	  .\repro.ps1                                  # all four servers, 10 runs each
	  .\repro.ps1 -Servers 2023,2025 -Runs 20
	  .\repro.ps1 -Servers 2023 -FreshStart        # restart the server before every run
	  .\repro.ps1 -Setup                           # first time: install all four, build the fix into the two "-fixed" servers

	Each run of index.cfm writes a brand-new component, so its metadata is untouched, as it is
	right after a restart. -FreshStart also restarts the JVM before each run.
#>
param(
	[ValidateSet( '2023', '2023-fixed', '2025', '2025-fixed' )]
	[string[]] $Servers = @( '2023', '2023-fixed', '2025', '2025-fixed' ),
	[int] $Runs = 10,
	[int] $Threads = 10,
	[ValidateSet( 'param', 'write', 'struct' )]
	[string] $Mode = 'param',
	[switch] $FreshStart,
	[switch] $Setup
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Get-ServerInfo( [string] $name ) {
	$config = Join-Path $root "server-$name.json"
	$json = Get-Content $config -Raw | ConvertFrom-Json
	[pscustomobject]@{
		Name   = $name
		Config = $config
		Port   = [int] $json.web.HTTP.port
		Home   = Join-Path $root $json.app.serverHomeDirectory
	}
}

function Stop-Server( $s ) {
	# Kill the JVM that owns the port, so the next start is a genuinely fresh JVM.
	$conn = Get-NetTCPConnection -LocalPort $s.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
	if ( $conn ) { Stop-Process -Id $conn.OwningProcess -Force }
	for ( $i = 0; $i -lt 30 -and ( Get-NetTCPConnection -LocalPort $s.Port -State Listen -ErrorAction SilentlyContinue ); $i++ ) { Start-Sleep 1 }
	foreach ( $f in '.pid.txt', 'serverInfo.json' ) { Remove-Item ( Join-Path $s.Home $f ) -Force -ErrorAction SilentlyContinue }
}

function Start-Server( $s ) {
	Push-Location $root
	try { box server start "serverConfigFile=$($s.Config)" | Out-Null }
	finally { Pop-Location }
	for ( $i = 0; $i -lt 180; $i++ ) {
		try {
			$r = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$($s.Port)/ping.cfm" -TimeoutSec 5
			if ( $r.Content -like 'ok*' ) { return }
		} catch { }
		Start-Sleep 1
	}
	throw "$($s.Name): not answering on port $($s.Port)."
}

if ( $Setup ) {
	foreach ( $name in '2023', '2023-fixed', '2025', '2025-fixed' ) {
		$s = Get-ServerInfo $name
		Write-Host "== ${name}: install and start"
		Start-Server $s
		if ( $name -like '*-fixed' ) {
			Write-Host "== ${name}: stop, build the fix, start"
			Stop-Server $s
			& ( Join-Path $root 'fix\build-fix.ps1' ) -ServerHome $s.Home
			Start-Server $s
		}
	}
}

$rows = foreach ( $name in $Servers ) {
	$s = Get-ServerInfo $name
	$failed = 0; $broken = 0; $npe = 0; $classes = 0
	for ( $run = 1; $run -le $Runs; $run++ ) {
		if ( $FreshStart ) { Stop-Server $s; Start-Server $s }
		$out = ( Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$($s.Port)/index.cfm?threads=$Threads&mode=$Mode" -TimeoutSec 180 ).Content
		if ( $out -match 'result:\s+INVALID' ) { throw "$($name): $out" }
		if ( $out -match 'result:\s+FAIL' ) { $failed++ }
		if ( $out -match 'after burst:\s+(\d+) of (\d+)' ) {
			if ( [int] $Matches[ 1 ] -gt 0 ) { $broken++ }
			$classes += [int] $Matches[ 1 ]
		}
		if ( $out -match '(\d+) x Cannot invoke "coldfusion\.util\.Key\.getKeyString\(\)"' ) { $npe += [int] $Matches[ 1 ] }
		$version = [regex]::Match( $out, 'server:\s+(.+)' ).Groups[ 1 ].Value.Trim()
	}
	[pscustomobject]@{
		Server               = $name
		Version              = $version
		Runs                 = $Runs
		'Runs failed'        = $failed
		'Runs left broken'   = $broken
		'Components broken'  = "$classes of $( $Runs * 10 )"
		'getKeyString NPEs'  = $npe
	}
}
$rows | Format-Table -AutoSize

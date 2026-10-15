<#
	Builds the CaseInsensitiveMap fix from a ColdFusion server's own cfusion.jar and installs it
	into that server's lib\updates folder. No Adobe class file is stored in this repository; the
	jar is made on your machine from the engine you already have.

	  .\fix\build-fix.ps1 -ServerHome .engine\acf2023-fixed
	  .\fix\build-fix.ps1 -ServerHome C:\ColdFusion2023\cfusion\..   (a standard install's root that holds WEB-INF or cfusion\lib)

	Stop the server first and start it again afterwards: a jar copied into a running server is
	not picked up.

	Needs a JDK (javac). It uses JAVA_HOME if set, otherwise the newest CommandBox JDK.
#>
param(
	[Parameter( Mandatory )] [string] $ServerHome,
	[string] $JavaHome = $env:JAVA_HOME
)
$ErrorActionPreference = 'Stop'
$fixDir   = $PSScriptRoot
$toolsDir = Join-Path $fixDir 'tools'
$buildDir = Join-Path $fixDir 'build'

# ---------------------------------------------------------------- the engine's lib folder
$ServerHome = ( Resolve-Path $ServerHome ).Path
$libDir = @( 'WEB-INF\cfusion\lib', 'cfusion\lib', 'lib' ) |
	ForEach-Object { Join-Path $ServerHome $_ } |
	Where-Object { Test-Path ( Join-Path $_ 'cfusion.jar' ) } |
	Select-Object -First 1
if ( -not $libDir ) { throw "No cfusion.jar under $ServerHome (looked in WEB-INF\cfusion\lib, cfusion\lib, lib)." }
$cfusionJar = Join-Path $libDir 'cfusion.jar'
$updatesDir = Join-Path $libDir 'updates'

# The class must be patched from the copy the server really loads. ColdFusion loads the newest
# cumulative update jar (chf<version><update>.jar) ahead of cfusion.jar, and some updates ship
# their own CaseInsensitiveMap (2025 Update 13 does; 2023 Update 25 does not).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$chf = Get-ChildItem $updatesDir -Filter 'chf*.jar' -ErrorAction SilentlyContinue |
	Where-Object { $_.Name -match '^chf(\d{4})(\d+)\.jar$' } |
	Sort-Object { [int] [regex]::Match( $_.Name, '^chf\d{4}(\d+)' ).Groups[ 1 ].Value } -Descending |
	Select-Object -First 1
if ( -not $chf ) { throw "No chf<version>.jar in $updatesDir; cannot tell which ColdFusion version this is." }
$sourceJar = $cfusionJar
$zip = [System.IO.Compression.ZipFile]::OpenRead( $chf.FullName )
try { if ( $zip.GetEntry( 'coldfusion/util/CaseInsensitiveMap.class' ) ) { $sourceJar = $chf.FullName } }
finally { $zip.Dispose() }
Write-Host "Patching CaseInsensitiveMap from $sourceJar"

# The update loader (coldfusion.bootstrap.ClassloaderHelper) accepts a hotfix jar only if its name
# is hf + the six-digit version (202300, 202500) + five characters that parse as a number, like
# Adobe's own hf202300-4232227.jar. Hotfix jars load ahead of the cumulative update jar.
$major   = [regex]::Match( $chf.Name, '^chf(\d{4})' ).Groups[ 1 ].Value
$jarName = "hf${major}00-00001-casemap-fix.jar"
Get-ChildItem $updatesDir -Filter '*casemap-fix*.jar' -ErrorAction SilentlyContinue | Remove-Item -Force

# ---------------------------------------------------------------- a JDK
if ( -not $JavaHome -or -not ( Test-Path ( Join-Path $JavaHome 'bin\javac.exe' ) ) ) {
	$JavaHome = Get-ChildItem ( Join-Path $env:USERPROFILE '.CommandBox\serverJREs' ) -Directory -ErrorAction SilentlyContinue |
		Where-Object { Test-Path ( Join-Path $_.FullName 'bin\javac.exe' ) } |
		Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if ( -not $JavaHome ) { throw 'No JDK found. Set JAVA_HOME to a JDK 11 or newer.' }
$javac = Join-Path $JavaHome 'bin\javac.exe'
$java  = Join-Path $JavaHome 'bin\java.exe'
$javap = Join-Path $JavaHome 'bin\javap.exe'

# ---------------------------------------------------------------- ASM 9.7 from Maven Central, hash-checked
$asm = @(
	@{ Name = 'asm-9.7.jar';      Url = 'https://repo1.maven.org/maven2/org/ow2/asm/asm/9.7/asm-9.7.jar';           Sha = 'adf46d5e34940bdf148ecdd26a9ee8eea94496a72034ff7141066b3eea5c4e9d' },
	@{ Name = 'asm-tree-9.7.jar'; Url = 'https://repo1.maven.org/maven2/org/ow2/asm/asm-tree/9.7/asm-tree-9.7.jar'; Sha = '62f4b3bc436045c1acb5c3ba2d8ec556ec3369093d7f5d06c747eb04b56d52b1' }
)
New-Item -ItemType Directory -Force $toolsDir, $buildDir | Out-Null
foreach ( $a in $asm ) {
	$path = Join-Path $toolsDir $a.Name
	if ( -not ( Test-Path $path ) ) { Invoke-WebRequest -UseBasicParsing $a.Url -OutFile $path }
	$sha = ( Get-FileHash $path -Algorithm SHA256 ).Hash.ToLower()
	if ( $sha -ne $a.Sha ) { Remove-Item $path; throw "$($a.Name): SHA256 $sha does not match the pinned $($a.Sha)." }
}
$cp = ( $asm | ForEach-Object { Join-Path $toolsDir $_.Name } ) -join ';'

# ---------------------------------------------------------------- compile, patch, check
& $javac -nowarn --release 11 -cp $cp -d $buildDir ( Join-Path $fixDir 'PatchCaseInsensitiveMap.java' )
if ( $LASTEXITCODE -ne 0 ) { throw 'javac failed.' }

$outJar = Join-Path $buildDir $jarName
& $java -cp "$cp;$buildDir" PatchCaseInsensitiveMap $sourceJar $outJar
if ( $LASTEXITCODE -ne 0 ) { throw 'Patching failed; nothing was installed.' }

# Show the two constructors as they now are.
$dis = & $javap -c -cp $outJar coldfusion.util.CaseInsensitiveMap
$ctors = [regex]::Matches( ( $dis -join "`n" ), '(?s)public coldfusion\.util\.CaseInsensitiveMap\((int)?\);.*?return' )
if ( $ctors.Count -ne 2 -or ( $ctors | Where-Object { $_.Value -notmatch 'CFConcurrentHashMap' -or $_.Value -match 'java/util/HashMap' } ) ) {
	throw 'The patched constructors do not look right; nothing was installed.'
}
Write-Host 'Patched constructors:'
$ctors | ForEach-Object { Write-Host $_.Value; Write-Host '' }

# ---------------------------------------------------------------- install
New-Item -ItemType Directory -Force $updatesDir | Out-Null
Copy-Item $outJar ( Join-Path $updatesDir $jarName ) -Force
Write-Host "Installed $jarName into $updatesDir"
Write-Host 'Restart ColdFusion for it to take effect. To remove the fix, delete that jar and restart.'

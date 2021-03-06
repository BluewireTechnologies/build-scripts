param(
    [string]$workingRoot,
    [string]$msBuildPath,
    [string]$outputDirectory,
    [switch]$debug
)

Trap {
    Write-Host $error[0];
    Write-Host "Failed to build packages.";
    exit 2;
}
$ErrorActionPreference = "Stop";
$BuildScriptPath = "${workingRoot}\scripts\package.proj";

function Die([int]$code, [string]$message)
{
    Write-Host $message;
    exit $code;
}

if (-not (Test-Path "${workingRoot}")) { Die 4 "Working copy directory does not exist: ${workingRoot}"; }
$gitDir = "${workingRoot}\.git";
if (-not (Test-Path "${gitDir}")) { Die 4 "Not a Git repository: ${gitDir}"; }
if (-not (Test-Path "${BuildScriptPath}")) { Die 4 "Build script was not found: ${BuildScriptPath}"; }
if (-not "${msBuildPath}") { Die 4 "MSBuild path was not specified."; }
if (-not (Test-Path "${msBuildPath}")) { Die 4 "MSBuild was not found at the specified path: ${msBuildPath}"; }

function Invoke-Git()
{
    Run-Executable git -C "${workingRoot}" @args;
}

function Run-Executable($executable)
{
    if ($debug)
    {
        Write-Host ". '${executable}' $(${args} -join ' ')"
    }
    $LASTEXITCODE = 0;
    &$executable @args;
}

function Put-Parameter($name, $value)
{
    Write-TeamCity "setParameter" @{ name = $name; value = $value; };
}

function Write-TeamCity([string]$type, $values)
{
    function Format-StringValue([string]$value)
    {
        $escaped = $value.Replace("|", "||").Replace("'", "|'").Replace("`n", "|n").Replace("`r", "|r").Replace("[", "|[").Replace("]", "|]");
        return "'${escaped}'";
    }

    function Format-TeamcityValues($values)
    {
        if ($values -is [string]) { return Format-StringValue $values; }
        if (-not $values.Keys) { return ""; }
        if (-not $values.GetEnumerator) { return ""; }
        return @($values.GetEnumerator() | %{ "$($_.Key)=$(Format-StringValue $_.Value)" }) -join ' ';
    }

    Write-Host "##teamcity[${type} $(Format-TeamcityValues ${values})]"
}

function Invoke-BuildScript([string]$siteName, [string]$siteVersion)
{
    Write-TeamCity "message" @{ text = "Building site ${siteName}, version ${siteVersion}"; }
    Run-Executable $msBuildPath $BuildScriptPath /p:Site=${siteName} /p:OutputVersion=${siteVersion} /p:OutputDirectory=${outputDirectory}
    if ($LASTEXITCODE) { Die 3 "MSBuild exited with code $LASTEXITCODE"; }
}

function Count-RevisionsOfPath([string]$path, [string]$startRef, [string]$endRef = "HEAD")
{
    @(Invoke-Git log --oneline "${startRef}..${endRef}" '--' "${path}").Length;
    if ($LASTEXITCODE) { Die 3 "git log returned error code $LASTEXITCODE"; }
}

function Get-LastChangeRevision([string]$path, [string]$ref = "HEAD")
{
    Invoke-Git rev-list -1 "${ref}" '--' "${path}";
    if ($LASTEXITCODE) { Die 3 "git rev-list returned error code $LASTEXITCODE"; }
}

function Get-MajorMinorVersionNumber([string]$versionFilePath, [string]$endRef = "HEAD")
{
    $ref = "HEAD";
    $gitCompatiblePath = $versionFilePath.Replace('\', '/');
    $majorMinor = $(Invoke-Git show "${endRef}:${gitCompatiblePath}");
    if (!$?) {
        # File doesn't exist?
        return $null;
    }

    $m = $majorMinor -match '^(?<major>[0-9]+)\.(?<minor>[0-9]+)$';
    if(!$m) {
        # Not in the form major.minor?
        return $null;
    }
    
    $startRef = Get-LastChangeRevision $versionFilePath $endRef;
    return @{
        Major = $matches['major'];
        Minor = $matches['minor'];
        LastBump = $startRef;
    };
}

function Build-Site()
{
    BEGIN {
    }
    PROCESS {
        $siteName = $_.Name;
        Write-TeamCity "progressStart" $siteName
        Try {
            $siteRoot = $_.FullName;
            $siteVersionFile = "Sites\${siteName}\version";
            if (-not (Test-Path "${workingRoot}\${siteVersionFile}")) {
                # Possibly not yet a valid Site directory? Skip this one with a warning.
                Write-TeamCity "message" @{ text = "Version file does not exist: ${siteVersionFile}"; status = "WARNING"; }
                return;
            }
            
            $majorMinor = Get-MajorMinorVersionNumber $siteVersionFile;
            if(!$majorMinor) { throw "Unable to determine major.minor version number: ${siteVersionFile}"; }

            $buildNumber = Count-RevisionsOfPath "Sites\${siteName}" $majorMinor.LastBump;

            $version = @(
                $majorMinor.Major,
                $majorMinor.Minor,
                $buildNumber
            ) -join ".";
            
            Put-Parameter "system.${siteName}.Version" $version;
            
            Invoke-BuildScript $siteName $version | Out-Host; 
            
        } catch {
            Write-TeamCity "message" @{ text = "$_"; status = "ERROR"; }
        } finally {
            Write-TeamCity "progressFinish" $siteName
        }
    }
    END {
    }
}

$siteNames = Get-ChildItem "${workingRoot}\Sites" | Build-Site;

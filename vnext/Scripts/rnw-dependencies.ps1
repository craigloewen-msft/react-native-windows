# Troubleshoot RNW dependencies
param(
    [switch]$Install = $false,
    [switch]$NoPrompt = $false,
    [switch]$Clone = $false,
    [switch]$ListChecks = $false,
    [string]$Check = [CheckId]::All,

    [Parameter(ValueFromRemainingArguments)]
    [ValidateSet('appDev', 'rnwDev', 'buildLab', 'vs2022', 'clone')]
    [String[]]$Tags = @('appDev'),
    [switch]$Enterprise = $false
)

$ShellInvocation = ($PSCmdlet.MyInvocation.BoundParameters -ne $null);

$Verbose = $false
if ($ShellInvocation) {
    $Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent;
}

enum CheckId {
    All
    AzureFunctions
    DeveloperMode
    DotNetCore
    FreeSpace
    git
    InstalledMemory
    LongPath
    MSBuildLogViewer
    Node
    RNWClone
    VSUWP
    WinAppDriver
    WindowsADK
    WindowsVersion
    Yarn
    CppWinRTVSIX
}

# CODESYNC \packages\@react-native-windows\cli\src\runWindows\runWindows.ts
$MarkerFile = "$env:LOCALAPPDATA\rnw-dependencies.txt"

# Create a set to handle with case insensitivy of the tags
$tagsToInclude = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnorecase)
foreach ($tag in $Tags) { $tagsToInclude.Add($tag) | Out-null }

# Convert legacy flags to tasks:
if ($Clone) {
    $tagsToInclude.Add('clone') | Out-null;
}

# Handle expansion of tasks
if ($tagsToInclude.Contains('buildLab')) {
    # The build lab needs the same steps as a react-native dev
    $tagsToInclude.Add('rnwDev') | Out-null;
}
if ($tagsToInclude.Contains('rnwDev')) {
    # A react-native dev needs the same as the default
    $tagsToInclude.Add('appDev') | Out-null;
}

$vsComponents = @('Microsoft.Component.MSBuild',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.ComponentGroup.UWP.Support',
    'Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core',
    'Microsoft.VisualStudio.Component.Windows10SDK.19041');

# UWP.VC is not needed to build the projects with msbuild, but the VS IDE requires it.
if (!($tagsToInclude.Contains('buildLab'))) {
    $vsComponents += 'Microsoft.VisualStudio.ComponentGroup.UWP.VC';
}

$vsWorkloads = @('Microsoft.VisualStudio.Workload.ManagedDesktop',
    'Microsoft.VisualStudio.Workload.NativeDesktop',
    'Microsoft.VisualStudio.Workload.Universal');

$vsAll = ($vsComponents + $vsWorkloads);

# The minimum VS version to check for
# Note: For install to work, whatever min version you specify here must be met by the current package available on winget.
$vsver = "17.3";

# The exact .NET SDK version to check for
$dotnetver = "6.0";
# Version name of the winget package
$wingetDotNetVer = "6";

$v = [System.Environment]::OSVersion.Version;
if ($env:Agent_BuildDirectory) {
    $drive = (Resolve-Path $env:Agent_BuildDirectory).Drive;
} else {
    if ($PSCommandPath) {
        $drive = (Resolve-Path $PSCommandPath).Drive;
    } else {
        $drive = (Resolve-Path $env:SystemDrive).Drive;
    }
}

function Get-VSWhere {
    Write-Verbose "Looking for Visual Studio Installer...";
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe";
    if (!(Test-Path $vsWhere)) {
        Write-Verbose "Visual Studio Installer not found.";
        return $null;
    }

    Write-Verbose "Visual Studio Installer found.";
    return $vsWhere;
}

function Get-VSPathPropertyForEachInstall {
    param(
        [string]$VsWhere,
        [string]$PathProperty,
        [string[]]$ExtraArgs =@()
    )

    [String[]]$output = & $VsWhere -version $vsver -property $PathProperty $ExtraArgs;
    if ($output -ne $null) {
        [String[]]$paths = ($output | Where-Object { (Test-Path $_) });
        return $paths;
    }
    
    return $null;
}

function CheckVS-WithVSWhere {
    param(
        [string]$VsWhere,
        [switch]$CheckPreRelease = $false
    )

    [string[]] $requireArgs = @("-requires");
    $requireArgs += $vsAll;

    [string[]] $prereleaseArgs = @();
    if ($CheckPreRelease) {
        $prereleaseArgs += "-prerelease";
    }

    # Checking for VS + all required components
    [String[]]$productPaths = Get-VSPathPropertyForEachInstall -VsWhere $VsWhere -PathProperty 'productPath' -ExtraArgs ($requireArgs + $prereleaseArgs);
    if ($productPaths.Count -gt 0) {
        Write-Verbose "Visual Studio install(s) found, with required components, at:";
        $productPaths | ForEach { Write-Verbose "  $_" };
        return $true;
    }

    # Check for VS without required components
    [String[]]$productPaths = Get-VSPathPropertyForEachInstall -VsWhere $VsWhere -PathProperty 'productPath' -ExtraArgs $prereleaseArgs;
    if ($productPaths.Count -gt 0) {
        Write-Verbose "Visual Studio install(s) found, but without required components, at:";
        $productPaths | ForEach { Write-Verbose "  $_" };
        return $false;
    }

    Write-Verbose "No Visual Studio installs found.";

    return $false;
}

function CheckVS {
    $vsWhere = Get-VSWhere;
    if ($vsWhere -eq $null) {
        return $false;
    }

    Write-Verbose "Looking for Visual Studio install(s)...";
    [bool]$result = CheckVS-WithVSWhere -VsWhere $vsWhere;

    if (!$result) {
        Write-Verbose "Retrying, but also including pre-releases versions...";
        [bool]$result = CheckVS-WithVSWhere -VsWhere $vsWhere -CheckPreRelease $true;
    }

    return $result;
}

function GetVSChannelAndProduct {
    param(
        [string]$VsWhere
    )
    
    if ($VsWhere) {
        $channelId = & $VsWhere -version $vsver -property channelId;
        $productId = & $VsWhere -version $vsver -property productId;
        
        # Channel/product not found, check one more time for pre-release
        if (($channelId -eq $null) -or ($productId -eq $null)) {
            $channelId = & $VsWhere -version $vsver -property channelId -prerelease;
            $productId = & $VsWhere -version $vsver -property productId -prerelease;
        }
        
        return $channelId, $productId;
    }
    
    return $null, $null;
}

function InstallVS {
    $vsWhere = Get-VSWhere;
    
    $channelId, $productId = GetVSChannelAndProduct -VsWhere $vsWhere

    if (($vsWhere -eq $null) -or ($channelId -eq $null) -or ($productId -eq $null)) {
        # No VSWhere / VS_Installer, try to install

        if ($Enterprise) {
            # The CI machines need the enterprise version of VS as that is what is hardcoded in all the scripts
            WinGetInstall Microsoft.VisualStudio.2022.Enterprise
        } else {
            WinGetInstall Microsoft.VisualStudio.2022.Community
        }

        $vsWhere = Get-VSWhere;

        $channelId, $productId = GetVSChannelAndProduct -VsWhere $vsWhere
    }
    
    # Final check before attempting install
    if (($vsWhere -eq $null) -or ($channelId -eq $null) -or ($productId -eq $null)) {
        throw "Unable to find or install a compatible version of Visual Studio >= ($vsver).";
    }

    $vsInstaller = Join-Path -Path (Split-Path -Parent $vsWhere) -ChildPath "vs_installer.exe";

    $addWorkloads = $vsAll | % { '--add', $_ };
    $p = Start-Process -PassThru -Wait  -FilePath $vsInstaller -ArgumentList ("modify --channelId $channelId --productId $productId $addWorkloads --quiet --includeRecommended" -split ' ');
    return $p.ExitCode;
}

function CheckNode {
    try {
        $nodeVersion = (Get-Command node -ErrorAction Stop).Version;
        Write-Verbose "Node version found: $nodeVersion";
        $v = $nodeVersion.Major;
        return ($v -ge 18) -and (($v % 2) -eq 0);
    } catch { Write-Debug $_ }

    Write-Verbose "Node not found.";
    return $false;
}

function CheckYarn {
    try {
        $yarn = (Get-Command yarn -ErrorAction Stop);
        if ($yarn -ne $null) {
            $yarnVersion = & yarn -v;
            Write-Verbose "Yarn version found: $yarnVersion";
            return $true;
        }
    } catch { Write-Debug $_ }

    Write-Verbose "Yarn not found.";
    return $false;
}

function CheckWinAppDriver {
    $WADPath = "${env:ProgramFiles(x86)}\Windows Application Driver\WinAppDriver.exe";
    if (Test-Path $WADPath) {
        $version = [Version]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($WADPath).FileVersion);
        Write-Verbose "WinAppDriver version found: $version";
        return $version.CompareTo([Version]"1.2.1") -ge 0;
    }

    Write-Verbose "WinAppDriver not found.";
    return $false;
}

function EnableDevmode {
    $RegistryKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock";

    if (-not(Test-Path -Path $RegistryKeyPath)) {
        New-Item -Path $RegistryKeyPath -ItemType Directory -Force;
    }

    $value = get-ItemProperty -Path $RegistryKeyPath -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue;
    if (($value -eq $null) -or ($value.AllowDevelopmentWithoutDevLicense -ne 1)) {
        Set-ItemProperty -Path $RegistryKeyPath -Name AllowDevelopmentWithoutDevLicense -Value 1 -ErrorAction Stop;
    }
}

function CheckCppWinRT_VSIX {
    $vsWhere = Get-VSWhere;
    if ($vsWhere -eq $null) {
        return $false;
    }

    [string]$vsPath = $null;

    Write-Verbose "Looking for Visual Studio install(s)..."
    [String[]]$vsPaths = Get-VSPathPropertyForEachInstall -VsWhere $VsWhere -PathProperty 'installationPath';
    if ($vsPaths.Count -gt 0) {
        Write-Verbose "Visual Studio install(s) found at:";
        $vsPaths | ForEach { Write-Verbose "  $_" }
        $vsPath = $vsPaths[0];
    }

    if ($vsPath -eq $null) {
        Write-Verbose "Retrying, but also including pre-releases versions..."

        [String[]]$vsPaths = Get-VSPropertyForEachInstall -VsWhere $VsWhere -Property 'installationPath' -ExtraArgs @('-prerelease');
        if ($vsPaths.Count -gt 0) {
            Write-Verbose "Visual Studio install(s) found at:";
            $vsPaths | ForEach { Write-Verbose "  $_" }
            $vsPath = $vsPaths[0];
        }
    }

    if ($vsPath -ne $null) {
        $natvis = Get-ChildItem (Join-Path -Path $vsPath -ChildPath "Common7\IDE\Extensions\cppwinrt.natvis") -Recurse;
        if ($natvis -ne $null) {
            Write-Verbose "Found CppWinRT VISX at:";
            Write-Verbose "  $(Split-Path $natvis)";
            return $true;
        }
    }

    Write-Verbose "CppWinRT VISX not found.";
    return $false;
}

function InstallCppWinRT_VSIX {
    $url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/CppWinRTTeam/vsextensions/cppwinrt101804264/2.0.210304.5/vspackage";
    Write-Verbose "Downloading CppWinRT VSIX from $url";
    Invoke-WebRequest -UseBasicParsing $url -OutFile $env:TEMP\Microsoft.Windows.CppWinRT.vsix;
    
    $vsWhere = Get-VSWhere;
    if ($vsWhere -eq $null) {
        return;
    }

    [string]$productPath = $null;

    Write-Verbose "Looking for Visual Studio install(s)...";
    [String[]]$productPaths = Get-VSPathPropertyForEachInstall -VsWhere $VsWhere -PathProperty 'productPath';
    if ($productPaths.Count -gt 0) {
        Write-Verbose "Visual Studio install(s) found at:";
        $productPaths | ForEach { Write-Verbose "  $_" };
        $productPath = $productPaths[0];
    }

    if ($productPath -eq $null) {
        Write-Verbose "Retrying, but also including pre-releases versions...";
        [String[]]$productPaths = Get-VSPathPropertyForEachInstall -VsWhere $VsWhere -PathProperty 'productPath' -ExtraArgs @('-prerelease');
        if ($productPaths.Count -gt 0) {
            Write-Verbose "Visual Studio install(s) found at:";
            $productPaths | ForEach { Write-Verbose "  $_" };
            $productPath = $productPaths[0];
        }
    }

    $VSIXInstaller_exe = Join-Path (Split-Path $productPath) "VSIXInstaller.exe";
    $process = Start-Process $VSIXInstaller_exe -PassThru -Wait -ArgumentList "/a /q $env:TEMP\Microsoft.Windows.CppWinRT.vsix";
    $process.WaitForExit();
}

function CheckDotNetCore {
    try {
        $dotnet = (Get-Command dotnet.exe -ErrorAction Stop);
        if ($dotnet -ne $null) {
            Write-Verbose ".NET found, searching for SDKs...";
            [string[]]$sdks = & dotnet --list-sdks;
            if ($sdks -ne $null) {
                Write-Verbose ".NET SDKs found:";
                $sdks | ForEach { Write-Verbose "  $_" };
                $validSDKs = $sdks | Where-Object { $_ -like  "$dotnetver.*"};
                return ($validSDKs -ne $null) -and ($validSDKs.Length -ge 1);
            }
        }
    } catch { Write-Debug $_ }

    Write-Verbose ".NET not found.";
    return $false;
}

$requiredFreeSpaceGB = 15;

$requirements = @(
    @{
        Id=[CheckId]::FreeSpace;
        Name = "Free space on current drive > $requiredFreeSpaceGB GB";
        Tags = @('appDev');
        Valid = { $drive.Free/1GB -gt $requiredFreeSpaceGB; }
        HasVerboseOutput = $true;
        Optional = $true; # this requirement is fuzzy
    },
    @{
        Id=[CheckId]::InstalledMemory;
        Name = "Installed memory >= 16 GB";
        Tags = @('appDev');
        Valid = { (Get-CimInstance -ClassName win32_computersystem).TotalPhysicalMemory -gt 15GB; }
        HasVerboseOutput = $true;
        Optional = $true;
    },
    @{
        Id=[CheckId]::WindowsVersion;
        Name = 'Windows version >= 10.0.17763.0';
        Tags = @('appDev');
        Valid = { ($v.Major -eq 10 -and $v.Minor -eq 0 -and $v.Build -ge 16299); }
    },
    @{
        Id=[CheckId]::DeveloperMode;
        Name = 'Developer mode is on';
        Tags = @('appDev');
        Valid = { try { (Get-WindowsDeveloperLicense).IsValid } catch { $false }; }
        Install = { EnableDevMode };
    },
    @{
        Id=[CheckId]::LongPath;
        Name = 'Long path support is enabled';
        Tags = @('appDev');
        Valid = { try { (Get-ItemProperty HKLM:/SYSTEM/CurrentControlSet/Control/FileSystem -Name LongPathsEnabled).LongPathsEnabled -eq 1} catch { $false }; }
        Install = { Set-ItemProperty HKLM:/SYSTEM/CurrentControlSet/Control/FileSystem -Name LongPathsEnabled -Value 1 -Type DWord;  };
    },
    @{
        Id=[CheckId]::git;
        Name = 'Git';
        Tags = @('rnwDev');
        Valid = { try { (Get-Command git.exe -ErrorAction Stop) -ne $null } catch { $false }; }
        Install = { WinGetInstall Microsoft.Git };
    },
    @{
        Id=[CheckId]::VSUWP;
        Name = "Visual Studio 2022 (>= $vsver) & req. components";
        Tags = @('appDev', 'vs2022');
        Valid = { CheckVS; }
        Install = { InstallVS };
        HasVerboseOutput = $true;
    },
    @{
        Id=[CheckId]::Node;
        Name = 'Node.js (LTS, >= 18.0)';
        Tags = @('appDev');
        Valid = { CheckNode; }
        Install = { WinGetInstall OpenJS.NodeJS.LTS };
        HasVerboseOutput = $true;
    },
    @{
        Id=[CheckId]::Yarn;
        Name = 'Yarn';
        Tags = @('appDev');
        Valid = { CheckYarn }
        Install = { WinGetInstall Yarn.Yarn };
        HasVerboseOutput = $true;
    },
    @{
        Id=[CheckId]::WinAppDriver;
        Name = 'WinAppDriver (>= 1.2.1)';
        Tags = @('rnwDev');
        Valid = { CheckWinAppDriver; }
        Install = {
            $ProgressPreference = 'Ignore';
            $url = "https://github.com/microsoft/WinAppDriver/releases/download/v1.2.1/WindowsApplicationDriver_1.2.1.msi";
            Write-Verbose "Downloading WinAppDriver from $url";
            Invoke-WebRequest -UseBasicParsing $url -OutFile $env:TEMP\WindowsApplicationDriver.msi
            & $env:TEMP\WindowsApplicationDriver.msi /q
        };
        HasVerboseOutput = $true;
        Optional = $true;
    },
    @{
        Id=[CheckId]::MSBuildLogViewer;
        Name = "MSBuild Structured Log Viewer";
        Tags = @('rnwDev');
        Valid = { ( cmd "/c assoc .binlog 2>nul" ) -ne $null; }
        Install = {
            WinGetInstall KirillOsenkov.MSBuildStructuredLogViewer;
            $slv = gci ${env:LocalAppData}\MSBuildStructuredLogViewer\StructuredLogViewer.exe -Recurse | select FullName | Sort-Object -Property FullName -Descending | Select-Object -First 1
            cmd /c "assoc .binlog=MSBuildLog >nul";
            cmd /c "ftype MSBuildLog=$($slv.FullName) %1 >nul";
         };
         Optional = $true;
    },
    @{
        # Install the Windows ADK (Assessment and Deployment Kit) to install the wpt (Windows Performance Toolkit) so we can use wpr (Windows Performance Recorder) for performance analysis
        Id=[CheckId]::WindowsADK;
        Name = 'Windows ADK';
        Tags = @('buildLab');
        Valid = { (Test-Path "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\wpr.exe"); };
        Install = { WinGetInstall Microsoft.WindowsADK };
        Optional = $true;
    },
    @{
        Id=[CheckId]::RNWClone;
        Name = "React-Native-Windows clone";
        Tags = @('clone');
        Valid = { try {
            Test-Path -Path react-native-windows
            } catch { $false }; }
        Install = { & "${env:ProgramFiles}\Git\cmd\git.exe" clone https://github.com/microsoft/react-native-windows.git };
        Optional = $true;
    },
    @{
        Id=[CheckId]::CppWinRTVSIX;
        Name = "C++/WinRT VSIX package";
        Tags = @('rnwDev');
        Valid = { CheckCppWinRT_VSIX; };
        Install = { InstallCppWinRT_VSIX };
        HasVerboseOutput = $true;
        Optional = $true;
    },
    @{
        ID=[CheckId]::DotNetCore;
        Name = ".NET SDK (LTS, = $dotnetver)";
        Tags = @('appDev');
        Valid = { CheckDotNetCore; };
        Install = { WinGetInstall Microsoft.DotNet.SDK.$wingetDotNetVer };
        HasVerboseOutput = $true;
    }
);

function EnsureWinGetForInstall {
    Write-Verbose "Checking for WinGet...";
    try {
        # Check if winget.exe is in PATH
        if (Get-Command "winget.exe" -CommandType Application -ErrorAction Ignore) {
            Write-Verbose "WinGet found in PATH.";
            return;
        }
    } catch { Write-Debug $_ }

    Write-Host "WinGet is required to install dependencies. See https://learn.microsoft.com/en-us/windows/package-manager/winget/ for more information.";
    throw "WinGet needed to install.";
}

function WinGetInstall {
    param(
        [string]$wingetPackage
    )

    EnsureWinGetForInstall;
    Write-Verbose "Executing `winget install `"$wingetPackage`"";
    & winget install "$wingetPackage" --accept-source-agreements --accept-package-agreements
 }
 
function IsElevated {
    return [bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544");
}

if (!($NoPrompt) -and !(IsElevated)) {
    Write-Host "rnw-dependencies - this script must run elevated.";
    if (!$ShellInvocation) { Read-Host 'Press Enter to exit' }
    exit 1
}

$NeedsRerun = 0;
$Installed = 0;
$filteredRequirements = New-Object System.Collections.Generic.List[object];
foreach ($req in $requirements)
{
    if ($Check -eq [CheckId]::All -or $req.Id -eq $Check)
    {
        foreach ($tag in $req.Tags)
        {
            if ($tagsToInclude.Contains($tag))
            {
                $filteredRequirements.Add($req);
                break;
            }
        }
    }
}

if ($ListChecks) {
    foreach ($req in $filteredRequirements)
    {
        if ($req.Optional)
        {
            Write-Host -NoNewline Optional;
        }
        else
        {
            Write-Host -NoNewline Required;
        }
        Write-Host -NoNewline ": ";
        Write-Host -NoNewline $req.Id;
        Write-Host -NoNewline ": ";
        Write-Host $req.Name;
    }
    return;
}

if (Test-Path $MarkerFile) {
    Remove-Item $MarkerFile;
}

foreach ($req in $filteredRequirements)
{
    Write-Host -NoNewline "Checking $($req.Name) ";
    $resultPad = 60 - $req.Name.Length;

    if ($req.HasVerboseOutput -and -$Verbose) {
        # This makes sure the verbose output is one line lower
        Write-Host "";
        $resultPad = 70;
    }

    $valid = $false;
    try {
        $valid = Invoke-Command $req.Valid;
    } catch {
        Write-Warning "There was a problem checking for $($req.Name). Re-run with -Debug for details."
        Write-Debug $_
    }

    if (!$valid) {
        if ($req.Optional) {
            Write-Host -ForegroundColor Yellow " Failed (warn)".PadLeft($resultPad);
        }
        else {
            Write-Host -ForegroundColor Red " Failed".PadLeft($resultPad);
        }
        if ($req.Install) {
            if ($Install -or (!$NoPrompt -and (Read-Host "Do you want to install? [y/N]").ToUpperInvariant() -eq 'Y')) {
                try {
                    $LASTEXITCODE = 0;
                    $outputFromInstall = Invoke-Command $req.Install -ErrorAction Stop;

                    if ($LASTEXITCODE -ne 0) {
                        throw "Last exit code was non-zero: $LASTEXITCODE - $outputFromInstall";
                    }

                    $Installed++;
                    continue; # go to the next item

                } catch {
                    Write-Warning "There was a problem trying to install $($req.Name). Re-run with -Debug for details."
                    Write-Debug $_
                }
            }
        }
        # If we got here, the req needed to be installed but wasn't
        $NeedsRerun += !($req.Optional); # don't let failures from optional components fail the script
    } else {
        Write-Host -ForegroundColor Green " OK".PadLeft($resultPad);
    }
}


if ($Installed -ne 0) {
    Write-Host "Installed $Installed dependencies. You may need to close this window for changes to take effect.";
}

if ($NeedsRerun -ne 0) {
    if ($Verbose) {
        Write-Warning "Some dependencies are not met. Re-run with -Install to install them.";
    } else {
        Write-Warning "Some dependencies are not met. Re-run with -Verbose for details, or use -Install to install them.";
    }
    if (!$ShellInvocation) { Read-Host 'Press Enter to exit' }
    exit 1;
} else {
    Write-Host "All mandatory requirements met.";
    $Tags | Out-File $MarkerFile;
    if (!$ShellInvocation) { Read-Host 'Press Enter to exit' }
    exit 0;
}
# Resolve only the configured SDK; all build orchestration lives there.
$ErrorActionPreference='Stop'
$sdkSetting=$null
foreach($line in Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Settings.R4S')){
    if($line -match '^SDK_ROOT=(.+)$'){$sdkSetting=$Matches[1]}
}
if(!$sdkSetting){throw 'Missing SDK_ROOT in Settings.R4S'}
$sdkPath=[IO.Path]::GetFullPath($sdkSetting.Replace('\',[IO.Path]::DirectorySeparatorChar),$PSScriptRoot)
& (Join-Path $sdkPath 'Tools/BuildModule.ps1') -ModuleRoot $PSScriptRoot -BuildArguments @($args)
exit $LASTEXITCODE

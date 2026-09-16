[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProjectRoot)){$ProjectRoot=Split-Path -Parent $PSScriptRoot}
$source=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'app\WidgetExperience.ps1'),[Text.UTF8Encoding]::new($false,$true))
foreach($statement in @('$language.Foreground=Convert-ToBrush ''#FFF6F9FF''','$item.Foreground=Convert-ToBrush ''#FFF6F9FF''')){
  if(-not $source.Contains($statement)){throw 'Selected language or item foreground is not explicitly bound.'}
}
function Get-Luminance([string]$hex){
  $channels=@(0,2,4|ForEach-Object {
    $v=[Convert]::ToInt32($hex.Substring($_,2),16)/255.0
    if($v -le 0.04045){$v/12.92}else{[math]::Pow(($v+0.055)/1.055,2.4)}
  })
  return 0.2126*$channels[0]+0.7152*$channels[1]+0.0722*$channels[2]
}
$foreground=Get-Luminance 'F6F9FF'
$checks=@(foreach($background in @('0F203B','174A78','245B97')){
  $ratio=($foreground+0.05)/((Get-Luminance $background)+0.05)
  if($ratio -lt 4.5){throw 'Language selector contrast is below 4.5:1.'}
  [pscustomobject]@{background=$background;ratio=[math]::Round($ratio,2)}
})
[pscustomobject]@{success=$true;checks=$checks;scope='Explicit production foreground and default/hover/pressed palette contrast; not a screenshot claim'}|ConvertTo-Json -Depth 4

# Product-owned WPF experience helpers. No network or lifecycle authority lives here.
$script:widgetDragging = $false
$script:widgetTransition = $null
$script:widgetTransitionTarget = $null
$script:widgetTransitionClosedHandler = $null
$script:widgetTransitionClosedWindow = $null
$script:settingsWindow = $null
$script:widgetWords = @{
  'Settings'='설정'; 'Widget settings'='위젯 설정'; 'Add'='추가'; 'Add shortcut'='바로가기 추가'; 'Edit shortcut'='바로가기 편집'
  'Name'='이름'; 'URL or local path'='주소 또는 파일 경로'; 'Save'='저장'; 'Cancel'='취소'; 'Close'='닫기'
  'Opacity'='불투명도'; 'Hover brightness'='마우스를 올리면 밝게'; 'Show hidden'='숨긴 항목 표시'; 'Reset size'='기본 크기로'
  'Always on top'='항상 위에 표시'; 'MIN UI mode'='아이콘만 표시'; 'Start with Windows'='로그인할 때 위젯 실행'
  'Keep on desktop layer when inactive'='사용하지 않을 때 바탕화면 뒤로 보내기'; 'Appearance & media...'='테마와 배경 미디어'
  'Appearance & media'='테마와 배경 미디어'; 'Checking...'='확인 중…'; 'Hover 100%'='올리면 100%'; 'Hover off'='자동 밝기 꺼짐'
  'Language'='언어'; 'Reduce motion'='애니메이션 줄이기'; 'Snap to screen edges'='화면 가장자리에 붙이기'
  'Move window'='누른 채로 위젯 이동'; 'Hide to tray'='트레이로 숨기기'; 'Switch to MIN UI'='아이콘 모드로 전환'; 'Restore full Workspace'='전체 모드로 전환'
  'Built-in icon (optional)'='기본 아이콘'; 'Automatic'='자동'; 'Custom icon image (optional)'='사용자 지정 아이콘'
  'Hover media (optional)'='마우스를 올릴 때 표시할 미디어'; 'Mute hover video'='미디어 소리 끄기'; 'Browse...'='파일 찾기…'
  'Paste image'='이미지 붙여넣기'; 'Retry preview'='미리보기 다시 불러오기'; 'I confirm this preview is the icon I want.'='미리보기를 확인했어요.'
  'Shortcut type'='등록 유형'; 'Ordinary shortcut'='일반 바로가기'; 'Local server'='로컬 서버'; 'Health checks'='서버 상태 확인'
  'Start script'='시작 스크립트'; 'Stop script'='종료 스크립트'; 'Start arguments'='시작 인수'; 'Stop arguments'='종료 인수'; 'Add health check'='상태 확인 주소 추가'
  'Start'='시작'; 'Stop'='종료'; 'Edit'='편집'; 'Hide'='숨기기'; 'Show'='표시'; 'Delete shortcut'='바로가기 삭제'; 'Move earlier'='앞으로 이동'; 'Move later'='뒤로 이동'
  'Refresh status'='상태 새로고침'; '+ Add shortcut'='+ 바로가기 추가'; 'Open Workspace'='위젯 열기'; 'Exit Widget (servers keep running)'='위젯 종료 (서버는 계속 실행)'
  'Remove health check'='상태 확인 주소 제거'; 'Enter unique local health URLs.'='중복되지 않는 로컬 서버 상태 확인 주소를 입력해 주세요.'
  'Choose existing start and stop scripts.'='실제로 존재하는 시작·종료 스크립트를 선택해 주세요.'
  'Theme'='테마'; 'Accent ARGB'='강조색 ARGB'; 'Panel ARGB'='패널색 ARGB'; 'Shortcut card ARGB'='카드색 ARGB'; 'Card hover ARGB'='마우스를 올린 카드색 ARGB'
  'Primary text ARGB'='기본 글자색 ARGB'; 'Background media'='배경 미디어'; 'Background opacity'='배경 불투명도'; 'Mute background video'='배경 영상 소리 끄기'
  'Folder'='폴더'; 'Code'='코드'; 'Terminal'='터미널'; 'Database'='데이터베이스'; 'Document'='문서'; 'Image'='이미지'; 'Video'='영상'; 'Tools'='도구'
  'Calendar'='일정'; 'Launch'='실행'; 'Service'='서버'; 'People'='사용자'; 'Workspace'='작업 공간'; 'Web'='웹'; 'Data'='데이터'; 'Automation'='자동화'; 'Lab'='실험'
  'Server stop was not confirmed. No unowned process was stopped.'='서버 종료를 확인하지 못했습니다. 위젯이 시작하지 않은 프로세스는 종료하지 않았습니다.'
  'Could not start the server. Check its start script and health URLs.'='서버를 시작하지 못했습니다. 시작 스크립트와 상태 확인 주소를 확인해 주세요.'
  'Remove shortcut...'='바로가기 삭제…'; 'Removes only this Workspace entry. The original target stays untouched.'='위젯의 등록 항목만 삭제합니다. 원본 파일과 서버는 유지됩니다.'
  'Starting server...'='서버를 시작하고 상태를 확인하는 중…'; 'Stopping server...'='서버가 안전하게 종료되기를 기다리는 중…'
  'Needs repair'='실행 경로 복구 필요'; 'Unavailable'='확인할 수 없음'; 'Permission blocked'='권한으로 차단됨'
  'Blocked by policy'='정책으로 차단됨'; 'Off · Windows setting'='꺼짐 · Windows 설정'; 'Off · not registered'='꺼짐 · 미등록'
  'Drop to add'='놓아서 추가'; 'Drop apps, files, folders, or URLs here'='앱, 파일, 폴더 또는 주소를 여기에 놓으세요'
  '{0} shortcuts'='바로가기 {0}개'; 'Last checked  {0}'='마지막 확인  {0}'
  '{0} / {1} online'='{1}개 중 {0}개 정상'; 'No health checks'='상태 확인 대상 없음'
  'Online'='정상'; 'Offline'='응답 없음'; 'Checking'='확인 중'
  'Offline · click card to start with bundled Node'='응답 없음 · 카드를 눌러 서버 시작'
  '{0} status: {1}'='{0} 상태: {1}'; 'Open {0}. Status: {1}.'='{0} 열기. 상태: {1}.'
  'Target: {0}. Health status: {1}.'='대상: {0}. 서버 상태: {1}.'
  'Keep Workspace above folders, browsers, and other applications.'='폴더, 브라우저 등 다른 앱보다 위에 표시합니다.'
  'Use a 96 px icon rail that snaps to the nearest screen edge.'='너비 96px의 아이콘 모드로 표시합니다.'
  'Choose a theme, colors, and an image, GIF, video, or YouTube background.'='테마와 색상, 이미지·GIF·영상·YouTube 배경을 설정합니다.'
  'When enabled, Workspace returns behind ordinary apps after it loses focus. Opening it from the shortcut or tray always brings it forward.'='다른 앱으로 전환하면 위젯을 뒤로 보냅니다. 바로가기나 트레이에서 열면 앞으로 표시합니다.'
  'The unpackaged development startup task needs repair.'='위젯의 Windows 시작 작업 경로를 복구해야 합니다.'
  'Windows startup-app status'='Windows 시작 앱 상태'
  'Choose a JavaScript or PowerShell script, or a folder containing package.json.'='JavaScript·PowerShell 스크립트 또는 package.json이 있는 폴더를 선택해 주세요.'
  'For a folder, enter its package script name. For a script file, enter its arguments.'='폴더를 선택했다면 패키지 스크립트 이름을, 파일을 선택했다면 실행 인수를 입력해 주세요.'
  'Choose a trusted JavaScript or PowerShell stop script. The built-in helper stops only a verified Widget-owned server.'='신뢰할 수 있는 JavaScript·PowerShell 종료 스크립트를 선택해 주세요. 기본 스크립트는 위젯이 실행한 것으로 확인된 서버만 종료합니다.'
  'Arguments passed to the configured stop script, without a command shell.'='종료 스크립트에 전달할 인수를 입력해 주세요. 명령 셸 구문은 실행하지 않습니다.'
}

function Initialize-ExperienceState {
  param($WindowState)
  foreach ($pair in @{language='ko-KR'; reduceMotion=$false; edgeSnap=$true}.GetEnumerator()) {
    if ($WindowState.PSObject.Properties.Name -notcontains $pair.Key) {
      $WindowState | Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value
    }
  }
  if ($WindowState.language -notin @('ko-KR','en-US')) { $WindowState.language='ko-KR' }
}

function Initialize-ServerRegistration {
  param($Item)
  if ($Item.PSObject.Properties.Name -notcontains 'registrationType') {
    $kind = if (-not [string]::IsNullOrWhiteSpace([string]$Item.startupTarget)) { 'server' } else { 'ordinary' }
    $Item | Add-Member -NotePropertyName registrationType -NotePropertyValue $kind
  }
  if ($Item.registrationType -notin @('server','ordinary')) { throw 'Unknown shortcut registration type.' }
  if ($Item.PSObject.Properties.Name -notcontains 'healthChecks') {
    $checks = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.health)) { $checks=@([pscustomobject]@{name='Primary';url=[string]$Item.health}) }
    $Item | Add-Member -NotePropertyName healthChecks -NotePropertyValue $checks
  }
  if ($Item.PSObject.Properties.Name -notcontains 'stopTarget') {
    $stop = if ($Item.registrationType -eq 'server') { Join-Path $scriptRoot 'managed-stop.mjs' } else { '' }
    $Item | Add-Member -NotePropertyName stopTarget -NotePropertyValue $stop
  }
  if ($Item.PSObject.Properties.Name -notcontains 'stopArgs') { $Item | Add-Member -NotePropertyName stopArgs -NotePropertyValue '' }
}

function Get-ItemHealthUrls {
  param($Item)
  if ($Item.PSObject.Properties.Name -contains 'registrationType' -and $Item.registrationType -ne 'server') { return }
  $checks = if ($Item.PSObject.Properties.Name -contains 'healthChecks') { @($Item.healthChecks) } else { @([pscustomobject]@{url=[string]$Item.health}) }
  foreach ($check in $checks) {
    if (-not [string]::IsNullOrWhiteSpace([string]$check.url)) { [string]$check.url }
  }
}

function Add-WidgetServerMenuItems {
  param($Menu,$Item)
  if($Item.registrationType -ne 'server'){return}
  $start=New-ContextMenuItem -Header 'Start'; $start.Tag=$Item
  $start.Add_Click({param($sender,$e)
    try { Queue-NodeStart -Item $sender.Tag -OpenWhenHealthy $false -RestartTrackedProcess $false }
    catch {
      Write-RuntimeLog "Server start action failed. $($_.Exception.Message)"
      Show-Toast -Message (Get-WidgetText 'Could not start the server. Check its start script and health URLs.')
    }
  })
  $stop=New-ContextMenuItem -Header 'Stop'; $stop.Tag=$Item
  $stop.Add_Click({param($sender,$e)
    try {
      if(Stop-TrackedLocalServer -Item $sender.Tag -ConfirmForce -AllowMissing){Start-HealthCheck}
      else{Show-Toast -Message (Get-WidgetText 'Server stop was not confirmed. No unowned process was stopped.')}
    } catch {
      Write-RuntimeLog "Server stop action failed. $($_.Exception.Message)"
      Show-Toast -Message (Get-WidgetText 'Server stop was not confirmed. No unowned process was stopped.')
    }
  })
  $Menu.Items.Add($start)|Out-Null; $Menu.Items.Add($stop)|Out-Null
}

function Get-ItemHealthJson {
  param($Item)
  return ConvertTo-Json -InputObject @(Get-ItemHealthUrls $Item) -Compress
}

function Add-HealthEditorRow {
  param($Panel,[string]$Name,[string]$Url)
  $row=[System.Windows.Controls.Grid]::new(); $row.Margin=[System.Windows.Thickness]::new(0,0,0,8)
  foreach($width in @('90','*','30')){
    $col=[System.Windows.Controls.ColumnDefinition]::new()
    $col.Width=[System.Windows.GridLengthConverter]::new().ConvertFromString($width)
    $row.ColumnDefinitions.Add($col)
  }
  $nameBox=[System.Windows.Controls.TextBox]::new(); $nameBox.Text=$Name
  $urlBox=[System.Windows.Controls.TextBox]::new(); $urlBox.Text=$Url
  foreach($box in @($nameBox,$urlBox)){
    $box.Height=34; $box.Padding=[System.Windows.Thickness]::new(6); $box.Margin=[System.Windows.Thickness]::new(0,0,5,0)
    $box.Background=Convert-ToBrush '#FF0F203B'; $box.Foreground=Convert-ToBrush '#FFF6F9FF'
    $box.BorderBrush=Convert-ToBrush '#665C8AC6'
  }
  [System.Windows.Automation.AutomationProperties]::SetName($nameBox,(Get-WidgetText 'Name'))
  [System.Windows.Automation.AutomationProperties]::SetName($urlBox,(Get-WidgetText 'Health checks'))
  [System.Windows.Controls.Grid]::SetColumn($urlBox,1)
  $remove=[System.Windows.Controls.Button]::new(); $remove.Content='−'; $remove.Tag=@{panel=$Panel;row=$row}
  $remove.ToolTip=Get-WidgetText 'Remove health check'
  $remove.Add_Click({param($sender,$e) if($sender.Tag.panel.Children.Count -gt 1){$sender.Tag.panel.Children.Remove($sender.Tag.row)}})
  [System.Windows.Controls.Grid]::SetColumn($remove,2)
  $row.Children.Add($nameBox)|Out-Null; $row.Children.Add($urlBox)|Out-Null; $row.Children.Add($remove)|Out-Null
  $row.Tag=@{name=$nameBox;url=$urlBox}; $Panel.Children.Add($row)|Out-Null
}

function Get-WidgetText {
  param([string]$Text)
  $stateVariable=Get-Variable -Name state -Scope Script -ErrorAction SilentlyContinue
  $windowState=$null
  if($null -ne $stateVariable -and $null -ne $stateVariable.Value -and
    $null -ne $stateVariable.Value.PSObject.Properties['window']){
    $windowState=$stateVariable.Value.window
  }
  if ($null -ne $windowState -and $null -ne $windowState.PSObject.Properties['language'] -and
    $windowState.language -eq 'ko-KR' -and $script:widgetWords.ContainsKey($Text)) {
    return [string]$script:widgetWords[$Text]
  }
  return $Text
}

function Set-WidgetLocalizedTree {
  param($Root)
  if ($null -eq $Root -or $Root -is [string]) { return }
  foreach ($property in @('Text','Content','Header','ToolTip','Title')) {
    if ($Root -is [System.Windows.Controls.TextBox]) { continue }
    $p = $Root.PSObject.Properties[$property]
    if ($null -ne $p -and $p.Value -is [string]) {
      $source=[string]$p.Value
      if (-not $script:widgetWords.ContainsKey($source)) {
        $matches=@($script:widgetWords.Keys | Where-Object {$script:widgetWords[$_] -ceq [string]$p.Value} | Select-Object -First 1)
        if($matches.Count -eq 0){continue}
        $source=[string]$matches[0]
      }
      $Root.$property = Get-WidgetText $source
    }
  }
  if ($Root -is [System.Windows.DependencyObject]) {
    foreach($property in @([System.Windows.Automation.AutomationProperties]::NameProperty,[System.Windows.Automation.AutomationProperties]::HelpTextProperty)) {
      $source=[string]$Root.GetValue($property)
      if(-not $script:widgetWords.ContainsKey($source)) {
        $matches=@($script:widgetWords.Keys | Where-Object {$script:widgetWords[$_] -ceq $source} | Select-Object -First 1)
        if($matches.Count -eq 0){continue}
        $source=[string]$matches[0]
      }
      $Root.SetValue($property,(Get-WidgetText $source))
    }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Root)) {
      if ($child -is [System.Windows.DependencyObject]) { Set-WidgetLocalizedTree $child }
    }
  }
}

function Test-WidgetInteractiveOrigin {
  param($Source)
  $node=$Source
  while($null -ne $node){
    if($node -is [System.Windows.Controls.Primitives.ButtonBase] -or $node -is [System.Windows.Controls.TextBox] -or $node -is [System.Windows.Controls.Primitives.Selector] -or $node -is [System.Windows.Controls.Primitives.RangeBase]){return $true}
    if($node -is [System.Windows.Media.Visual]){$node=[System.Windows.Media.VisualTreeHelper]::GetParent($node)}
    elseif($node -is [System.Windows.FrameworkContentElement]){$node=$node.Parent}
    else{$node=[System.Windows.LogicalTreeHelper]::GetParent($node)}
  }
  return $false
}

function Update-WidgetLanguage {
  Set-WidgetLocalizedTree $script:toolbar
  Set-WidgetLocalizedTree $script:footer
  Set-WidgetLocalizedTree $script:addShortcutButton
  Set-WidgetLocalizedTree $script:settingsWindow
  foreach($entry in $script:trayMenu.Items){
    if($entry -is [System.Windows.Forms.ToolStripMenuItem]){
      foreach($key in @('Open Workspace','Exit Widget (servers keep running)')){
        if($entry.Text -eq $key -or $entry.Text -eq $script:widgetWords[$key]){$entry.Text=Get-WidgetText $key}
      }
    }
  }
  Render-Items
}

function Add-WidgetFilePicker {
  param($Panel,$TextBox,[string]$Filter)
  $button = [System.Windows.Controls.Button]::new()
  $button.Content = Get-WidgetText 'Browse...'
  $button.Height=30; $button.Padding=[System.Windows.Thickness]::new(12,4,12,4)
  $button.HorizontalAlignment='Left'; $button.Margin=[System.Windows.Thickness]::new(0,-6,0,12)
  $button.Background=Convert-ToBrush '#FF223149'; $button.Foreground=Convert-ToBrush '#FFF6F9FF'
  $button.Template=New-ButtonTemplate -HoverBackground '#FF304663' -PressedBackground '#FF1B2C42'
  $button.Tag=@{box=$TextBox;filter=$Filter}
  $button.Add_Click({
    param($sender,$eventArgs)
    $picker=[Microsoft.Win32.OpenFileDialog]::new()
    $picker.Filter=$sender.Tag.filter; $picker.CheckFileExists=$true; $picker.Multiselect=$false
    $owner=[System.Windows.Window]::GetWindow($sender)
    if ($picker.ShowDialog($owner)) { $sender.Tag.box.Text=$picker.FileName }
  })
  $Panel.Children.Add($button) | Out-Null
}

function Test-WidgetMotionEnabled {
  return (-not [bool]$script:state.window.reduceMotion -and [System.Windows.SystemParameters]::ClientAreaAnimation)
}

function Restore-WidgetBoundsTransitionTarget {
  if ($null -eq $script:widgetTransitionTarget) { return $false }
  foreach($property in @('Left','Top','Width','Height')) {
    $dp=[System.Windows.Window]::("${property}Property")
    $script:window.BeginAnimation($dp,$null)
    $script:window.SetValue($dp,[double]$script:widgetTransitionTarget[$property])
  }
  return $true
}

function Complete-WidgetBoundsTransition {
  param(
    [bool]$Settled,
    [string]$Reason
  )

  $target=$script:widgetTransitionTarget
  if($null -eq $target){return $false}
  if($null -ne $script:widgetTransition){$script:widgetTransition.Stop()}
  [void](Restore-WidgetBoundsTransitionTarget)
  $script:widgetTransition=$null
  $script:widgetTransitionTarget=$null
  if($null -ne $target.OnCommitted){
    & $target.OnCommitted $Settled $Reason
  }
  return $true
}

function Cancel-WidgetBoundsTransition {
  param([string]$Reason)
  if(Complete-WidgetBoundsTransition -Settled:$false -Reason $Reason){
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
      Write-RuntimeLog "Widget bounds transition cancelled: $Reason"
    }
    return $true
  }
  return $false
}

function Supersede-WidgetBoundsTransition {
  if($null -eq $script:widgetTransitionTarget){return $false}
  if($null -ne $script:widgetTransition){$script:widgetTransition.Stop()}
  # Retain the rendered value as the next transition's base. This intentionally
  # does not invoke the prior completion callback or snap to its old target.
  foreach($property in @('Left','Top','Width','Height')) {
    $dp=[System.Windows.Window]::("${property}Property")
    $current=[double]$script:window.GetValue($dp)
    $script:window.BeginAnimation($dp,$null)
    $script:window.SetValue($dp,$current)
  }
  $script:widgetTransition=$null
  $script:widgetTransitionTarget=$null
  return $true
}

function Start-WidgetBoundsTransition {
  param(
    [double]$FromLeft,
    [double]$FromTop,
    [double]$FromWidth,
    [double]$FromHeight,
    [double]$TargetLeft,
    [double]$TargetTop,
    [double]$TargetWidth,
    [double]$TargetHeight,
    [scriptblock]$OnCommitted
  )
  if($null -ne $script:widgetTransitionTarget){
    Supersede-WidgetBoundsTransition | Out-Null
  }
  $script:widgetTransitionTarget=[ordered]@{
    Left=$TargetLeft; Top=$TargetTop; Width=$TargetWidth; Height=$TargetHeight; OnCommitted=$OnCommitted
  }
  if (-not (Test-WidgetMotionEnabled) -or -not $script:window.IsVisible) {
    Complete-WidgetBoundsTransition -Settled:$false -Reason 'motion disabled or window hidden' | Out-Null
    return
  }
  if ($script:widgetTransitionClosedWindow -ne $script:window) {
    if ($null -ne $script:widgetTransitionClosedWindow -and $null -ne $script:widgetTransitionClosedHandler) {
      $script:widgetTransitionClosedWindow.remove_Closed($script:widgetTransitionClosedHandler)
    }
    $script:widgetTransitionClosedHandler=[EventHandler]{ Cancel-WidgetBoundsTransition -Reason 'window closed' }
    $script:window.add_Closed($script:widgetTransitionClosedHandler)
    $script:widgetTransitionClosedWindow=$script:window
  }
  $target=$script:widgetTransitionTarget
  # Keep only a broad transitional range while animated. The exact destination
  # constraints and values are committed after the clocks have been removed.
  $script:window.MinWidth=$script:minUiWidth; $script:window.MaxWidth=1000
  $duration=[System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
  $from=@{Left=$FromLeft;Top=$FromTop;Width=$FromWidth;Height=$FromHeight}
  foreach ($property in @('Left','Top','Width','Height')) {
    $animation=[System.Windows.Media.Animation.DoubleAnimation]::new([double]$from[$property],[double]$target[$property],$duration)
    $ease=[System.Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode='EaseOut'; $animation.EasingFunction=$ease
    $animation.FillBehavior='HoldEnd'
    $dp=[System.Windows.Window]::("${property}Property")
    $script:window.BeginAnimation($dp,$animation,[System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
  }
  $script:widgetTransition=[System.Windows.Threading.DispatcherTimer]::new()
  $script:widgetTransition.Interval=[TimeSpan]::FromMilliseconds(240)
  $script:widgetTransition.Tag=[ordered]@{settling=$false;attempts=0;stableTicks=0;settleStarted=$null}
  $script:widgetTransition.Add_Tick({
    param($sender,$eventArgs)
    if ($sender -ne $script:widgetTransition) { $sender.Stop(); return }
    if($null -eq $script:widgetTransitionTarget){$sender.Stop();return}
    if(-not (Test-WidgetMotionEnabled) -or -not $script:window.IsVisible){
      Cancel-WidgetBoundsTransition -Reason 'motion disabled or window hidden while settling'
      return
    }
    if(-not [bool]$sender.Tag.settling){
      [void](Restore-WidgetBoundsTransitionTarget)
      $sender.Tag.settling=$true
      $sender.Tag.settleStarted=[Diagnostics.Stopwatch]::StartNew()
      $sender.Interval=[TimeSpan]::FromMilliseconds(20)
      return
    }
    $sender.Tag.attempts++
    $stable=$true
    foreach($property in @('Left','Top','Width','Height')) {
      $dp=[System.Windows.Window]::("${property}Property")
      $actual=[double]$script:window.GetAnimationBaseValue($dp)
      if([math]::Abs($actual-[double]$script:widgetTransitionTarget[$property]) -ge 0.001){$stable=$false;break}
    }
    if($stable){$sender.Tag.stableTicks++}
    else {
      $sender.Tag.stableTicks=0
      [void](Restore-WidgetBoundsTransitionTarget)
    }
    if($sender.Tag.stableTicks -ge 2){
      Complete-WidgetBoundsTransition -Settled:$true -Reason 'settled' | Out-Null
    } elseif($sender.Tag.attempts -ge 16 -or $sender.Tag.settleStarted.ElapsedMilliseconds -ge 1000) {
      Complete-WidgetBoundsTransition -Settled:$false -Reason 'settle deadline' | Out-Null
      Write-RuntimeLog 'Widget bounds transition did not stabilize before its settle deadline; explicit target was restored through its completion callback.'
    }
  })
  $script:widgetTransition.Start()
}

function Show-WidgetSettings {
  # Reuse existing settings controls and their tested event handlers in a single,
  # opaque, independently sized window; compact mode never clips these controls.
  if ($null -ne $script:settingsWindow) { $script:settingsWindow.Activate() | Out-Null; return }
  $dialog=[System.Windows.Window]::new(); $script:settingsWindow=$dialog
  $dialog.Title=Get-WidgetText 'Settings'; $dialog.Owner=$script:window
  $dialog.Width=550; $dialog.Height=570; $dialog.MinWidth=470; $dialog.MinHeight=380
  $dialog.WindowStartupLocation='CenterOwner'; $dialog.ShowInTaskbar=$false
  $dialog.Background=Convert-ToBrush '#FF16181D'; $dialog.Foreground=Convert-ToBrush '#FFF6F9FF'
  $scroll=[System.Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'
  $stack=[System.Windows.Controls.StackPanel]::new(); $stack.Margin=[System.Windows.Thickness]::new(22)
  $scroll.Content=$stack; $dialog.Content=$scroll
  $title=New-TextBlock -Text (Get-WidgetText 'Settings') -Size 22 -Weight SemiBold
  $title.Margin=[System.Windows.Thickness]::new(0,0,0,20); $stack.Children.Add($title)|Out-Null
  $opacityContent=$script:opacityPanel.Child; $script:opacityPanel.Child=$null
  $settingsContent=$script:settingsPanel.Child; $script:settingsPanel.Child=$null
  $opacityContent.Margin=[System.Windows.Thickness]::new(0,0,0,20)
  $stack.Children.Add($opacityContent)|Out-Null; $stack.Children.Add($settingsContent)|Out-Null
  $languageLabel=New-TextBlock -Text (Get-WidgetText 'Language') -Size 12
  $languageLabel.Margin=[System.Windows.Thickness]::new(0,22,0,8); $stack.Children.Add($languageLabel)|Out-Null
  $language=[System.Windows.Controls.ComboBox]::new(); $language.Height=36
  $language.Foreground=Convert-ToBrush '#FFF6F9FF'
  $language.Background=Convert-ToBrush '#FF0F203B'
  $language.BorderBrush=Convert-ToBrush '#FF5C8AC6'
  Set-DialogComboBoxStyle $language
  foreach ($entry in @(@('ko-KR','한국어'),@('en-US','English'))) {
    $item=[System.Windows.Controls.ComboBoxItem]::new(); $item.Tag=$entry[0]; $item.Content=$entry[1]
    $item.Foreground=Convert-ToBrush '#FFF6F9FF'
    $language.Items.Add($item)|Out-Null
    if($script:state.window.language -eq $entry[0]){$language.SelectedItem=$item}
  }
  $language.Add_SelectionChanged({
    param($sender,$eventArgs)
    if($null -eq $sender.SelectedItem){return}
    $script:state.window.language=[string]$sender.SelectedItem.Tag
    Update-WidgetLanguage
    Save-State | Out-Null
  })
  $stack.Children.Add($language)|Out-Null
  foreach($option in @(@('Reduce motion','reduceMotion'),@('Snap to screen edges','edgeSnap'))) {
    $check=[System.Windows.Controls.CheckBox]::new(); $check.Content=$option[0]; $check.Tag=$option[1]
    $check.Foreground=Convert-ToBrush '#FFE0E5ED'; $check.Margin=[System.Windows.Thickness]::new(0,14,0,0)
    $check.IsChecked=[bool]$script:state.window.($option[1])
    $check.Add_Click({param($sender,$e) $script:state.window.($sender.Tag)=[bool]$sender.IsChecked; Save-State | Out-Null})
    $stack.Children.Add($check)|Out-Null
  }
  $close=[System.Windows.Controls.Button]::new(); $close.Content='Close'; $close.Height=34
  $close.Background=Convert-ToBrush '#FF223149'; $close.Foreground=Convert-ToBrush '#FFF6F9FF'
  $close.BorderBrush=Convert-ToBrush '#FF53729B'
  $close.Template=New-ButtonTemplate -HoverBackground '#FF304663' -PressedBackground '#FF1B2C42'
  $close.Margin=[System.Windows.Thickness]::new(0,20,0,0); $close.IsCancel=$true
  $close.Add_Click({$script:settingsWindow.Close()}); $stack.Children.Add($close)|Out-Null
  $dialog.Tag=@{stack=$stack;opacity=$opacityContent;settings=$settingsContent}
  $dialog.Add_Closed({param($sender,$e)
    $sender.Tag.stack.Children.Remove($sender.Tag.opacity)
    $sender.Tag.stack.Children.Remove($sender.Tag.settings)
    $script:opacityPanel.Child=$sender.Tag.opacity; $script:settingsPanel.Child=$sender.Tag.settings
    $script:settingsWindow=$null
  })
  Set-WidgetLocalizedTree $dialog
  if(-not $script:autostartBusy){Start-AutostartOperation -Action Get}
  $dialog.ShowDialog()|Out-Null
}

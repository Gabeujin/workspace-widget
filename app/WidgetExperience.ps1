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
  'General'='일반'; 'Apply'='적용'; 'Clear media'='미디어 지우기'; 'Custom'='사용자 지정'; 'Midnight'='미드나이트'; 'Neon'='네온'; 'Sakura'='사쿠라'; 'Monochrome'='모노크롬'
  'Use a preset or custom colors, then add a local image, GIF, video, or YouTube poster as the widget background.'='기본 테마나 사용자 지정 색상을 선택한 뒤, 로컬 이미지·GIF·영상 또는 YouTube 포스터를 위젯 배경으로 추가하세요.'
  'Used by the Custom theme for primary labels and shortcut names.'='사용자 지정 테마의 기본 레이블과 바로가기 이름에 사용합니다.'
  'Local image/GIF/video, public HTTPS image, or YouTube link.'='로컬 이미지·GIF·영상, 공개 HTTPS 이미지 또는 YouTube 링크를 입력하세요.'
  'Only use media you trust and have permission to display. YouTube links display a poster in the widget background; inline playback is only available for shortcut hover media.'='신뢰할 수 있고 표시 권한이 있는 미디어만 사용하세요. YouTube 링크는 위젯 배경에 포스터로 표시하며, 바로가기 위에 마우스를 올릴 때만 위젯 안에서 영상을 재생할 수 있습니다.'
  'Choose Workspace background media'='위젯 배경 미디어 선택'; 'Supported media'='지원하는 미디어'; 'Images'='이미지'; 'Videos'='영상'; 'All files'='모든 파일'
  'All colors must be valid #AARRGGBB or named WPF colors.'='모든 색상은 올바른 #AARRGGBB 값 또는 WPF 색상 이름이어야 합니다.'
  'Background media must be a supported local file, public HTTPS image, or YouTube link.'='배경 미디어는 지원하는 로컬 파일, 공개 HTTPS 이미지 또는 YouTube 링크여야 합니다.'
  'Could not apply appearance settings. Your current appearance was restored.'='테마와 배경 설정을 적용하지 못했습니다. 이전 설정으로 되돌렸습니다.'
  'Folder'='폴더'; 'Code'='코드'; 'Terminal'='터미널'; 'Database'='데이터베이스'; 'Document'='문서'; 'Image'='이미지'; 'Video'='영상'; 'Tools'='도구'
  'Calendar'='일정'; 'Launch'='실행'; 'Service'='서버'; 'People'='사용자'; 'Workspace'='작업 공간'; 'Web'='웹'; 'Data'='데이터'; 'Automation'='자동화'; 'Lab'='실험'
  'Server stop was not confirmed. No unowned process was stopped.'='서버 종료를 확인하지 못했습니다. 위젯이 시작하지 않은 프로세스는 종료하지 않았습니다.'
  'Could not start the server. Check its start script and health URLs.'='서버를 시작하지 못했습니다. 시작 스크립트와 상태 확인 주소를 확인해 주세요.'
  'Remove shortcut...'='바로가기 삭제…'; 'Removes only this Workspace entry. The original target stays untouched.'='위젯의 등록 항목만 삭제합니다. 원본 파일과 서버는 유지됩니다.'
  'Starting server...'='서버를 시작하고 상태를 확인하는 중…'; 'Stopping server...'='서버가 안전하게 종료되기를 기다리는 중…'
  'Needs repair'='실행 경로 복구 필요'; 'Unavailable'='확인할 수 없음'; 'Permission blocked'='권한으로 차단됨'
  'Blocked by policy'='정책으로 차단됨'; 'Off · Windows setting'='꺼짐 · Windows 설정'; 'Off · not registered'='꺼짐 · 미등록'
  'On'='켜짐'; 'Off'='꺼짐'; 'On · policy'='켜짐 · 정책'; 'Turn this on to start Workspace Widget after Windows sign-in.'='Windows에 로그인한 뒤 위젯을 실행하려면 켜세요.'
  'Drop to add'='놓아서 추가'; 'Drop apps, files, folders, or URLs here'='앱, 파일, 폴더 또는 주소를 여기에 놓으세요'
  '{0} shortcuts'='바로가기 {0}개'; 'Last checked  {0}'='마지막 확인  {0}'
  '{0} / {1} online'='{1}개 중 {0}개 정상'; 'No health checks'='상태 확인 대상 없음'
  'Online'='정상'; 'Offline'='응답 없음'; 'Checking'='확인 중'
  'Offline · click card to start with bundled Node'='응답 없음 · 카드를 눌러 서버 시작'
  '{0} status: {1}'='{0} 상태: {1}'; 'Open {0}. Status: {1}.'='{0} 열기. 상태: {1}.'
  'Target: {0}. Health status: {1}.'='대상: {0}. 서버 상태: {1}.'
  'Keep Workspace above folders, browsers, and other applications.'='폴더, 브라우저 등 다른 앱보다 위에 표시합니다.'
  'Use a 96 px icon rail that can snap to the nearest screen edge when edge snapping is enabled.'='너비 96px의 아이콘 모드로 표시합니다. 화면 가장자리에 붙이기를 켜면 가장 가까운 화면 가장자리에 맞춥니다.'
  'Choose a theme, colors, and an image, GIF, video, or YouTube background.'='테마와 색상, 이미지·GIF·영상·YouTube 배경을 설정합니다.'
  'When enabled, Workspace returns behind ordinary apps after it loses focus. Opening it from the shortcut or tray always brings it forward.'='다른 앱으로 전환하면 위젯을 뒤로 보냅니다. 바로가기나 트레이에서 열면 앞으로 표시합니다.'
  'The unpackaged development startup task needs repair.'='위젯의 Windows 시작 작업 경로를 복구해야 합니다.'
  'Windows startup-app status'='Windows 시작 앱 상태'
  'Choose a JavaScript or PowerShell script, or a folder containing package.json.'='JavaScript·PowerShell 스크립트 또는 package.json이 있는 폴더를 선택해 주세요.'
  'For a folder, enter its package script name. For a script file, enter its arguments.'='폴더를 선택했다면 패키지 스크립트 이름을, 파일을 선택했다면 실행 인수를 입력해 주세요.'
  'Choose a trusted JavaScript or PowerShell stop script. The built-in helper stops only a verified Widget-owned server.'='신뢰할 수 있는 JavaScript·PowerShell 종료 스크립트를 선택해 주세요. 기본 스크립트는 위젯이 실행한 것으로 확인된 서버만 종료합니다.'
  'Arguments passed to the configured stop script, without a command shell.'='종료 스크립트에 전달할 인수를 입력해 주세요. 명령 셸 구문은 실행하지 않습니다.'
  '{0} is already online'='{0} 서버가 이미 실행 중입니다.'; 'Restart not performed: stop was not confirmed for {0}'='{0} 서버의 종료를 확인하지 못해 다시 시작하지 않았습니다.'
  'Starting {0} with bundled Node'='번들 Node로 {0} 서버를 시작하는 중입니다.'; 'Restarting {0} with bundled Node'='번들 Node로 {0} 서버를 다시 시작하는 중입니다.'
  'Checking {0} before start'='{0} 서버를 시작하기 전에 상태를 확인하는 중입니다.'; 'Checking {0} before restart'='{0} 서버를 다시 시작하기 전에 상태를 확인하는 중입니다.'
  'Stop not confirmed for {0}. Check server status and the runtime log.'='{0} 서버의 종료를 확인하지 못했습니다. 서버 상태와 런타임 로그를 확인해 주세요.'; 'Stopped {0}'='{0} 서버를 종료했습니다.'
  '{0} is ready'='{0} 서버가 준비되었습니다.'; 'Could not open {0}'='{0} 서버를 열지 못했습니다.'; '{0} is online'='{0} 서버가 정상입니다.'
  'Restart canceled for {0}'='{0} 서버의 다시 시작을 취소했습니다.'; 'Could not start {0}'='{0} 서버를 시작하지 못했습니다.'; '{0} did not become healthy'='{0} 서버가 정상 상태가 되지 않았습니다.'
  'Stop server...'='서버 종료…'; 'Server ownership not verified'='서버 소유권을 확인하지 못했습니다.'; 'Server is online'='서버가 정상입니다.'
  'Restart server'='서버 다시 시작'; 'Check and restart server'='서버 상태 확인 후 다시 시작'; 'Checking server ownership...'='서버 소유권 확인 중…'
  'Ownership is verified against the saved launch and live supervisor, not the application code. Stop requests cleanup; a verified force-stop needs confirmation after timeout.'='앱 코드 자체가 아니라 저장된 실행 정보와 실행 중인 서버 관리 프로세스로 소유권을 확인했습니다. 종료 요청은 정리를 시도하며, 시간 초과 뒤 강제 종료는 확인이 필요합니다.'
  'This server was started outside the current verified launch contract. Use its own controls to stop it.'='이 서버는 현재 확인된 실행 계약 밖에서 시작되었습니다. 해당 서버의 자체 제어 기능으로 종료하세요.'
  'The configured health endpoint is responding.'='구성된 상태 확인 주소가 응답하고 있습니다.'; 'Runs the trusted Node start target and waits for the health endpoint.'='신뢰할 수 있는 Node 시작 대상을 실행하고 상태 확인 주소를 기다립니다.'
  'Checking the saved launch and its live supervisor.'='저장된 실행 정보와 실행 중인 서버 관리 프로세스를 확인하는 중입니다.'
  'Workspace is still running'='위젯이 계속 실행 중입니다.'
  'Choose Exit Widget in the tray to close the launcher. Servers keep running; stop them from their cards.'='트레이에서 위젯 종료를 선택하면 실행기를 닫습니다. 서버는 계속 실행되므로 카드에서 종료하세요.'
  'Background video could not be played on this PC.'='이 PC에서는 배경 영상을 재생할 수 없습니다.'
  'Workspace Widget host is missing'='위젯 호스트를 찾을 수 없습니다.'; 'Could not update Windows startup'='Windows 시작 설정을 업데이트하지 못했습니다.'
  'Windows startup check timed out'='Windows 시작 설정 확인 시간이 초과되었습니다.'; 'Starts with Windows at sign-in'='Windows 로그인 시 위젯을 시작합니다.'
  'Windows startup remains off'='로그인 시 위젯 자동 실행이 꺼진 상태로 유지됩니다.'; 'Windows startup is off'='로그인 시 위젯 자동 실행이 꺼져 있습니다.'
  'Autostart needs installer repair'='자동 시작을 사용하려면 설치를 복구해야 합니다.'; 'Could not read Windows startup status'='Windows 시작 상태를 읽지 못했습니다.'
  'Workspace Widget starts after Windows sign-in. You can also control this in Windows Startup Apps settings.'='Windows 로그인 후 위젯이 시작됩니다. Windows 시작 앱 설정에서도 관리할 수 있습니다.'
  'A Windows or organization policy keeps this startup entry enabled.'='Windows 또는 조직 정책으로 이 시작 항목이 켜져 있습니다.'
  'Windows Startup Apps settings disabled Workspace Widget. Re-enable it from Settings > Apps > Startup.'='Windows 시작 앱 설정에서 위젯을 껐습니다. 설정 > 앱 > 시작 프로그램에서 다시 켜세요.'
  'A Windows or organization policy controls this startup entry.'='Windows 또는 조직 정책에서 이 시작 항목을 관리합니다.'
  'Turn this on to register Workspace Widget for Windows sign-in.'='Windows 로그인 시 위젯을 실행하도록 등록하려면 켜세요.'
  'Windows did not allow this account to inspect or change startup.'='Windows에서 이 계정의 시작 설정 확인 또는 변경을 허용하지 않았습니다.'
  'Autostart status is unavailable.'='자동 시작 상태를 확인할 수 없습니다.'
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
    if ($property -eq 'Text' -and $Root -is [System.Windows.Controls.TextBox]) { continue }
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

function Set-WidgetAppearanceDraftError {
  param($Context,[string]$Message)
  $Context.controls.error.Text=Get-WidgetText $Message
  $Context.controls.error.Visibility=if([string]::IsNullOrWhiteSpace($Message)){[System.Windows.Visibility]::Collapsed}else{[System.Windows.Visibility]::Visible}
}

function Reset-WidgetAppearanceSettingsDraft {
  param($Context)
  $appearance=$script:state.window.appearance
  foreach($item in $Context.controls.theme.Items){
    if([string]$item.Tag -eq [string]$appearance.theme){$Context.controls.theme.SelectedItem=$item;break}
  }
  if($null -eq $Context.controls.theme.SelectedItem){$Context.controls.theme.SelectedIndex=0}
  foreach($field in @('accent','panel','card','cardHover','text')){
    $property=@{accent='accentColor';panel='panelColor';card='cardColor';cardHover='cardHoverColor';text='textColor'}[$field]
    $Context.controls[$field].Text=[string]$appearance.$property
  }
  $Context.controls.media.Text=[string]$appearance.backgroundMedia
  $Context.controls.opacity.Value=[math]::Max(0.05,[math]::Min(1.0,[double]$appearance.backgroundMediaOpacity))
  $Context.controls.mute.IsChecked=[bool]$appearance.backgroundVideoMuted
  Set-WidgetAppearanceDraftError -Context $Context -Message ''
}

function Apply-WidgetAppearanceSettingsDraft {
  param($Context)
  $controls=$Context.controls
  $selectedTheme=if($null -eq $controls.theme.SelectedItem){''}else{[string]$controls.theme.SelectedItem.Tag}
  try {
    foreach($field in @('accent','panel','card','cardHover','text')){Convert-ToBrush $controls[$field].Text.Trim()|Out-Null}
  } catch {
    Set-WidgetAppearanceDraftError -Context $Context -Message 'All colors must be valid #AARRGGBB or named WPF colors.'
    return $false
  }
  $backgroundMedia=$controls.media.Text.Trim()
  try {$backgroundKind=Resolve-MediaKind -Source $backgroundMedia -ConfiguredKind 'auto'} catch {
    Set-WidgetAppearanceDraftError -Context $Context -Message 'Background media must be a supported local file, public HTTPS image, or YouTube link.'
    return $false
  }
  if(-not [string]::IsNullOrWhiteSpace($backgroundMedia) -and -not (Test-MediaSource -Source $backgroundMedia -ConfiguredKind $backgroundKind)){
    Set-WidgetAppearanceDraftError -Context $Context -Message 'Background media must be a supported local file, public HTTPS image, or YouTube link.'
    return $false
  }
  $values=@($controls.accent.Text.Trim(),$controls.panel.Text.Trim(),$controls.card.Text.Trim(),$controls.cardHover.Text.Trim(),$controls.text.Text.Trim())
  if($selectedTheme -ne 'Custom' -and $Context.presets.ContainsKey($selectedTheme) -and [string]::Join('|',$values) -cne [string]::Join('|',$Context.presets[$selectedTheme])){$selectedTheme='Custom'}
  $appearance=$script:state.window.appearance
  $prior=@{}
  foreach($property in @('theme','accentColor','panelColor','cardColor','cardHoverColor','textColor','backgroundMedia','backgroundMediaKind','backgroundMediaOpacity','backgroundVideoMuted')){$prior[$property]=$appearance.$property}
  try {
    $appearance.theme=$selectedTheme; $appearance.accentColor=$values[0]; $appearance.panelColor=$values[1]; $appearance.cardColor=$values[2]; $appearance.cardHoverColor=$values[3]; $appearance.textColor=$values[4]
    $appearance.backgroundMedia=$backgroundMedia; $appearance.backgroundMediaKind=$backgroundKind; $appearance.backgroundMediaOpacity=[math]::Round([double]$controls.opacity.Value,2); $appearance.backgroundVideoMuted=[bool]$controls.mute.IsChecked
    Apply-Appearance
    if(-not (Save-State)){throw 'State save did not complete.'}
  } catch {
    foreach($property in $prior.Keys){$appearance.$property=$prior[$property]}
    try{Apply-Appearance}catch{}
    Write-RuntimeLog "Appearance settings apply failed. $($_.Exception.Message)"
    Set-WidgetAppearanceDraftError -Context $Context -Message 'Could not apply appearance settings. Your current appearance was restored.'
    return $false
  }
  # Re-read the applied theme as well as colors: editing a preset promotes it
  # to Custom, and the selector must not keep showing the old preset name.
  Reset-WidgetAppearanceSettingsDraft -Context $Context
  return $true
}

function New-WidgetAppearanceSettingsPanel {
  param([Parameter(Mandatory=$true)]$Dialog)
  $panel=[System.Windows.Controls.StackPanel]::new()
  $panel.Margin=[System.Windows.Thickness]::new(2,4,2,4)
  $presets=@{
    Midnight=@('#FF3E8BFF','#EE09162B','#E80F203B','#F2162F56','#FFF6F9FF')
    Neon=@('#FF30F2FF','#F0050812','#E8111230','#F5230B4C','#FFF7FEFF')
    Sakura=@('#FFFF6FAE','#F01D1025','#EA35172F','#F34A2147','#FFFFF6FB')
    Monochrome=@('#FFAFC7FF','#F016181D','#EA23262D','#F2383D47','#FFF7F8FA')
  }
  $controls=@{}
  $title=New-TextBlock -Text (Get-WidgetText 'Appearance & media') -Size 18 -Weight SemiBold; $title.Margin=[System.Windows.Thickness]::new(0,0,0,5); $panel.Children.Add($title)|Out-Null
  $intro=New-TextBlock -Text (Get-WidgetText 'Use a preset or custom colors, then add a local image, GIF, video, or YouTube poster as the widget background.') -Size 12 -Color '#FFA9B9D1'; $intro.TextWrapping='Wrap'; $intro.Margin=[System.Windows.Thickness]::new(0,0,0,15); $panel.Children.Add($intro)|Out-Null
  $themeLabel=New-TextBlock -Text (Get-WidgetText 'Theme') -Size 11 -Color '#FFA9B9D1'; $themeLabel.Margin=[System.Windows.Thickness]::new(0,0,0,5); $panel.Children.Add($themeLabel)|Out-Null
  $theme=[System.Windows.Controls.ComboBox]::new(); $theme.Height=34; $theme.Margin=[System.Windows.Thickness]::new(0,0,0,12); $theme.Background=Convert-ToBrush '#FF0F203B'; $theme.Foreground=Convert-ToBrush '#FFF6F9FF'; $theme.MaxDropDownHeight=294; Set-DialogComboBoxStyle $theme
  foreach($id in @('Midnight','Neon','Sakura','Monochrome','Custom')){$item=[System.Windows.Controls.ComboBoxItem]::new();$item.Tag=$id;$item.Content=Get-WidgetText $id;$item.Foreground=Convert-ToBrush '#FFF6F9FF';$theme.Items.Add($item)|Out-Null}
  $controls.theme=$theme; $panel.Children.Add($theme)|Out-Null
  $colorMap=@(@('accent','Accent ARGB'),@('panel','Panel ARGB'),@('card','Shortcut card ARGB'),@('cardHover','Card hover ARGB'),@('text','Primary text ARGB'))
  foreach($entry in $colorMap){
    $label=New-TextBlock -Text (Get-WidgetText $entry[1]) -Size 11 -Color '#FFA9B9D1'; $label.Margin=[System.Windows.Thickness]::new(0,0,0,4); $panel.Children.Add($label)|Out-Null
    $box=[System.Windows.Controls.TextBox]::new();$box.Height=32;$box.Padding=[System.Windows.Thickness]::new(8,5,8,5);$box.Margin=[System.Windows.Thickness]::new(0,0,0,9);$box.Background=Convert-ToBrush '#FF0F203B';$box.Foreground=Convert-ToBrush '#FFF6F9FF';$box.BorderBrush=Convert-ToBrush '#665C8AC6';$controls[$entry[0]]=$box;$panel.Children.Add($box)|Out-Null
  }
  $mediaLabel=New-TextBlock -Text (Get-WidgetText 'Background media') -Size 11 -Color '#FFA9B9D1';$mediaLabel.Margin=[System.Windows.Thickness]::new(0,4,0,5);$panel.Children.Add($mediaLabel)|Out-Null
  $mediaGrid=[System.Windows.Controls.Grid]::new();$mediaGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())|Out-Null;$browseColumn=[System.Windows.Controls.ColumnDefinition]::new();$browseColumn.Width='Auto';$mediaGrid.ColumnDefinitions.Add($browseColumn)|Out-Null;$mediaGrid.Margin=[System.Windows.Thickness]::new(0,0,0,12);$panel.Children.Add($mediaGrid)|Out-Null
  $media=[System.Windows.Controls.TextBox]::new();$media.Height=34;$media.Padding=[System.Windows.Thickness]::new(9,6,9,6);$media.Background=Convert-ToBrush '#FF0F203B';$media.Foreground=Convert-ToBrush '#FFF6F9FF';$media.BorderBrush=Convert-ToBrush '#665C8AC6';$media.ToolTip=Get-WidgetText 'Local image/GIF/video, public HTTPS image, or YouTube link.';$controls.media=$media;$mediaGrid.Children.Add($media)|Out-Null
  $browse=[System.Windows.Controls.Button]::new();$browse.Content=Get-WidgetText 'Browse...';$browse.Width=82;$browse.Height=34;$browse.Margin=[System.Windows.Thickness]::new(8,0,0,0);$browse.Background=Convert-ToBrush '#FF172A47';$browse.Foreground=Convert-ToBrush '#FFF6F9FF';$browse.BorderBrush=Convert-ToBrush '#665C8AC6';$browse.Template=New-ButtonTemplate;[System.Windows.Controls.Grid]::SetColumn($browse,1);$mediaGrid.Children.Add($browse)|Out-Null
  $opacityLabel=New-TextBlock -Text (Get-WidgetText 'Background opacity') -Size 11 -Color '#FFA9B9D1';$opacityLabel.Margin=[System.Windows.Thickness]::new(0,0,0,5);$panel.Children.Add($opacityLabel)|Out-Null
  $opacityRow=[System.Windows.Controls.Grid]::new();$opacityRow.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())|Out-Null;$valueCol=[System.Windows.Controls.ColumnDefinition]::new();$valueCol.Width='Auto';$opacityRow.ColumnDefinitions.Add($valueCol)|Out-Null;$opacityRow.Margin=[System.Windows.Thickness]::new(0,0,0,10);$panel.Children.Add($opacityRow)|Out-Null
  $opacity=[System.Windows.Controls.Slider]::new();$opacity.Minimum=.05;$opacity.Maximum=1.0;$opacity.SmallChange=.05;$controls.opacity=$opacity;$opacityRow.Children.Add($opacity)|Out-Null
  $opacityText=New-TextBlock -Text='' -Size 11;$opacityText.Width=48;$opacityText.TextAlignment='Right';[System.Windows.Controls.Grid]::SetColumn($opacityText,1);$opacityRow.Children.Add($opacityText)|Out-Null
  $mute=[System.Windows.Controls.CheckBox]::new();$mute.Content=Get-WidgetText 'Mute background video';$mute.Foreground=Convert-ToBrush '#FFC6D2E5';$mute.FontSize=11;$mute.Margin=[System.Windows.Thickness]::new(0,0,0,12);$controls.mute=$mute;$panel.Children.Add($mute)|Out-Null
  $rights=New-TextBlock -Text (Get-WidgetText 'Only use media you trust and have permission to display. YouTube links display a poster in the widget background; inline playback is only available for shortcut hover media.') -Size 12 -Color '#FF7D91AE';$rights.TextWrapping='Wrap';$rights.Margin=[System.Windows.Thickness]::new(0,0,0,10);$panel.Children.Add($rights)|Out-Null
  $error=New-TextBlock -Text='' -Size 10 -Color '#FFFF9A9A';$error.TextWrapping='Wrap';$error.Visibility='Collapsed';$error.Margin=[System.Windows.Thickness]::new(0,0,0,10);$controls.error=$error;$panel.Children.Add($error)|Out-Null
  $buttons=[System.Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';$buttons.HorizontalAlignment='Right';$panel.Children.Add($buttons)|Out-Null
  $clear=[System.Windows.Controls.Button]::new();$clear.Content=Get-WidgetText 'Clear media';$clear.Height=34;$clear.Padding=[System.Windows.Thickness]::new(12,4,12,4);$clear.Margin=[System.Windows.Thickness]::new(0,0,8,0);$clear.Background=Convert-ToBrush '#FF172A47';$clear.Foreground=Convert-ToBrush '#FFF6F9FF';$clear.BorderBrush=Convert-ToBrush '#665C8AC6';$clear.Template=New-ButtonTemplate -HoverBackground '#FF304663' -PressedBackground '#FF1B2C42';$buttons.Children.Add($clear)|Out-Null
  $cancel=[System.Windows.Controls.Button]::new();$cancel.Content=Get-WidgetText 'Cancel';$cancel.Height=34;$cancel.Padding=[System.Windows.Thickness]::new(12,4,12,4);$cancel.Margin=[System.Windows.Thickness]::new(0,0,8,0);$cancel.Background=Convert-ToBrush '#FF172A47';$cancel.Foreground=Convert-ToBrush '#FFF6F9FF';$cancel.BorderBrush=Convert-ToBrush '#665C8AC6';$cancel.Template=New-ButtonTemplate -HoverBackground '#FF304663' -PressedBackground '#FF1B2C42';$buttons.Children.Add($cancel)|Out-Null
  $apply=[System.Windows.Controls.Button]::new();$apply.Content=Get-WidgetText 'Apply';$apply.Height=34;$apply.Padding=[System.Windows.Thickness]::new(12,4,12,4);$apply.Background=Convert-ToBrush '#FF1F6FD0';$apply.Foreground=[System.Windows.Media.Brushes]::White;$apply.BorderBrush=Convert-ToBrush '#FF3E8BFF';$apply.Template=New-ButtonTemplate -HoverBackground '#FF2D80E0' -PressedBackground '#FF195AA8';$buttons.Children.Add($apply)|Out-Null
  $controls.apply=$apply;$controls.cancel=$cancel;$panel.Tag=$controls
  $context=@{controls=$controls;presets=$presets;dialog=$Dialog}
  $theme.Tag=$context;$browse.Tag=$context;$clear.Tag=$context;$cancel.Tag=$context;$apply.Tag=$context;$opacity.Tag=@{text=$opacityText}
  $theme.Add_SelectionChanged({param($sender,$e)$context=$sender.Tag;if($null -eq $sender.SelectedItem){return};$id=[string]$sender.SelectedItem.Tag;if($context.presets.ContainsKey($id)){$colors=$context.presets[$id];foreach($pair in @(@('accent',0),@('panel',1),@('card',2),@('cardHover',3),@('text',4))){$context.controls[$pair[0]].Text=$colors[$pair[1]]}}})
  $browse.Add_Click({param($sender,$e)$context=$sender.Tag;$picker=[Microsoft.Win32.OpenFileDialog]::new();$picker.Title=Get-WidgetText 'Choose Workspace background media';$picker.Filter="$(Get-WidgetText 'Supported media')|*.png;*.jpg;*.jpeg;*.bmp;*.ico;*.gif;*.mp4;*.m4v;*.wmv;*.avi;*.mov|$(Get-WidgetText 'Images')|*.png;*.jpg;*.jpeg;*.bmp;*.ico;*.gif|$(Get-WidgetText 'Videos')|*.mp4;*.m4v;*.wmv;*.avi;*.mov|$(Get-WidgetText 'All files')|*.*";if($picker.ShowDialog($context.dialog)){$context.controls.media.Text=$picker.FileName}})
  $clear.Add_Click({param($sender,$e)$sender.Tag.controls.media.Text=''})
  $cancel.Add_Click({param($sender,$e)Reset-WidgetAppearanceSettingsDraft -Context $sender.Tag})
  $apply.Add_Click({param($sender,$e)[void](Apply-WidgetAppearanceSettingsDraft -Context $sender.Tag)})
  $opacity.Add_ValueChanged({param($sender,$e)$sender.Tag.text.Text=('{0:P0}' -f $sender.Value)})
  Reset-WidgetAppearanceSettingsDraft -Context $context
  return $panel
}

function Set-WidgetSettingsTabStyle {
  param([System.Windows.Controls.TabControl]$Tabs)
  $resources=[System.Windows.Markup.XamlReader]::Parse(@'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="SettingsTab" TargetType="{x:Type TabItem}">
    <Setter Property="Foreground" Value="#FFF6F9FF"/>
    <Setter Property="Background" Value="#FF223149"/>
    <Setter Property="Padding" Value="14,9"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="{x:Type TabItem}">
          <Border x:Name="TabSurface" Background="{TemplateBinding Background}" BorderBrush="#FF53729B" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}" Margin="0,0,6,8">
            <ContentPresenter ContentSource="Header" RecognizesAccessKey="True" TextElement.Foreground="{TemplateBinding Foreground}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TabSurface" Property="Background" Value="#FF304663"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="TabSurface" Property="Background" Value="#FF245B97"/><Setter TargetName="TabSurface" Property="BorderBrush" Value="#FF74AEFF"/></Trigger>
            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="TabSurface" Property="BorderBrush" Value="#FFD9E9FF"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="TabSurface" Property="Opacity" Value="0.55"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <ControlTemplate x:Key="SettingsTabs" TargetType="{x:Type TabControl}">
    <DockPanel LastChildFill="True">
      <TabPanel DockPanel.Dock="Top" IsItemsHost="True" KeyboardNavigation.TabIndex="1"/>
      <Border Background="#FF16181D" Padding="0,6,0,0">
        <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent"/>
      </Border>
    </DockPanel>
  </ControlTemplate>
</ResourceDictionary>
'@)
  $Tabs.ItemContainerStyle=$resources['SettingsTab']
  $Tabs.Template=$resources['SettingsTabs']
}

function Show-WidgetSettings {
  param([ValidateSet('General','Appearance')][string]$InitialPage='General')
  if($null -ne $script:settingsWindow){
    if($script:settingsWindow.Tag.tabs){$script:settingsWindow.Tag.tabs.SelectedIndex=if($InitialPage -eq 'Appearance'){1}else{0}}
    $script:settingsWindow.Activate()|Out-Null;return
  }
  $dialog=[System.Windows.Window]::new();$script:settingsWindow=$dialog;$dialog.Title=Get-WidgetText 'Settings';$dialog.Owner=$script:window;$dialog.Width=570;$dialog.Height=650;$dialog.MinWidth=470;$dialog.MinHeight=380;$dialog.WindowStartupLocation='CenterOwner';$dialog.ShowInTaskbar=$false;$dialog.Background=Convert-ToBrush '#FF16181D';$dialog.Foreground=Convert-ToBrush '#FFF6F9FF'
  $root=[System.Windows.Controls.DockPanel]::new();$root.Margin=[System.Windows.Thickness]::new(22);$dialog.Content=$root
  $close=[System.Windows.Controls.Button]::new();$close.Content=Get-WidgetText 'Close';$close.Height=34;$close.Background=Convert-ToBrush '#FF223149';$close.Foreground=Convert-ToBrush '#FFF6F9FF';$close.BorderBrush=Convert-ToBrush '#FF53729B';$close.Template=New-ButtonTemplate -HoverBackground '#FF304663' -PressedBackground '#FF1B2C42';$close.Margin=[System.Windows.Thickness]::new(0,14,0,0);$close.IsCancel=$true;$close.Add_Click({$script:settingsWindow.Close()});[System.Windows.Controls.DockPanel]::SetDock($close,'Bottom');$root.Children.Add($close)|Out-Null
  $tabs=[System.Windows.Controls.TabControl]::new();$tabs.Background=Convert-ToBrush '#FF0F203B';$tabs.Foreground=Convert-ToBrush '#FFF6F9FF';$tabs.BorderBrush=Convert-ToBrush '#FF53729B'
  Set-WidgetSettingsTabStyle $tabs
  $root.Children.Add($tabs)|Out-Null
  $generalTab=[System.Windows.Controls.TabItem]::new();$generalTab.Header=Get-WidgetText 'General';$tabs.Items.Add($generalTab)|Out-Null
  $generalScroll=[System.Windows.Controls.ScrollViewer]::new();$generalScroll.VerticalScrollBarVisibility='Auto';$generalTab.Content=$generalScroll;$general=[System.Windows.Controls.StackPanel]::new();$general.Margin=[System.Windows.Thickness]::new(2,12,2,2);$generalScroll.Content=$general
  $opacityContent=$script:opacityPanel.Child;$script:opacityPanel.Child=$null;$settingsContent=$script:settingsPanel.Child;$script:settingsPanel.Child=$null;$opacityContent.Margin=[System.Windows.Thickness]::new(0,0,0,20);$general.Children.Add($opacityContent)|Out-Null;$general.Children.Add($settingsContent)|Out-Null
  $languageLabel=New-TextBlock -Text (Get-WidgetText 'Language') -Size 12;$languageLabel.Margin=[System.Windows.Thickness]::new(0,22,0,8);$general.Children.Add($languageLabel)|Out-Null
  $language=[System.Windows.Controls.ComboBox]::new();$language.Height=36;$language.Foreground=Convert-ToBrush '#FFF6F9FF';$language.Background=Convert-ToBrush '#FF0F203B';$language.BorderBrush=Convert-ToBrush '#FF5C8AC6';Set-DialogComboBoxStyle $language;foreach($entry in @(@('ko-KR','한국어'),@('en-US','English'))){$item=[System.Windows.Controls.ComboBoxItem]::new();$item.Tag=$entry[0];$item.Content=$entry[1];$item.Foreground=Convert-ToBrush '#FFF6F9FF';$language.Items.Add($item)|Out-Null;if($script:state.window.language -eq $entry[0]){$language.SelectedItem=$item}};$language.Add_SelectionChanged({param($sender,$e)if($null -ne $sender.SelectedItem){$script:state.window.language=[string]$sender.SelectedItem.Tag;Update-WidgetLanguage;Save-State|Out-Null}});$general.Children.Add($language)|Out-Null
  foreach($option in @(@('Reduce motion','reduceMotion'),@('Snap to screen edges','edgeSnap'))){$check=[System.Windows.Controls.CheckBox]::new();$check.Content=$option[0];$check.Tag=$option[1];$check.Foreground=Convert-ToBrush '#FFE0E5ED';$check.Margin=[System.Windows.Thickness]::new(0,14,0,0);$check.IsChecked=[bool]$script:state.window.($option[1]);$check.Add_Click({param($sender,$e)$script:state.window.($sender.Tag)=[bool]$sender.IsChecked;Save-State|Out-Null});$general.Children.Add($check)|Out-Null}
  $appearanceTab=[System.Windows.Controls.TabItem]::new();$appearanceTab.Header=Get-WidgetText 'Appearance & media';$tabs.Items.Add($appearanceTab)|Out-Null;$appearanceScroll=[System.Windows.Controls.ScrollViewer]::new();$appearanceScroll.VerticalScrollBarVisibility='Auto';$appearanceTab.Content=$appearanceScroll;$appearanceScroll.Content=(New-WidgetAppearanceSettingsPanel -Dialog $dialog)
  $tabs.SelectedIndex=if($InitialPage -eq 'Appearance'){1}else{0};$dialog.Tag=@{tabs=$tabs;general=$general;opacity=$opacityContent;settings=$settingsContent}
  $dialog.Add_Closed({param($sender,$e)$sender.Tag.general.Children.Remove($sender.Tag.opacity);$sender.Tag.general.Children.Remove($sender.Tag.settings);$script:opacityPanel.Child=$sender.Tag.opacity;$script:settingsPanel.Child=$sender.Tag.settings;$script:settingsWindow=$null})
  Set-WidgetLocalizedTree $dialog;if(-not $script:autostartBusy){Start-AutostartOperation -Action Get};$dialog.ShowDialog()|Out-Null
}

[CmdletBinding()]
param([string]$ProjectRoot, [switch]$Preview)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName PresentationFramework
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application PowerShell parse failed' }
$function = $ast.Find({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Set-DialogComboBoxStyle'
  }, $true)
if ($null -eq $function) { throw 'ComboBox style function missing' }
. ([scriptblock]::Create($function.Extent.Text))
$combo = [System.Windows.Controls.ComboBox]::new()
$combo.Width = 360
$combo.Height = 42
Set-DialogComboBoxStyle $combo
if ($combo.Foreground.ToString() -ne '#FFF6F9FF') { throw 'Collapsed text foreground regression' }
foreach ($name in @('Automatic','Lab','People')) { $null = $combo.Items.Add($name) }
$combo.SelectedIndex = 1
$null = $combo.ApplyTemplate()
$combo.Measure([System.Windows.Size]::new(360,42))
$combo.Arrange([System.Windows.Rect]::new(0,0,360,42))
$combo.UpdateLayout()
$toggle = $combo.Template.FindName('DropDownToggle',$combo)
$null = $toggle.ApplyTemplate()
$surface = $toggle.Template.FindName('ToggleSurface',$toggle)
$popup = $combo.Template.FindName('PART_Popup',$combo)
if ($surface.Background.ToString() -ne '#FF0F203B') { throw 'Collapsed background regression' }
if ($popup.Child.Background.ToString() -ne '#FF0F203B') { throw 'Popup background regression' }
if ([math]::Abs($popup.Child.Width - $combo.ActualWidth) -gt 1) { throw 'Popup width binding regression' }
if ($popup.PlacementTarget -ne $combo) { throw 'Popup target binding regression' }
$item = [System.Windows.Controls.ComboBoxItem]::new()
$item.Content = 'Lab'
$item.Style = $combo.ItemContainerStyle
$null = $item.ApplyTemplate()
$itemSurface = $item.Template.FindName('ItemSurface',$item)
if ($itemSurface.Background.ToString() -ne '#FF0F203B') { throw 'Item background regression' }
$item.IsSelected = $true
if ($itemSurface.Background.ToString() -ne '#FF245B97') { throw 'Selected background regression' }
$item.IsEnabled = $false
if ($itemSurface.Opacity -ne 0.55) { throw 'Disabled feedback regression' }
$combo.IsEnabled = $false
if ($combo.Template.FindName('ComboRoot',$combo).Opacity -ne 0.55) { throw 'Disabled picker regression' }
if ($combo.SelectedItem -ne 'Lab') { throw 'Selection changed during styling' }
[pscustomobject]@{success=$true;checks=9;scope='WPF template construction and property bindings; interactive keyboard and mouse require native UI verification'} | ConvertTo-Json
if ($Preview) {
  $combo.IsEnabled = $true
  $combo.MaxDropDownHeight = 294
  $combo.Items.Clear()
  $manifest = Get-Content (Join-Path $ProjectRoot 'assets\semantic-icons\manifest.json') -Raw | ConvertFrom-Json
  $null = $combo.Items.Add('Automatic')
  foreach ($icon in $manifest.icons) {
    $entry = [System.Windows.Controls.ComboBoxItem]::new()
    $entry.Tag = $icon.id
    $row = [System.Windows.Controls.StackPanel]::new()
    $row.Orientation = 'Horizontal'
    $image = [System.Windows.Controls.Image]::new()
    $image.Source = [System.Windows.Media.Imaging.BitmapImage]::new([uri](Join-Path $ProjectRoot ('assets\semantic-icons\' + $icon.png)))
    $image.Width = 24; $image.Height = 24
    $image.Margin = [System.Windows.Thickness]::new(0,0,10,0)
    $text = [System.Windows.Controls.TextBlock]::new()
    $text.Text = $icon.name; $text.Foreground = [System.Windows.Media.Brushes]::White
    $text.VerticalAlignment = 'Center'
    $null = $row.Children.Add($image); $null = $row.Children.Add($text)
    $entry.Content = $row
    $null = $combo.Items.Add($entry)
  }
  $combo.SelectedIndex = 8
  $window = [System.Windows.Window]::new()
  $window.Title = 'Workspace Widget - Icon picker verification'
  $window.Width = 430; $window.Height = 470
  $window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF09172B')
  $stack = [System.Windows.Controls.StackPanel]::new()
  $stack.Margin = [System.Windows.Thickness]::new(24)
  $label = [System.Windows.Controls.TextBlock]::new()
  $label.Text = 'Built-in icon'; $label.Foreground = [System.Windows.Media.Brushes]::White
  $label.Margin = [System.Windows.Thickness]::new(0,0,0,10)
  $null = $stack.Children.Add($label); $null = $stack.Children.Add($combo)
  $window.Content = $stack
  $null = $window.ShowDialog()
}

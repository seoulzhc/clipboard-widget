$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Clipboard widget: history + favorites, WPF UI in ui.xaml
#  - single click = copy, double click = edit, star = favorite
#  - +/- buttons zoom the whole card, position saved bottom-right
# ---------------------------------------------------------------------------

$script:AppName     = 'ClipboardWidget'
$script:DataDir     = Join-Path $env:APPDATA $script:AppName
$script:DataFile    = Join-Path $script:DataDir 'data.json'
$script:LogFile     = Join-Path $script:DataDir 'app.log'
$script:MaxHistory  = 60
$script:MaxFavorite = 200
$script:Win         = $null
$script:BaseWidth   = 360.0
$script:BaseHeight  = 470.0
$script:MinScale    = 0.6
$script:MaxScale    = 1.6
$script:Scale       = 1.0
$script:EditResult  = $null
$script:TrayMode    = $false
$script:Notify      = $null
$script:App         = $null
$script:IconStream  = $null

if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
}

# icon is copied next to the data file so Explorer can read it from shortcuts
$script:IconFile = Join-Path $script:DataDir 'icon.ico'
try {
    $userIconSource = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path -LiteralPath $userIconSource) {
        Copy-Item -LiteralPath $userIconSource -Destination $script:IconFile -Force
    }
} catch { }

function Write-Log {
    param([string]$Message)
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

trap {
    Write-Log ('FATAL: ' + ($_ | Out-String))
    exit 1
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
public static class ConsoleHelper {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
    [void][DpiHelper]::SetProcessDpiAwarenessContext([IntPtr](-4))
    $consoleHandle = [ConsoleHelper]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) { [void][ConsoleHelper]::ShowWindow($consoleHandle, 0) }
} catch { }

$mutex = New-Object System.Threading.Mutex($false, 'Local\DSH_ClipboardWidget')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'another instance is already running, exiting'
    exit 0
}

$script:BrushCache = @{}
function Get-Brush {
    param([string]$Hex)
    if ($script:BrushCache.ContainsKey($Hex)) { return $script:BrushCache[$Hex] }
    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    $script:BrushCache[$Hex] = $brush
    return $brush
}

function Ensure-TrayIcon {
    $path = $script:IconFile
    if (Test-Path -LiteralPath $path) { return $path }
    $localIcon = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path -LiteralPath $localIcon) {
        try { Copy-Item -LiteralPath $localIcon -Destination $path -Force; return $path } catch { return $localIcon }
    }

    $sizes = @(16, 20, 24, 32, 48, 64, 256)
    $images = New-Object System.Collections.ArrayList
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList @($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $blue = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(37, 99, 235))
        $g.FillEllipse($blue, 0, 0, ($s - 1), ($s - 1))
        $white = [System.Drawing.Brushes]::White
        $wf = [double]$s
        $bx = [int][math]::Round($wf * 0.30)
        $by = [int][math]::Round($wf * 0.32)
        $bw = [int][math]::Round($wf * 0.40)
        $bh = [int][math]::Round($wf * 0.42)
        $g.FillRectangle($white, $bx, $by, $bw, $bh)
        $g.FillRectangle($white, [int][math]::Round($wf * 0.40), [int][math]::Round($wf * 0.21), [int][math]::Round($wf * 0.20), [int][math]::Round($wf * 0.11))
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        [void]$images.Add($ms.ToArray())
        $ms.Dispose()
    }

    $out = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($out)
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $data = $images[$i]
        $dim = if ($s -ge 256) { [byte]0 } else { [byte]$s }
        $writer.Write($dim)
        $writer.Write($dim)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$data.Length)
        $writer.Write([UInt32]$offset)
        $offset += $data.Length
    }
    foreach ($d in $images) { $writer.Write([byte[]]$d) }
    $writer.Flush()
    [System.IO.File]::WriteAllBytes($path, $out.ToArray())
    $writer.Dispose()
    $out.Dispose()
    return $path
}

# ---------------------------------------------------------------- load UI ---
$xamlPath = Join-Path $PSScriptRoot 'ui.xaml'
if (-not (Test-Path -LiteralPath $xamlPath)) { throw "Missing ui.xaml: $xamlPath" }
$xamlText = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$nodeReader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
$script:Win = [System.Windows.Markup.XamlReader]::Load($nodeReader)

try {
    $iconFile = $script:IconFile
    if (-not (Test-Path -LiteralPath $iconFile)) { $iconFile = Join-Path $PSScriptRoot 'icon.ico' }
    if (Test-Path -LiteralPath $iconFile) {
        $bmpIcon = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmpIcon.BeginInit()
        $bmpIcon.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmpIcon.UriSource = New-Object System.Uri($iconFile)
        $bmpIcon.EndInit()
        $script:Win.Icon = $bmpIcon
    }
} catch { }

function Get-Msg {
    param([string]$Key)
    return [string]$script:Win.FindResource($Key)
}

# -------------------------------------------------------------- load data ---
$script:History   = New-Object System.Collections.ArrayList
$script:Favorites = New-Object System.Collections.ArrayList
$script:SavedX    = $null
$script:SavedY    = $null

if (Test-Path -LiteralPath $script:DataFile) {
    try {
        $data = Get-Content -LiteralPath $script:DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($h in @($data.history)) {
            if ($h -and $h.Text) { [void]$script:History.Add([pscustomobject]@{ Text = [string]$h.Text }) }
        }
        foreach ($f in @($data.favorites)) {
            if ($f -and $f.Text) { [void]$script:Favorites.Add([pscustomobject]@{ Text = [string]$f.Text }) }
        }
        if ($null -ne $data.scale) {
            $sc = [double]$data.scale
            if ($sc -gt 0) { $script:Scale = $sc }
        }
        if ($null -ne $data.x) { $script:SavedX = [double]$data.x }
        if ($null -ne $data.y) { $script:SavedY = [double]$data.y }
    } catch {
        Write-Log ('load failed: ' + ($_ | Out-String))
    }
}
if ($script:Scale -lt $script:MinScale) { $script:Scale = $script:MinScale }
if ($script:Scale -gt $script:MaxScale) { $script:Scale = $script:MaxScale }

$script:FooterDefault = [string]$script:Win.FindName('FooterHint').Text

# ------------------------------------------------------------------ state ---
function Save-Data {
    try {
        $x = [double]$script:Win.Left
        $y = [double]$script:Win.Top
        if ([double]::IsNaN($x)) { $x = 0 }
        if ([double]::IsNaN($y)) { $y = 0 }
        $payload = [ordered]@{
            history   = @($script:History   | ForEach-Object { [ordered]@{ Text = $_.Text } })
            favorites = @($script:Favorites | ForEach-Object { [ordered]@{ Text = $_.Text } })
            scale     = [double]$script:Scale
            x         = $x
            y         = $y
        }
        $json = $payload | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath $script:DataFile -Value $json -Encoding UTF8
    } catch {
        Write-Log ('save failed: ' + ($_ | Out-String))
    }
}

function Test-Favorite {
    param([string]$Text)
    foreach ($f in $script:Favorites) { if ($f.Text -eq $Text) { return $true } }
    return $false
}

function Toggle-Favorite {
    param([string]$Text)
    $idx = -1
    for ($i = 0; $i -lt $script:Favorites.Count; $i++) {
        if ($script:Favorites[$i].Text -eq $Text) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $script:Favorites.RemoveAt($idx)
    } else {
        $script:Favorites.Insert(0, [pscustomobject]@{ Text = $Text })
        while ($script:Favorites.Count -gt $script:MaxFavorite) {
            $script:Favorites.RemoveAt($script:Favorites.Count - 1)
        }
    }
    Save-Data
    Render-All
}

function Remove-Entry {
    param([string]$Kind, [string]$Text)
    $removed = $false
    if ($Kind -eq 'history') {
        for ($i = 0; $i -lt $script:History.Count; $i++) {
            if ($script:History[$i].Text -eq $Text) { $script:History.RemoveAt($i); $removed = $true; break }
        }
    } else {
        for ($i = 0; $i -lt $script:Favorites.Count; $i++) {
            if ($script:Favorites[$i].Text -eq $Text) { $script:Favorites.RemoveAt($i); $removed = $true; break }
        }
    }
    if ($removed) {
        Save-Data
        Render-All
        Set-Footer (Get-Msg 'MsgDeleted')
    }
}

function Add-History {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($Text.Length -gt 20000) { $Text = $Text.Substring(0, 20000) }
    for ($i = $script:History.Count - 1; $i -ge 0; $i--) {
        if ($script:History[$i].Text -eq $Text) { $script:History.RemoveAt($i) }
    }
    $script:History.Insert(0, [pscustomobject]@{ Text = $Text })
    while ($script:History.Count -gt $script:MaxHistory) {
        $script:History.RemoveAt($script:History.Count - 1)
    }
    Save-Data
    Render-All
}

function Remove-Duplicates {
    param($List)
    $seen = @{}
    for ($i = $List.Count - 1; $i -ge 0; $i--) {
        $t = [string]$List[$i].Text
        if ($seen.ContainsKey($t)) { $List.RemoveAt($i) } else { $seen[$t] = $true }
    }
}

function Apply-Edit {
    param([string]$Kind, [string]$Old, [string]$New)
    if ($New.Length -gt 20000) { $New = $New.Substring(0, 20000) }

    if ($Kind -eq 'history') {
        for ($i = 0; $i -lt $script:History.Count; $i++) {
            if ($script:History[$i].Text -eq $Old) { $script:History[$i].Text = $New; break }
        }
        foreach ($f in $script:Favorites) {
            if ($f.Text -eq $Old) { $f.Text = $New }
        }
        Remove-Duplicates $script:History
        Remove-Duplicates $script:Favorites
    } else {
        for ($i = 0; $i -lt $script:Favorites.Count; $i++) {
            if ($script:Favorites[$i].Text -eq $Old) { $script:Favorites[$i].Text = $New; break }
        }
        Remove-Duplicates $script:Favorites
    }

    Save-Data
    Render-All
    Set-Footer (Get-Msg 'MsgSaved')
}

# ------------------------------------------------------------------ view ---
$script:FooterTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FooterTimer.Interval = [TimeSpan]::FromSeconds(1.8)
$script:FooterTimer.Add_Tick({
    $script:FooterTimer.Stop()
    $footer = $script:Win.FindName('FooterHint')
    $footer.Text = $script:FooterDefault
    $footer.Foreground = Get-Brush '#94A3B8'
})

function Set-Footer {
    param([string]$Text, [string]$Color = '#16A34A')
    $footer = $script:Win.FindName('FooterHint')
    $footer.Text = $Text
    $footer.Foreground = Get-Brush $Color
    $script:FooterTimer.Stop()
    $script:FooterTimer.Start()
}

function Copy-Text {
    param([string]$Text)
    try {
        [System.Windows.Forms.Clipboard]::SetText($Text)
        $script:LastClip = $Text
        Set-Footer (Get-Msg 'MsgCopied')
    } catch {
        Set-Footer (Get-Msg 'MsgCopyFailed') '#DC2626'
    }
}

function New-Empty {
    param([string]$Message)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Message
    $tb.FontSize = 11
    $tb.Foreground = Get-Brush '#A7B4C6'
    $tb.TextWrapping = 'Wrap'
    $tb.TextAlignment = 'Center'
    $tb.Margin = New-Object System.Windows.Thickness(6, 16, 6, 6)
    return $tb
}

function New-FlatDialogButton {
    param([string]$Label, [bool]$Primary)
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 8
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.Padding = New-Object System.Windows.Thickness(16, 6, 16, 6)
    $b.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    if ($Primary) { $b.Background = Get-Brush '#2563EB' } else { $b.Background = Get-Brush '#F1F5F9' }
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Label
    $t.FontSize = 12
    if ($Primary) { $t.Foreground = [System.Windows.Media.Brushes]::White } else { $t.Foreground = Get-Brush '#334155' }
    $b.Child = $t
    return $b
}

function Show-Editor {
    param([string]$Text, [string]$Kind)
    Write-Log ('editor open: kind=' + $Kind + ' len=' + $Text.Length)

    $dlg = New-Object System.Windows.Window
    $dlg.Title = Get-Msg 'MsgEditTitle'
    $dlg.WindowStyle = [System.Windows.WindowStyle]::None
    $dlg.AllowsTransparency = $true
    $dlg.Background = [System.Windows.Media.Brushes]::Transparent
    $dlg.Width = 380
    $dlg.Height = 250
    $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dlg.ShowInTaskbar = $false
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner = $script:Win
    $dlg.Topmost = $true
    $dlg.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')

    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = 14
    $card.Background = [System.Windows.Media.Brushes]::White
    $card.BorderBrush = Get-Brush '#E2E8F0'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.Padding = New-Object System.Windows.Thickness(16)

    $panel = New-Object System.Windows.Controls.StackPanel

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = Get-Msg 'MsgEditTitle'
    $title.FontSize = 14
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.Foreground = Get-Brush '#0F172A'
    [void]$panel.Children.Add($title)

    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $Text
    $box.FontSize = 12.5
    $box.Height = 120
    $box.Margin = New-Object System.Windows.Thickness(0, 10, 0, 6)
    $box.Padding = New-Object System.Windows.Thickness(8)
    $box.AcceptsReturn = $true
    $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $box.Background = Get-Brush '#F8FAFC'
    $box.Foreground = Get-Brush '#1F2937'
    $box.BorderBrush = Get-Brush '#E2E8F0'
    $box.BorderThickness = New-Object System.Windows.Thickness(1)
    [void]$panel.Children.Add($box)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = Get-Msg 'MsgEditHint'
    $hint.FontSize = 10
    $hint.Foreground = Get-Brush '#94A3B8'
    [void]$panel.Children.Add($hint)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)

    $cancel = New-FlatDialogButton (Get-Msg 'MsgCancel') $false
    $save = New-FlatDialogButton (Get-Msg 'MsgSave') $true
    [void]$buttons.Children.Add($cancel)
    [void]$buttons.Children.Add($save)
    [void]$panel.Children.Add($buttons)

    $card.Child = $panel
    $dlg.Content = $card

    $obj = New-Object psobject -Property @{ Dialog = $dlg; Box = $box; Result = $null }
    $script:EditState = $obj

    $cancel.Add_MouseLeftButtonUp({ $script:EditState.Result = $null; $script:EditState.Dialog.Close() })
    $save.Add_MouseLeftButtonUp({ $script:EditState.Result = $script:EditState.Box.Text; $script:EditState.Dialog.Close() })
    $dlg.Add_PreviewKeyDown({
        param($s, $ev)
        if ($ev.Key -eq [System.Windows.Input.Key]::Escape) {
            $script:EditState.Result = $null
            $script:EditState.Dialog.Close()
            $ev.Handled = $true
        } elseif ($ev.Key -eq [System.Windows.Input.Key]::Enter -and (($ev.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)) {
            $script:EditState.Result = $script:EditState.Box.Text
            $script:EditState.Dialog.Close()
            $ev.Handled = $true
        }
    })
    $dlg.Add_Loaded({
        try { $script:EditState.Dialog.Activate() } catch { }
        $script:EditState.Box.Focus()
        $script:EditState.Box.SelectAll()
    })

    [void]$dlg.ShowDialog()

    $new = $script:EditState.Result
    $script:EditState = $null
    if ($new -ne $null) {
        $new = ([string]$new).Trim()
        if ($new.Length -gt 0 -and $new -ne $Text) {
            Apply-Edit $Kind $Text $new
        }
    }
}

function New-TextRow {
    param([string]$Text, [bool]$IsFavorite, [string]$Kind)

    $tag = [pscustomobject]@{ Text = $Text; Kind = $Kind }

    $row = New-Object System.Windows.Controls.Button
    $row.Style = $script:Win.FindResource('RowBtn')
    $row.Tag = $tag
    $tip = $Text
    if ($tip.Length -gt 300) { $tip = $tip.Substring(0, 300) + '...' }
    $row.ToolTip = $tip

    $grid = New-Object System.Windows.Controls.Grid
    $colText = New-Object System.Windows.Controls.ColumnDefinition
    $colText.Width = [System.Windows.GridLength]::new(1.0, [System.Windows.GridUnitType]::Star)
    $colEdit = New-Object System.Windows.Controls.ColumnDefinition
    $colEdit.Width = [System.Windows.GridLength]::Auto
    $colStar = New-Object System.Windows.Controls.ColumnDefinition
    $colStar.Width = [System.Windows.GridLength]::Auto
    $colDel = New-Object System.Windows.Controls.ColumnDefinition
    $colDel.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($colText)
    [void]$grid.ColumnDefinitions.Add($colEdit)
    [void]$grid.ColumnDefinitions.Add($colStar)
    [void]$grid.ColumnDefinitions.Add($colDel)

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = ($Text -replace '\s+', ' ')
    $label.FontSize = 11.5
    $label.Foreground = Get-Brush '#1F2937'
    $label.TextWrapping = 'Wrap'
    $label.TextTrimming = 'CharacterEllipsis'
    $label.MaxHeight = 32
    $label.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($label, 0)

    $star = New-Object System.Windows.Controls.Button
    $star.Style = $script:Win.FindResource('StarBtn')
    $star.Content = if ($IsFavorite) { [string][char]0x2605 } else { [string][char]0x2606 }
    $star.Foreground = if ($IsFavorite) { Get-Brush '#F59E0B' } else { Get-Brush '#C3CEDC' }
    $star.Tag = $tag
    $star.ToolTip = if ($IsFavorite) { Get-Msg 'MsgUnfavorite' } else { Get-Msg 'MsgFavorite' }
    $star.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
    $star.Width = 22
    $star.Height = 22
    $star.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    [System.Windows.Controls.Grid]::SetColumn($star, 2)

    $edit = New-Object System.Windows.Controls.Button
    $edit.Style = $script:Win.FindResource('StarBtn')
    $edit.Content = [string][char]0x270E
    $edit.FontSize = 12
    $edit.Width = 20
    $edit.Height = 20
    $edit.Foreground = Get-Brush '#94A3B8'
    $edit.Tag = $tag
    $edit.ToolTip = Get-Msg 'MsgEditTip'
    $edit.Margin = New-Object System.Windows.Thickness(4, 0, 0, 0)
    $edit.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    [System.Windows.Controls.Grid]::SetColumn($edit, 1)

    $del = New-Object System.Windows.Controls.Button
    $del.Style = $script:Win.FindResource('StarBtn')
    $del.Content = [string][char]0x2715
    $del.FontSize = 11
    $del.Width = 20
    $del.Height = 20
    $del.Foreground = Get-Brush '#C3CEDC'
    $del.Tag = $tag
    $del.ToolTip = Get-Msg 'MsgDeleteTip'
    $del.Margin = New-Object System.Windows.Thickness(1, 0, 0, 0)
    $del.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    [System.Windows.Controls.Grid]::SetColumn($del, 3)

    [void]$grid.Children.Add($label)
    [void]$grid.Children.Add($edit)
    [void]$grid.Children.Add($star)
    [void]$grid.Children.Add($del)
    $row.Content = $grid

    $row.Add_Click({ param($s, $ev) Copy-Text ([string]$s.Tag.Text) })
    $star.Add_Click({ param($s, $ev) $ev.Handled = $true; Toggle-Favorite ([string]$s.Tag.Text) })
    $edit.Add_Click({ param($s, $ev) $ev.Handled = $true; Show-Editor ([string]$s.Tag.Text) ([string]$s.Tag.Kind) })
    $del.Add_Click({ param($s, $ev) $ev.Handled = $true; Remove-Entry ([string]$s.Tag.Kind) ([string]$s.Tag.Text) })
    $row.Add_PreviewMouseLeftButtonDown({
        param($s, $ev)
        if ($ev.ClickCount -ne 2) { return }
        $d = $ev.OriginalSource
        while ($d -ne $null -and $d -ne $s) {
            if ($d -is [System.Windows.Controls.Button]) { return }
            try { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) } catch { return }
        }
        $ev.Handled = $true
        Show-Editor ([string]$s.Tag.Text) ([string]$s.Tag.Kind)
    })
    $star.Add_PreviewMouseLeftButtonDown({
        param($s, $ev)
        if ($ev.ClickCount -eq 2) { $ev.Handled = $true }
    })

    return $row
}

function Render-All {
    $historyPanel = $script:Win.FindName('HistoryPanel')
    $favPanel     = $script:Win.FindName('FavPanel')
    $historyPanel.Children.Clear()
    $favPanel.Children.Clear()

    foreach ($item in $script:History) {
        [void]$historyPanel.Children.Add((New-TextRow -Text $item.Text -IsFavorite (Test-Favorite $item.Text) -Kind 'history'))
    }
    if ($script:History.Count -eq 0) {
        [void]$historyPanel.Children.Add((New-Empty (Get-Msg 'MsgEmptyHistory')))
    }

    foreach ($item in $script:Favorites) {
        [void]$favPanel.Children.Add((New-TextRow -Text $item.Text -IsFavorite $true -Kind 'fav'))
    }
    if ($script:Favorites.Count -eq 0) {
        [void]$favPanel.Children.Add((New-Empty (Get-Msg 'MsgEmptyFavorite')))
    }

    $script:Win.FindName('HistoryCount').Text = [string]$script:History.Count
    $script:Win.FindName('FavCount').Text     = [string]$script:Favorites.Count
}

function Update-PinVisual {
    $pin = $script:Win.FindName('PinBtn')
    if ($script:Win.Topmost) {
        $pin.Background = Get-Brush '#DBEAFE'
        $pin.ToolTip = Get-Msg 'MsgPinned'
    } else {
        $pin.Background = [System.Windows.Media.Brushes]::Transparent
        $pin.ToolTip = Get-Msg 'MsgPin'
    }
}

function Get-MaxScale {
    $work = [System.Windows.SystemParameters]::WorkArea
    $mx = $script:MaxScale
    $byW = ($work.Width - 8) / $script:BaseWidth
    $byH = ($work.Height - 8) / $script:BaseHeight
    if ($byW -lt $mx) { $mx = $byW }
    if ($byH -lt $mx) { $mx = $byH }
    if ($mx -lt $script:MinScale) { $mx = $script:MinScale }
    return $mx
}

function Get-CursorDip {
    $p = [System.Windows.Forms.Cursor]::Position
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($script:Win)
    $sx = 1.0
    $sy = 1.0
    if ($dpi.DpiScaleX -gt 0) { $sx = $dpi.DpiScaleX }
    if ($dpi.DpiScaleY -gt 0) { $sy = $dpi.DpiScaleY }
    return @(($p.X / $sx), ($p.Y / $sy))
}

function Set-Scale {
    param([double]$NewScale, [double]$Left, [double]$Top, [bool]$Persist = $true)

    $s = [math]::Round($NewScale, 2)
    if ($s -lt $script:MinScale) { $s = $script:MinScale }
    $mx = Get-MaxScale
    if ($s -gt $mx) { $s = $mx }

    $script:Scale = $s
    $card = $script:Win.FindName('RootCard')
    $card.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($s, $s)
    $script:Win.Width  = $script:BaseWidth * $s
    $script:Win.Height = $script:BaseHeight * $s
    $script:Win.Left = $Left
    $script:Win.Top  = $Top

    $work = [System.Windows.SystemParameters]::WorkArea
    if ($script:Win.Left -lt ($work.Left + 2)) { $script:Win.Left = $work.Left + 2 }
    if ($script:Win.Top -lt ($work.Top + 2)) { $script:Win.Top = $work.Top + 2 }
    if (($script:Win.Left + $script:Win.Width) -gt ($work.Right - 2)) { $script:Win.Left = $work.Right - 2 - $script:Win.Width }
    if (($script:Win.Top + $script:Win.Height) -gt ($work.Bottom - 2)) { $script:Win.Top = $work.Bottom - 2 - $script:Win.Height }

    if ($Persist) { Save-Data }
}

function Collapse-Widget {
    if ($script:TrayMode) { return }
    $script:TrayMode = $true
    Save-Data
    $script:Win.Hide()
    if ($script:Notify -ne $null) {
        try { $script:Notify.Visible = $true } catch { }
    }
}

function Restore-Widget {
    if (-not $script:TrayMode) { return }
    $script:TrayMode = $false
    if ($script:Notify -ne $null) {
        try { $script:Notify.Visible = $false } catch { }
    }
    $script:Win.Show()
    if ($script:Win.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $script:Win.WindowState = [System.Windows.WindowState]::Normal
    }
    try { $script:Win.Activate() } catch { }
}

# ------------------------------------------------------------- clipboard ---
$script:LastClip = $null
try {
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $script:LastClip = [System.Windows.Forms.Clipboard]::GetText()
    }
} catch { }

$script:ClipTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ClipTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$script:ClipTimer.Add_Tick({
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $t = [System.Windows.Forms.Clipboard]::GetText()
            if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne $script:LastClip) {
                $script:LastClip = $t
                Add-History $t
            }
        }
    } catch { }
})
$script:ClipTimer.Start()

# ---------------------------------------------------------------- window ---
function Test-ButtonSource {
    param($Source)
    $d = $Source
    while ($d -ne $null) {
        if ($d -is [System.Windows.Controls.Button]) { return $true }
        try { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) } catch { return $false }
    }
    return $false
}

$header = $script:Win.FindName('Header')
$header.Add_MouseLeftButtonDown({
    param($s, $ev)
    if ($ev.ButtonState -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    if (Test-ButtonSource $ev.OriginalSource) { return }
    try { $script:Win.DragMove() } catch { }
    Save-Data
})

$script:Resizing          = $false
$script:ResizeCorner      = ''
$script:ResizeStartX      = 0.0
$script:ResizeStartY      = 0.0
$script:ResizeStartLeft   = 0.0
$script:ResizeStartTop    = 0.0
$script:ResizeStartWidth  = 0.0
$script:ResizeStartHeight = 0.0
$script:ResizeStartScale  = 1.0

foreach ($gripName in @('ResizeTL', 'ResizeTR', 'ResizeBL', 'ResizeBR')) {
    $grip = $script:Win.FindName($gripName)
    $grip.Add_MouseLeftButtonDown({
        param($s, $ev)
        if ($ev.ButtonState -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $script:Resizing = $true
        $script:ResizeCorner = [string]$s.Tag
        $pt = Get-CursorDip
        $script:ResizeStartX = $pt[0]
        $script:ResizeStartY = $pt[1]
        $script:ResizeStartLeft = $script:Win.Left
        $script:ResizeStartTop = $script:Win.Top
        $script:ResizeStartWidth = $script:Win.Width
        $script:ResizeStartHeight = $script:Win.Height
        $script:ResizeStartScale = $script:Scale
        [void]$s.CaptureMouse()
        $ev.Handled = $true
    })
    $grip.Add_MouseMove({
        param($s, $ev)
        if (-not $script:Resizing) { return }
        $pt = Get-CursorDip
        $dx = $pt[0] - $script:ResizeStartX
        $dy = $pt[1] - $script:ResizeStartY
        $sw = [double]$script:ResizeStartWidth
        $sh = [double]$script:ResizeStartHeight
        if ($sw -le 0 -or $sh -le 0) { return }

        $corner = [string]$script:ResizeCorner
        $ds = 0.0
        if ($corner -eq 'BR') { $ds = ($dx / $sw + $dy / $sh) / 2.0 }
        elseif ($corner -eq 'BL') { $ds = (($dx * -1) / $sw + $dy / $sh) / 2.0 }
        elseif ($corner -eq 'TR') { $ds = ($dx / $sw + ($dy * -1) / $sh) / 2.0 }
        else { $ds = (($dx * -1) / $sw + ($dy * -1) / $sh) / 2.0 }

        $s2 = $script:ResizeStartScale * (1.0 + $ds)
        if ($s2 -lt $script:MinScale) { $s2 = $script:MinScale }
        $mx = Get-MaxScale
        if ($s2 -gt $mx) { $s2 = $mx }
        $s2 = [math]::Round($s2 * 50) / 50

        $newW = $script:BaseWidth * $s2
        $newH = $script:BaseHeight * $s2
        $left = $script:ResizeStartLeft
        $top = $script:ResizeStartTop
        if ($corner -eq 'BL' -or $corner -eq 'TL') { $left = $script:ResizeStartLeft + $sw - $newW }
        if ($corner -eq 'TR' -or $corner -eq 'TL') { $top = $script:ResizeStartTop + $sh - $newH }
        Set-Scale $s2 $left $top $false
        $ev.Handled = $true
    })
    $grip.Add_MouseLeftButtonUp({
        param($s, $ev)
        if ($script:Resizing) {
            $script:Resizing = $false
            try { [void]$s.ReleaseMouseCapture() } catch { }
            Save-Data
            $ev.Handled = $true
        }
    })
}

$script:Win.Add_Loaded({
    $script:Win.Topmost = $true
    try { $script:Win.Activate() } catch { }
})

$script:Win.FindName('MinBtn').Add_Click({ Collapse-Widget })

$script:Win.FindName('CloseBtn').Add_Click({
    $script:Win.Close()
    if ($script:App -ne $null) { $script:App.Shutdown() }
})
$script:Win.FindName('PinBtn').Add_Click({
    $script:Win.Topmost = -not $script:Win.Topmost
    Update-PinVisual
})
$script:Win.Add_Closing({
    Save-Data
    if ($script:Notify -ne $null) {
        try { $script:Notify.Visible = $false } catch { }
        try { $script:Notify.Dispose() } catch { }
        $script:Notify = $null
    }
})
$script:Win.Add_Closed({
    if ($script:App -ne $null) { $script:App.Shutdown() }
})

# ---------------------------------------------------------------- startup ---
$w = $script:BaseWidth * $script:Scale
$h = $script:BaseHeight * $script:Scale
$work = [System.Windows.SystemParameters]::WorkArea
$left = $work.Right - $w - 14
$top  = $work.Bottom - $h - 14
if ($null -ne $script:SavedX -and $null -ne $script:SavedY) {
    $sx = [double]$script:SavedX
    $sy = [double]$script:SavedY
    if ($sx -gt ($work.Left - 150) -and $sx -lt ($work.Right - 120) -and
        $sy -gt ($work.Top - 60) -and $sy -lt ($work.Bottom - 120)) {
        $left = $sx
        $top  = $sy
    }
}
Set-Scale $script:Scale $left $top $false

# ------------------------------------------------------------------- tray ---
try {
    $iconPath = Ensure-TrayIcon
    $script:Notify = New-Object System.Windows.Forms.NotifyIcon
    $iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
    $script:IconStream = New-Object System.IO.MemoryStream(, $iconBytes)
    $script:Notify.Icon = New-Object System.Drawing.Icon($script:IconStream)
    $script:Notify.Text = Get-Msg 'MsgTrayTip'
    $script:Notify.Visible = $false

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $trayMenu.Items.Add((Get-Msg 'MsgTrayOpen'))
    $miOpen.Add_Click({ Restore-Widget })
    $miExit = $trayMenu.Items.Add((Get-Msg 'MsgTrayExit'))
    $miExit.Add_Click({
        if ($script:Notify -ne $null) { $script:Notify.Visible = $false }
        $script:Win.Close()
        if ($script:App -ne $null) { $script:App.Shutdown() }
    })
    $script:Notify.ContextMenuStrip = $trayMenu

    $script:Notify.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-Widget }
    })
    $script:Notify.Add_MouseDoubleClick({
        param($s, $e)
        Restore-Widget
    })
    Write-Log 'tray ready'
} catch {
    Write-Log ('tray init failed: ' + ($_ | Out-String))
}

Update-PinVisual
Render-All
Write-Log 'started'

$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:App.Run($script:Win) | Out-Null
$script:ClipTimer.Stop()
Write-Log 'exited'

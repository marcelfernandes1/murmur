param([Parameter(Mandatory)][string]$AppPath, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$process = Start-Process $AppPath -PassThru
try {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) { throw "Murmur exited with code $($process.ExitCode)." }
    } until ($process.MainWindowHandle -ne 0 -or (Get-Date) -gt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw 'Murmur did not open its setup window.' }
    $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Speech model')
    $modelPicker = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (!$modelPicker) { throw 'Speech model setup was not accessible.' }
    $bounds = $window.Current.BoundingRectangle
    $image = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $image.Size)
        $image.Save((Join-Path $Output 'windows-setup.png'))
    } finally { $graphics.Dispose(); $image.Dispose() }
    # Second launch must signal the first process and exit.
    $second = Start-Process $AppPath -PassThru
    if (!$second.WaitForExit(10000)) { Stop-Process -Id $second.Id -Force; throw 'Single-instance activation failed.' }
    if ($second.ExitCode -ne 0) { throw 'Second launch failed.' }
    'PASS: WPF startup, accessible setup, single-instance activation.' | Set-Content (Join-Path $Output 'smoke-results.txt')
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
}

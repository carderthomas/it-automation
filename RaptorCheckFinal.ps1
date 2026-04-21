#
#   Raptor Hardware Service Monitoring
#
#   Created by Thomas Carder, 4/20/2026
#
#   Publicly available under GNU GPLv3
#

#
#	to install
#
# 1. place this script in documents or similar folder on local machine
# 2. copy/paste below into new shortcut
# powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Path\To\Script.ps1"
# conhost.exe powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Your\Full\Path\To\YourScript.ps1" << use this one if the above one does not start silently, this is an issue with Windows Terminal being the default I believe
# 3. place your shortcut in shell:startup folder (accessible through windows + r or file explorer)
# 4. ensure the user has local admin privileges (possibly setup a kiosk account if only used for Raptor)
#

#
#   to use
#
# - once installed, service monitoring will automatically record the status of your Hardware Service every 15 minutes
# - if any errors are encountered, they will be logged and a correction will be attempted
# - if the error is fatal, a pop-up will appear on your user's desktop to inform them to submit a help ticket (exact message can modified below)
# - the log is available by navigating to the LocalAppData folder where it will be saved in a folder named whatever you called your orgName variable (default is Your Organization)
#

#
#	to un-install
#
# 1. delete the shortcut you created that is located in shell:startup
# 2. delete the script in your documents folder (or wherever saved earlier)
# 

# configure for your organization
$orgName = "Your Organization"
$raptorSystemTrayPath = "C:\Program Files (x86)\Raptor Technologies LLC\RaptorHardwareService\HardwareServiceSysTray.exe"



# import pop-up functionality
Add-Type -AssemblyName PresentationFramework

# prevent multiple instances
$mutexName = "Global\RaptorMonitor"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)

if (-not $mutex.WaitOne(0)) {
    Write-Host "Another instance is already running. Exiting."
    exit
}

# function to keep only 30 days of log
function Limit-Log {
    $logPath = Join-Path -Path "$env:LOCALAPPDATA\$script:orgName\Logs" -ChildPath "monitor.log"
    $cutoff = (Get-Date).AddDays(-30)

    if (-not (Test-Path $logPath)) { return }

    $lines = Get-Content $logPath
    $filtered = $lines | Where-Object {
        if ($_ -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}') {
            [datetime]$lineDate = $matches[0]
            $lineDate -ge $cutoff
        } else {
            $true  # keep lines that don't match the timestamp format
        }
    }
    $filtered | Set-Content $logPath
}

# function to write to log file
function Write-Log{
    param([string]$Message)
    $logPath = Join-Path -Path "$env:LOCALAPPDATA\$script:orgName\Logs" -ChildPath "monitor.log"

    $timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timeStamp - $Message"

    # check for log file, creates if does not exist
    $logDir = Split-Path -Path $logPath -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -Path $logPath -Value $logEntry
}

# function for pop-ups on fatal errors, change to your use-case
function Show-HelpDeskAlert {
    param([string]$ErrorType)

    $messages = @{
        'SERVICE_MISSING'  = "Raptor service could not be found on this computer.`n`nPlease submit a ticket or call the help desk."
        'SERVICE_DISABLED' = "Raptor service has been disabled on this computer.`n`nPlease submit a ticket or call the help desk."
    }

    $msg = $messages[$ErrorType]
    if (-not $msg) { $msg = "An unknown Raptor error occurred. Please submit a ticket or call the help desk." }

    [System.Windows.MessageBox]::Show(
        $msg,
        "RaptorActionRequired",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
}

$mutexRef = $mutex
# release mutex on exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $mutexRef.ReleaseMutex()
    $mutexRef.Dispose()
}

# allows system to boot fully before starting script
Start-Sleep -Seconds 120


# check to see if RaptorHardwareService is started
:mainLoop while($true) {
    $now = Get-Date
    if (-not $script:lastCleanup -or ($now - $script:lastCleanup).TotalHours -ge 24) {
        Limit-Log
        $script:lastCleanup = $now
    }

    $svc = Get-Service -Name "RaptorHardwareService" -ErrorAction SilentlyContinue
    $procs = @(Get-Process -Name "HardwareServiceSysTray" -ErrorAction SilentlyContinue)
    $count = $procs.Count
    


    # if $svc = $null: fatal error, raptor missing, automated report
    if ($null -eq $svc) {
        Write-Log "Fatal Error: Missing Raptor Hardware Service."
        Show-HelpDeskAlert -ErrorType 'SERVICE_MISSING'
        $mutex.ReleaseMutex()
        exit
    }
    elseif ($svc.StartType -eq 'Disabled') {
        Write-Log "Fatal Error: Service is disabled. Cannot start."
        Show-HelpDeskAlert -ErrorType 'SERVICE_DISABLED'
        $mutex.ReleaseMutex()
        exit
    }
    else{
        # if procs.Count > 1: stop-process all raptor, restart hardwareservice service
        if ($count -gt 1){
            Write-Log "Detected $($procs.Count) instance(s). Closing and restarting services.."
            try {
                Stop-Process -InputObject $procs -Force
                Start-Sleep -Seconds 30
                Restart-Service -InputObject $svc
                $svc.Refresh()
            } catch {
                Write-Log "ERROR: Failed to close and restart Raptor"
                continue mainLoop
            }
            try{
                $svc.WaitForStatus('Running', '00:00:30')
                Write-Log "Raptor Hardware Service has been restarted."
            } catch [System.ServiceProcess.TimeoutException] {
                $svc.Refresh()
                Write-Log "ERROR: Failed to start within 30 secs. Current: $($svc.Status)"
            }
        }
        elseif ($count -eq 0){
            Write-Log "System Tray not running."
            try {
                Start-Process -FilePath $raptorSystemTrayPath
            } catch {
                Write-Log "Failed to start System Tray"
            }
        }

        $svc.Refresh()
        switch($svc.Status){
            'Running' {
                Write-Log "Raptor Hardware Service is functioning properly."
            }

            'Stopped' {
                Write-Log "Raptor Hardware Service is stopped. Attempting to resume.."

                try {
                    Start-Service -InputObject $svc
                } catch {
                    Write-Log "ERROR: Failed to send start command"
                }

                try{
                    $svc.WaitForStatus('Running', '00:00:30')
                    Write-Log "Raptor Hardware Service has been restarted."
                } catch [System.ServiceProcess.TimeoutException] {
                    $svc.Refresh()
                    Write-Log "ERROR: Failed to start within 30 secs. Current: $($svc.Status)"
                }
            }

            'Paused' {
                Write-Log "Raptor Hardware Service is paused. Attempting to resume.."

                try {
                Resume-Service -InputObject $svc
                } catch {
                    Write-Log "ERROR: Failed to send resume command"
                }
                
                try {
                    $svc.WaitForStatus('Running', '00:00:30')
                    Write-Log "Raptor Hardware Service successfully started."
                } catch {
                    $svc.Refresh()
                    Write-Log "ERROR: Failed to start within 30 secs. Current: $($svc.Status)"
                }
            }

            'StopPending' {
                Write-Log "Raptor Hardware Service is in StopPending. Waiting.."

                try {
                    $svc.WaitForStatus('Stopped', '00:00:30')
                    Write-Log "Service reached stopped. attempting to start"
                    try {
                        Start-Service -InputObject $svc
                    } catch {
                        Write-Log "ERROR: Service stuck in StopPending after 30 seconds"
                    }
                } catch {
                    $svc.Refresh()
                    Write-Log "ERROR: Service is still in $($svc.Status) after 30 seconds."
                }
            }

            'StartPending' {
                Write-Log "Raptor Hardware Service is in StartPending. Waiting.."

                try {
                    $svc.WaitForStatus('Running', '00:00:30')
                    Write-Log "Service reached Running from StartPending."
                } catch {
                    $svc.Refresh()
                    Write-Log "ERROR: Service is still in $($svc.Status) after 30 seconds."
                }
            }

            'ContinuePending' {
                Write-Log "Raptor Hardware Service is in ContinuePending. Waiting.."
                try {
                    $svc.WaitForStatus('Running', '00:00:30')
                    Write-Log "Service reached Running from ContinuePending."
                } catch {
                    $svc.Refresh()
                    Write-Log "ERROR: Service is still in $($svc.Status) after 30 seconds."
                }
            }

            default {
                Write-Log "Unknown service status: $($svc.Status)"
            }
        }
    }
    Start-Sleep -Seconds 900
}






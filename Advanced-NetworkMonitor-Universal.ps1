<#
.SYNOPSIS
    Sistem Pemantauan Jaringan Universal & Pencatat Insiden (PowerShell 1.0 - 5.x+)
.DESCRIPTION
    Skrip kompatibel universal yang menggunakan .NET WebClient dan System.Net.NetworkInformation.Ping
    untuk menghindari error pada versi PowerShell yang lebih lama.
#>

# ==========================================
# 1. KONFIGURASI SISTEM & TARGET
# ==========================================
\$Config = @{
    Targets           = @(
        @{ Name = "DNS Utama (Google)"; Address = "8.8.8.8"; Type = "Ping" },
        @{ Name = "Gateway Lokal"; Address = "192.168.1.1"; Type = "Ping" },
        @{ Name = "Server Web Utama"; Address = "http://www.google.com"; Type = "HTTP" }
    )
    IntervalSeconds   = 10
    LatencyThresholdMS= 150
    LogDirectory      = "C:\NetworkMonitor\Logs"
    LogFileName       = "NetworkIncidents.log"
    MaxLogSizeBytes   = 5242880 # 5 MB dalam bytes
    
    # Pengaturan Webhook (Discord / Slack / Teams) - Kosongkan jika tidak digunakan
    WebhookUrl        = ""
}

# ==========================================
# 2. INISIALISASI DIREKTORI & LOG
# ==========================================
if (-not (Test-Path -Path \$Config.LogDirectory)) {
    [void](New-Item -ItemType Directory -Path \$Config.LogDirectory -Force)
}

\$Global:LogFilePath = Join-Path -Path $Config.LogDirectory -ChildPath$Config.LogFileName

function Write-Log {
    param (\$Level, $Target,$Message)
    
    # Rotasi Log Aman untuk PS 1.0+
    if (Test-Path \$Global:LogFilePath) {
        $logItem = Get-Item$Global:LogFilePath
        if (\$logItem.Length -gt $Config.MaxLogSizeBytes) {$timestampFile = (Get-Date).ToString("yyyyMMdd_HHmmss")
            \$archivedPath = Join-Path -Path $Config.LogDirectory -ChildPath ("NetworkIncidents_$timestampFile.log")
            Rename-Item -Path $Global:LogFilePath -NewName$archivedPath -Force
        }
    }
    
    \$Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    \$FormattedEntry = "[$Timestamp] [$Level] [$Target] -$Message"
    
    Add-Content -Path $Global:LogFilePath -Value$FormattedEntry
    
    # Pewarnaan konsol aman (Host Color didukung PS 2.0+)
    if (\$host.Version.Major -ge 2) {
        switch (\$Level) {
            "INFO"    { Write-Host \$FormattedEntry -ForegroundColor Cyan }
            "SUCCESS" { Write-Host \$FormattedEntry -ForegroundColor Green }
            "WARNING" { Write-Host \$FormattedEntry -ForegroundColor Yellow }
            "ERROR"   { Write-Host \$FormattedEntry -ForegroundColor Red }
            default   { Write-Host \$FormattedEntry }
        }
    } else {
        Write-Host \$FormattedEntry
    }
}

# Fungsi Webhook Aman (Menggunakan .NET WebClient agar kompatibel dengan PS 1.0/2.0)
function Send-WebhookNotification {
    param ($Message,$Status)
    
    if (-not $Config.WebhookUrl -or$Config.WebhookUrl -eq "") { return }
    
    \$Color = 3066993
    if (\$Status -eq "DOWN") { $Color = 15158332 }$IsoTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    \$Payload = "{`"embeds`":[{`"title`":`"🚨 NOTIFIKASI MONITORING JARINGAN`",`"description`":`"$Message`",`"color`":\$Color,`"timestamp`":`"$IsoTime`"}]}"
    
    \$webClient = New-Object System.Net.WebClient
    \$webClient.Headers.Add("Content-Type", "application/json")
    try {
        [void]\$webClient.UploadString($Config.WebhookUrl, "POST", $Payload)
    } catch {
        Write-Log "ERROR" "SYSTEM" "Gagal mengirim webhook: \$_"
    } finally {
        \$webClient.Dispose()
    }
}

# ==========================================
# 3. FUNGSI PENGUJIAN KONEKSI AMAN (UNIVERSAL)
# ==========================================
function Test-TargetConnectionUniversal {
    param (\$Target)
    
    $Result = @{ Success =$false; Latency = 0; ErrorDetail = "" }
    
    if (\$Target.Type -eq "Ping") {
        \$pingSender = New-Object System.Net.NetworkInformation.Ping
        try {
            # Timeout 2000ms, menggunakan .NET kelas murni agar aman di PS 1.0 - 5.x
            \$reply = $pingSender.Send($Target.Address, 2000)
            if ($reply -and$reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $Result.Success =$true
                $Result.Latency =$reply.RoundtripTime
            } else {
                \$Result.ErrorDetail = "Status: $($reply.Status)"
            }
        } catch {
            $Result.ErrorDetail =$_.Exception.Message
        } finally {
            if ($pingSender) {$pingSender.Dispose() }
        }
    } 
    elseif (\$Target.Type -eq "HTTP") {
        \$wc = New-Object System.Net.WebClient
        \$sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Unduh header/sedikit data untuk memastikan HTTP aktif
            [void]\$wc.DownloadString($Target.Address)$sw.Stop()
            $Result.Success =$true
            $Result.Latency = [math]::Round($sw.Elapsed.TotalMilliseconds)
        } catch {
            $Result.ErrorDetail =$_.Exception.Message
        } finally {
            \$wc.Dispose()
        }
    }
    
    return \$Result
}

# ==========================================
# 4. LOOP PEMANTAUAN UTAMA
# ==========================================
\$StatusTracker = @{ }
foreach (\$t in $Config.Targets) {$StatusTracker[$t.Name] = @{ Status = "UNKNOWN"; HighLatencyAlerted = $false }
}

Write-Log "INFO" "SYSTEM" "=== SISTEM MEMULAI PEMANTAUAN JARINGAN (Universal Mode) ==="

while (\$true) {
    for (\$i = 0; $i -lt$Config.Targets.Count; $i++) {$Target = $Config.Targets[$i]
        $Name =$Target.Name
        
        \$CheckResult = Test-TargetConnectionUniversal -Target $Target$PreviousStatus = $StatusTracker[$Name].Status
        
        if (-not \$CheckResult.Success) {
            if (\$PreviousStatus -ne "DOWN") {
                $StatusTracker[$Name].Status = "DOWN"
                \$Msg = "INSIDEN TERDETEKSI: \$Name ($($Target.Address)) TERPUTUS/OFFLINE! Detail: $($CheckResult.ErrorDetail)"
                Write-Log "ERROR" $Name$Msg
                Send-WebhookNotification -Message \$Msg -Status "DOWN"
            }
        } else {
            if (\$PreviousStatus -eq "DOWN") {
                $StatusTracker[$Name].Status = "UP"
                \$Msg = "PEMULIHAN KONEKSI: \$Name ($($Target.Address)) KEMBALI ONLINE. Latensi: $($CheckResult.Latency)ms"
                Write-Log "SUCCESS" $Name$Msg
                Send-WebhookNotification -Message \$Msg -Status "UP"
            }
            elseif (\$PreviousStatus -eq "UNKNOWN") {
                $StatusTracker[$Name].Status = "UP"
                Write-Log "SUCCESS" \$Name "Status awal terhubung: Latensi $($CheckResult.Latency)ms"
            }
            
            # Cek Latensi Tinggi
            if ($CheckResult.Latency -gt$Config.LatencyThresholdMS) {
                if (-not $StatusTracker[$Name].HighLatencyAlerted) {
                    Write-Log "WARNING" \$Name "PERINGATAN LATENSI TINGGI: $($CheckResult.Latency)ms"
                    \$StatusTracker[$Name].HighLatencyAlerted =$true
                }
            } else {
                \$StatusTracker[$Name].HighLatencyAlerted =$false
            }
        }
    }
    
    Start-Sleep -Seconds \$Config.IntervalSeconds
}
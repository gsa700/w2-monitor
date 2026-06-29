<#
  W2 Monitor - desktop monitor for Elecraft W2 RF power / SWR meters
  Version 0.9.0-beta
  Copyright (C) 2026  David Erickson (AB0R)

  Created by David Erickson (AB0R) in collaboration with Claude (Anthropic),
  which did the heavy lifting on the code.

  Each W2 (and each bound CAT radio) runs on its own background runspace so serial
  I/O never blocks the UI. The main window auto-focuses whichever sampler is
  transmitting; a Setup window manages meters, controls, display and logging; a
  Radios window binds a CAT radio (direct serial or Hamlib rigctld) to each sampler
  for live frequency.

  Launch via "Launch W2 Monitor.vbs" (no console) or:
    powershell -ExecutionPolicy Bypass -File W2App.ps1

  This program is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
  PARTICULAR PURPOSE.  See the GNU General Public License for more details. You should
  have received a copy of the GNU General Public License along with this program (see
  the LICENSE file).  If not, see <https://www.gnu.org/licenses/>.

  Elecraft and Kenwood are trademarks of their respective owners. This is an
  independent project, not affiliated with or endorsed by Elecraft, Kenwood, or the
  Hamlib project.
#>
param([string]$Port = 'COM8')

$AppVersion = '0.9.0-beta'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- palette ----------
$cBg    = [System.Drawing.Color]::FromArgb(28,28,30)
$cPanel = [System.Drawing.Color]::FromArgb(44,44,48)
$cTrack = [System.Drawing.Color]::FromArgb(60,60,66)
$cText  = [System.Drawing.Color]::Gainsboro
$cAmber = [System.Drawing.Color]::FromArgb(255,176,0)
$cGreen = [System.Drawing.Color]::FromArgb(60,200,80)
$cRed   = [System.Drawing.Color]::FromArgb(235,70,70)
$cDim   = [System.Drawing.Color]::FromArgb(120,120,128)
$fHdr   = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$fSmall = New-Object System.Drawing.Font('Segoe UI',9)

# runtime glyphs (kept out of the source as literals so file encoding can't corrupt them)
$DASH = [string][char]0x2014
$BULL = [string][char]0x2022

# ---------- script state ----------
$script:meters=@(); $script:focusId=$null; $script:focusMeter=$null; $script:meterSig=''
$script:radios=@(); $script:radioSig=''; $script:radioListLoading=$false
$script:rstep=0; $script:exiting=$false; $script:scaling=$false
$script:stPending=''; $script:stCount=0; $script:flashBtn=$null
$script:tg=@{ pkhold=$false; pep=$false }
$script:fs=200.0; $script:tickN=0; $script:autoLit=$null; $script:ledLit=$null
$script:timeoutSec=180; $script:logTx=$false; $script:logMax=2000; $script:logShown=$false
$script:plotShown=$false; $script:plotLoading=$false; $script:txHang=2.0; $script:txAlertLevel=0
$script:scale=1.05
$show=@{ statusLine=$true; powerBar=$true; swrBar=$true; reflected=$true; returnLoss=$true; peak=$true; tx=$true; freq=$true }

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $scriptDir) { $scriptDir = [Environment]::GetFolderPath('MyDocuments') }
$cfgPath = Join-Path $scriptDir 'W2Monitor.config.json'
$logPath = Join-Path $scriptDir 'W2_TXlog.csv'

# ---------- parse helpers ----------
function Get-Power($r) { if ($r -match '^[FfRr](\d+)D(\d);') { return [int]$matches[1] / [math]::Pow(10,[int]$matches[2]) }; return $null }
function Get-Swr($r)   { if ($r -match '^[Ss](\d+);')        { return [int]$matches[1] / 100.0 }; return $null }
function Get-Ports     { [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object { [int]($_ -replace '\D','') } }
function New-Uid       { 'x' + ([guid]::NewGuid().ToString('N').Substring(0,6)) }
$rangeFS = @{ '1'=2.0; '2'=20.0; '3'=200.0; '4'=2000.0 }
$rangeNm = @{ '1'='2 W'; '2'='20 W'; '3'='200 W'; '4'='2 kW' }
$typeNm  = @{ '0'='HF 200W'; '1'='HF 2 kW'; '2'='VHF/UHF' }

# ---------- W2 meter model + serial worker ----------
$worker = {
  param($sync)
  function ReadUntil($p,$ms) {
    $sb=New-Object System.Text.StringBuilder; $dl=[DateTime]::UtcNow.AddMilliseconds($ms)
    while ([DateTime]::UtcNow -lt $dl) {
      while ($p.BytesToRead -gt 0) { $ch=[char]$p.ReadByte(); [void]$sb.Append($ch); if ($ch -eq ';') { return $sb.ToString() } }
      Start-Sleep -Milliseconds 3
    }
    return $sb.ToString()
  }
  function Query($p,$cmd) { try { $p.DiscardInBuffer(); $p.Write($cmd); return (ReadUntil $p 200) } catch { return '' } }
  $sp=$null
  while (-not $sync.Stop) {
    try {
      if ($sync.DisconnectReq) {
        if ($sp -and $sp.IsOpen) { try { $sp.Close() } catch {} }
        $sp=$null; $sync.Connected=$false; $sync.ConnectTo=$null; $sync.DisconnectReq=$false
      }
      if ($sync.ConnectTo -and ($null -eq $sp -or -not $sp.IsOpen)) {
        try {
          $sp=New-Object System.IO.Ports.SerialPort $sync.ConnectTo,9600,'None',8,'One'
          $sp.ReadTimeout=200; $sp.WriteTimeout=200; $sp.DtrEnable=$true; $sp.RtsEnable=$true
          $sp.Open(); Start-Sleep -Milliseconds 120
          $sync.FW=(Query $sp 'V'); $sync.Connected=$true; $sync.Error=''
        } catch { $sync.Error=$_.Exception.Message; $sync.Connected=$false; $sp=$null; Start-Sleep -Milliseconds 1500 }
      }
      if ($sp -and $sp.IsOpen) {
        while ($sync.Cmds.Count -gt 0) {
          $c=$null; try { $c=$sync.Cmds[0]; $sync.Cmds.RemoveAt(0) } catch {}
          if ($c) { try { $sp.DiscardInBuffer(); $sp.Write([string]$c); [void](ReadUntil $sp 200) } catch {} }
        }
        $sync.F=(Query $sp 'F'); $sync.R=(Query $sp 'R'); $sync.S=(Query $sp 'S'); $sync.I=(Query $sp 'I'); $sync.Stamp=[DateTime]::Now
      }
    } catch { $sync.Error=$_.Exception.Message }
    Start-Sleep -Milliseconds 80
  }
  if ($sp -and $sp.IsOpen) { try { $sp.Close() } catch {} }
}
function New-Meter($id,$name,$port) {
  $st=[hashtable]::Synchronized(@{})
  $st.Stop=$false; $st.ConnectTo=$null; $st.DisconnectReq=$false
  $st.Connected=$false; $st.FW=''; $st.Error=''
  $st.F=''; $st.R=''; $st.S=''; $st.I=''; $st.Stamp=$null
  $st.Cmds=[System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  [pscustomobject]@{
    Id=$id; Name=$name; Port=$port; State=$st; PS=$null; RS=$null; Handle=$null; Peak=0.0
    Tx=@{ active=$false; start=$null; last=$null; peakF=0.0; maxSwr=0.0; sensor=$DASH; range=$DASH; type=$DASH; freq=$null }
    Last=@{ f=$null; r=$null; s=$null; active=$DASH; range=$DASH; type=$DASH; autoOn=$false; ledOn=$false; alarm=$false; fs=200.0; connected=$false }
  }
}
function Start-MeterWorker($m) {
  $m.RS=[runspacefactory]::CreateRunspace(); $m.RS.ApartmentState='MTA'; $m.RS.Open()
  $m.PS=[powershell]::Create(); $m.PS.Runspace=$m.RS
  [void]$m.PS.AddScript($worker).AddArgument($m.State); $m.Handle=$m.PS.BeginInvoke()
}
function Stop-MeterWorker($m) {
  try { $m.State.Stop=$true } catch {}
  try { if ($m.PS) { $m.PS.EndInvoke($m.Handle) } } catch {}
  try { if ($m.PS) { $m.PS.Dispose() }; if ($m.RS) { $m.RS.Close(); $m.RS.Dispose() } } catch {}
}
function Connect-All    { foreach ($m in $script:meters) { if ($m.Port) { $m.State.Error=''; $m.State.ConnectTo=$m.Port } } }
function Disconnect-All { foreach ($m in $script:meters) { $m.State.DisconnectReq=$true } }

# ---------- radio (CAT) model + worker: Kenwood TM-D710 / TM-V71A family ----------
$radioWorker = {
  param($sync)
  function ReadTerm($p,$ms,$term) {
    $sb=New-Object System.Text.StringBuilder; $dl=[DateTime]::UtcNow.AddMilliseconds($ms)
    while ([DateTime]::UtcNow -lt $dl) {
      while ($p.BytesToRead -gt 0) { $b=$p.ReadByte(); if ($b -eq $term) { return $sb.ToString() }; if ($b -ne 10 -and $b -ne 13) { [void]$sb.Append([char]$b) } }
      Start-Sleep -Milliseconds 3
    }
    return $sb.ToString()
  }
  $sp=$null
  while (-not $sync.Stop) {
    try {
      if ($sync.DisconnectReq) {
        if ($sp -and $sp.IsOpen) { try { $sp.Close() } catch {} }
        $sp=$null; $sync.Connected=$false; $sync.ConnectTo=$null; $sync.DisconnectReq=$false; $sync.Freq=$null
      }
      if ($sync.ConnectTo -and ($null -eq $sp -or -not $sp.IsOpen)) {
        try {
          $sp=New-Object System.IO.Ports.SerialPort $sync.ConnectTo,([int]$sync.Baud),'None',8,'One'
          $sp.ReadTimeout=300; $sp.WriteTimeout=300; $sp.DtrEnable=$true; $sp.RtsEnable=$true
          $sp.Open(); Start-Sleep -Milliseconds 120; $sync.Connected=$true; $sync.Error=''
        } catch { $sync.Error=$_.Exception.Message; $sync.Connected=$false; $sp=$null; Start-Sleep -Milliseconds 1500 }
      }
      if ($sp -and $sp.IsOpen) {
        try {
          if ($sync.Proto -eq 'ts2000') {
            # Kenwood TS-2000 / Elecraft / SmartSDR CAT: VFO-A frequency, 11 digits Hz, semicolon-terminated
            $sp.DiscardInBuffer(); $sp.Write('FA;'); $resp=ReadTerm $sp 300 59
            if ($resp -match 'FA(\d{6,12})') { $hz=[double]$matches[1]; $sync.FreqHz=$hz; $sync.Freq=[math]::Round($hz/1e6,4) }
          } else {
            # Kenwood TM-D710 / TM-V71A: read PTT band (BC) then that band's frequency (FO), CR-terminated
            $sp.DiscardInBuffer(); $sp.Write("BC`r"); $bc=ReadTerm $sp 300 13; $ptt='0'; if ($bc -match 'BC\s*(\d)\s*,\s*(\d)') { $ptt=$matches[2] }
            $sp.DiscardInBuffer(); $sp.Write("FO $ptt`r"); $fo=ReadTerm $sp 300 13
            if ($fo -match 'FO\s*\d+\s*,\s*(\d{6,12})') { $hz=[double]$matches[1]; $sync.FreqHz=$hz; $sync.Freq=[math]::Round($hz/1e6,4) }
          }
        } catch {}
      }
    } catch { $sync.Error=$_.Exception.Message }
    Start-Sleep -Milliseconds 350
  }
  if ($sp -and $sp.IsOpen) { try { $sp.Close() } catch {} }
}
$rigctldWorker = {
  param($sync)
  $cli=$null; $stream=$null
  while (-not $sync.Stop) {
    try {
      if ($sync.DisconnectReq) {
        if ($cli) { try { $cli.Close() } catch {} }
        $cli=$null; $stream=$null; $sync.Connected=$false; $sync.ConnectTo=$null; $sync.DisconnectReq=$false; $sync.Freq=$null
      }
      if ($sync.ConnectTo -and ($null -eq $cli -or -not $cli.Connected)) {
        try {
          $hp=([string]$sync.ConnectTo).Split(':'); $h=$hp[0].Trim(); $pt= if ($hp.Count -ge 2 -and $hp[1]) { [int]$hp[1] } else { 4532 }
          $cli=New-Object System.Net.Sockets.TcpClient
          $iar=$cli.BeginConnect($h,$pt,$null,$null)
          if (-not $iar.AsyncWaitHandle.WaitOne(800)) { throw 'connect timeout' }
          $cli.EndConnect($iar); $cli.ReceiveTimeout=600; $cli.SendTimeout=600
          $stream=$cli.GetStream(); $sync.Connected=$true; $sync.Error=''
        } catch { $sync.Error=$_.Exception.Message; $sync.Connected=$false; if ($cli) { try { $cli.Close() } catch {} }; $cli=$null; $stream=$null; Start-Sleep -Milliseconds 1500 }
      }
      if ($cli -and $cli.Connected -and $stream) {
        try {
          $out=[System.Text.Encoding]::ASCII.GetBytes("f`n"); $stream.Write($out,0,$out.Length); $stream.Flush()
          $sb=New-Object System.Text.StringBuilder; $buf=New-Object byte[] 256; $dl=[DateTime]::UtcNow.AddMilliseconds(500)
          while ([DateTime]::UtcNow -lt $dl) {
            if ($stream.DataAvailable) { $n=$stream.Read($buf,0,$buf.Length); if ($n -gt 0) { [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf,0,$n)) }; if ($sb.ToString() -match "`n") { break } }
            else { Start-Sleep -Milliseconds 10 }
          }
          $resp=$sb.ToString()
          if ($resp -match '(?m)^\s*(\d{4,})\s*$') { $hz=[double]$matches[1]; $sync.FreqHz=$hz; $sync.Freq=[math]::Round($hz/1e6,4) }
          elseif ($resp -match '(\d{5,})') { $hz=[double]$matches[1]; $sync.FreqHz=$hz; $sync.Freq=[math]::Round($hz/1e6,4) }
        } catch { $sync.Error=$_.Exception.Message; if ($cli) { try { $cli.Close() } catch {} }; $cli=$null; $stream=$null; $sync.Connected=$false }
      }
    } catch { $sync.Error=$_.Exception.Message }
    Start-Sleep -Milliseconds 400
  }
  if ($cli) { try { $cli.Close() } catch {} }
}
function New-Radio($id,$meterId,$sampler,$port,$baud,$proto,$name) {
  $st=[hashtable]::Synchronized(@{})
  $st.Stop=$false; $st.ConnectTo=$null; $st.DisconnectReq=$false; $st.Connected=$false; $st.Error=''
  $st.Freq=$null; $st.FreqHz=0.0; $st.Baud=[int]$baud; $st.Proto=$proto
  [pscustomobject]@{ Id=$id; MeterId=[string]$meterId; Sampler=[string]$sampler; Port=$port; Baud=[int]$baud; Proto=$proto; Name=$name; State=$st; PS=$null; RS=$null; Handle=$null }
}
function Start-RadioWorker($r) {
  $rscript = if ($r.Proto -eq 'rigctld') { $rigctldWorker } else { $radioWorker }
  $r.RS=[runspacefactory]::CreateRunspace(); $r.RS.ApartmentState='MTA'; $r.RS.Open()
  $r.PS=[powershell]::Create(); $r.PS.Runspace=$r.RS
  [void]$r.PS.AddScript($rscript).AddArgument($r.State); $r.Handle=$r.PS.BeginInvoke()
}
function Stop-RadioWorker($r) {
  try { $r.State.Stop=$true } catch {}
  try { if ($r.PS) { $r.PS.EndInvoke($r.Handle) } } catch {}
  try { if ($r.PS) { $r.PS.Dispose() }; if ($r.RS) { $r.RS.Close(); $r.RS.Dispose() } } catch {}
}
function Connect-AllRadios { foreach ($r in $script:radios) { if ($r.Port) { $r.State.Error=''; $r.State.Baud=[int]$r.Baud; $r.State.ConnectTo=$r.Port } } }
function Get-RadioFor($meterId,$samplerNum) { return (@($script:radios | Where-Object { $_.MeterId -eq $meterId -and $_.Sampler -eq $samplerNum }))[0] }

# ---------- control factories ----------
function New-Label($parent,$text,$x,$y,$w,$h,$font,$color,[string]$align='MiddleLeft') {
  $l = New-Object System.Windows.Forms.Label
  $l.Text=$text; $l.Location=(P $x $y); $l.Size=(Z $w $h); $l.Font=$font; $l.ForeColor=$color
  $l.BackColor=[System.Drawing.Color]::Transparent; $l.TextAlign=$align
  $parent.Controls.Add($l); return $l
}
function New-Bar($parent,$fillColor) {
  $t = New-Object System.Windows.Forms.Panel
  $t.Location=(P 0 0); $t.Size=(Z 10 14); $t.BackColor=$cTrack
  $f = New-Object System.Windows.Forms.Panel
  $f.Location=(P 0 0); $f.Size=(Z 0 14); $f.BackColor=$fillColor
  $t.Controls.Add($f); $parent.Controls.Add($t); return $f
}
function New-Button($parent,$text,$x,$y,$w,$h=34) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text=$text; $b.Location=(P $x $y); $b.Size=(Z $w $h)
  $b.FlatStyle='Flat'; $b.BackColor=$cPanel; $b.ForeColor=$cText; $b.Font=$fSmall
  $b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(80,80,86)
  $parent.Controls.Add($b); return $b
}
function New-Check($parent,$text,$x,$y) {
  $c = New-Object System.Windows.Forms.CheckBox
  $c.Text=$text; $c.Location=(P $x $y); $c.Size=(Z 300 22)
  $c.ForeColor=$cText; $c.Font=$fSmall; $parent.Controls.Add($c); return $c
}
function New-Combo($parent,$x,$y,$w) {
  $c = New-Object System.Windows.Forms.ComboBox
  $c.DropDownStyle='DropDownList'; $c.Location=(P $x $y); $c.Size=(Z $w 24)
  $c.BackColor=$cPanel; $c.ForeColor=$cText; $c.FlatStyle='Flat'; $parent.Controls.Add($c); return $c
}

# ---------- geometry / font scaling ----------
function S($n) { [int][math]::Round([double]$n * $script:scale) }
function P($x,$y) { New-Object System.Drawing.Point([int]$x,[int]$y) }
function Z($w,$h) { New-Object System.Drawing.Size([int]$w,[int]$h) }
function Build-MainFonts {
  $sc=$script:scale
  $script:fTitle =New-Object System.Drawing.Font('Segoe UI',(15*$sc),[System.Drawing.FontStyle]::Bold)
  $script:fStat  =New-Object System.Drawing.Font('Segoe UI',(10*$sc),[System.Drawing.FontStyle]::Bold)
  $script:fCap   =New-Object System.Drawing.Font('Segoe UI',(8.5*$sc),[System.Drawing.FontStyle]::Bold)
  $script:fBig   =New-Object System.Drawing.Font('Consolas',(30*$sc),[System.Drawing.FontStyle]::Bold)
  $script:fMed   =New-Object System.Drawing.Font('Consolas',(16*$sc),[System.Drawing.FontStyle]::Bold)
  $script:fSmallM=New-Object System.Drawing.Font('Segoe UI',(9*$sc))
}
Build-MainFonts

# ---------- main window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text="W2 Monitor v$AppVersion"; $form.ClientSize=(Z 462 380)
$form.StartPosition='CenterScreen'; $form.FormBorderStyle='Sizable'
$form.MaximizeBox=$false; $form.BackColor=$cBg; $form.MinimumSize=(Z 340 220)

$titleLbl = New-Label $form 'W2 MONITOR' 0 0 10 10 $fTitle $cAmber
$fwLbl    = New-Label $form "FW $DASH" 0 0 10 10 $fSmallM $cDim 'MiddleRight'
$dot      = New-Object System.Windows.Forms.Panel; $dot.Size=(Z 12 12); $dot.BackColor=$cDim; $form.Controls.Add($dot)
$setupBtn = New-Button $form 'Setup' 0 0 92 30; $setupBtn.Font=$fSmallM

$statusLbl = New-Label $form 'Disconnected' 0 0 10 10 $fStat $cText 'MiddleCenter'
$fwdCap = New-Label $form 'FORWARD POWER' 0 0 10 10 $fCap $cDim
$swrCap = New-Label $form 'SWR' 0 0 10 10 $fCap $cDim
$fwdVal = New-Label $form "$DASH W" 0 0 10 10 $fBig $cAmber
$swrVal = New-Label $form "$DASH" 0 0 10 10 $fBig $cDim
$fwdBar = New-Bar $form $cAmber
$swrBar = New-Bar $form $cGreen
$freqCap = New-Label $form 'FREQUENCY' 0 0 10 10 $fCap $cDim
$freqVal = New-Label $form "$DASH" 0 0 10 10 $fMed $cText 'MiddleRight'
$revCap = New-Label $form 'REFLECTED POWER' 0 0 10 10 $fCap $cDim
$revVal = New-Label $form "$DASH W" 0 0 10 10 $fMed $cText 'MiddleRight'
$rlCap  = New-Label $form 'RETURN LOSS' 0 0 10 10 $fCap $cDim
$rlVal  = New-Label $form "$DASH dB" 0 0 10 10 $fMed $cText 'MiddleRight'
$pkCap  = New-Label $form 'PEAK FORWARD' 0 0 10 10 $fCap $cDim
$pkVal  = New-Label $form "$DASH W" 0 0 10 10 $fMed $cGreen 'MiddleRight'
$txCap  = New-Label $form 'TX TIMER' 0 0 10 10 $fCap $cDim
$txVal  = New-Label $form '0:00' 0 0 10 10 $fMed $cDim 'MiddleRight'

# ---------- setup / options window (fixed size) ----------
$opt = New-Object System.Windows.Forms.Form
$opt.Text='W2 Setup'; $opt.ClientSize=(Z 372 724)
$opt.FormBorderStyle='FixedSingle'; $opt.MaximizeBox=$false; $opt.MinimizeBox=$false
$opt.BackColor=$cBg; $opt.ShowInTaskbar=$false; $opt.StartPosition='Manual'

New-Label $opt 'METERS (W2)' 16 12 200 18 $fHdr $cAmber | Out-Null
New-Label $opt "v$AppVersion" 226 13 130 16 $fSmall $cDim 'MiddleRight' | Out-Null
$meterList = New-Object System.Windows.Forms.ListBox
$meterList.Location=(P 16 34); $meterList.Size=(Z 244 84); $meterList.BackColor=$cPanel; $meterList.ForeColor=$cText
$meterList.BorderStyle='FixedSingle'; $meterList.Font=$fSmall; $meterList.IntegralHeight=$false; $opt.Controls.Add($meterList)
$addBtn    = New-Button $opt 'Add'    268 34 88 26
$removeBtn = New-Button $opt 'Remove' 268 64 88 26
$detectBtn = New-Button $opt 'Detect' 268 94 88 26
New-Label $opt 'Assign port:' 16 126 90 24 $fSmall $cText | Out-Null
$combo = New-Combo $opt 110 123 140
$refreshBtn = New-Button $opt 'Refresh' 258 122 98 26
$connectBtn = New-Button $opt 'Connect' 16 156 120 28
$optStatus  = New-Label $opt "Disconnected.`r`nAdd a meter and press Connect." 146 148 214 54 $fSmall $cDim 'TopLeft'

New-Label $opt 'W2 CONTROLS' 16 206 200 18 $fHdr $cAmber | Out-Null
$btnSensor = New-Button $opt 'Switch Sensor' 16 230 110
$btnAuto   = New-Button $opt 'Auto Range'    132 230 110
$btnRange  = New-Button $opt 'Range'         248 230 108
$btnPkHold = New-Button $opt 'Pk-Hold LED'   16 270 110
$btnAvg    = New-Button $opt 'Avg / PEP'     132 270 110
$btnLeds   = New-Button $opt 'LEDs On/Off'   248 270 108
$btnReset  = New-Button $opt 'Reset Peak'    16 310 110
$topMost   = New-Check  $opt 'Always on top' 132 314
$cmdButtons = @($btnSensor,$btnAuto,$btnRange,$btnPkHold,$btnAvg,$btnLeds)

New-Label $opt 'DISPLAY' 16 350 200 18 $fHdr $cAmber | Out-Null
$cbStatus = New-Check $opt 'Status line'        16 372
$cbPwrBar = New-Check $opt 'Forward power bar'  16 396
$cbSwrBar = New-Check $opt 'SWR bar'            16 420
$cbRefl   = New-Check $opt 'Reflected power'    16 444
$cbRl     = New-Check $opt 'Return loss'        16 468
$cbPeak   = New-Check $opt 'Peak forward'       16 492
$cbTx     = New-Check $opt 'TX timer'           16 516
$cbFreq   = New-Check $opt 'Frequency'          16 540
New-Label $opt 'TX timeout (sec)' 16 570 120 24 $fSmall $cText | Out-Null
$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Location=(P 140 567); $numTimeout.Size=(Z 80 24); $numTimeout.Minimum=30; $numTimeout.Maximum=1800; $numTimeout.Increment=15
$numTimeout.BackColor=$cPanel; $numTimeout.ForeColor=$cText; $numTimeout.BorderStyle='FixedSingle'; $opt.Controls.Add($numTimeout)
New-Label $opt 'LOGGING' 16 600 200 18 $fHdr $cAmber | Out-Null
$cbLog      = New-Check  $opt 'Log each TX' 16 624; $cbLog.Size=(Z 200 22)
$viewLogBtn = New-Button $opt 'View Log' 236 620 120 28
$closeBtn   = New-Button $opt 'Close'     16 656 120 30
$radiosBtn  = New-Button $opt 'Radios...' 146 656 120 30
New-Label $opt "W2 Monitor v$AppVersion   $BULL   GPLv3   $BULL   AB0R + Claude" 16 696 344 22 $fSmall $cDim 'MiddleLeft' | Out-Null

# ---------- radios window ----------
$radioForm = New-Object System.Windows.Forms.Form
$radioForm.Text='W2 Radio Bindings'; $radioForm.ClientSize=(Z 524 396)
$radioForm.FormBorderStyle='FixedSingle'; $radioForm.MaximizeBox=$false; $radioForm.MinimizeBox=$false
$radioForm.BackColor=$cBg; $radioForm.ShowInTaskbar=$false; $radioForm.StartPosition='Manual'
New-Label $radioForm 'RADIO BINDINGS (one per sampler)' 16 12 400 18 $fHdr $cAmber | Out-Null
$radioList = New-Object System.Windows.Forms.ListBox
$radioList.Location=(P 16 36); $radioList.Size=(Z 492 150); $radioList.BackColor=$cPanel; $radioList.ForeColor=$cText
$radioList.BorderStyle='FixedSingle'; $radioList.Font=$fSmall; $radioList.IntegralHeight=$false; $radioForm.Controls.Add($radioList)
New-Label $radioForm 'Meter:' 16 199 50 22 $fSmall $cText | Out-Null
$rMeter   = New-Combo $radioForm 68 196 130
New-Label $radioForm 'Sampler:' 210 199 56 22 $fSmall $cText | Out-Null
$rSampler = New-Combo $radioForm 268 196 70
New-Label $radioForm 'Port:' 16 235 50 22 $fSmall $cText | Out-Null
$rPort    = New-Combo $radioForm 68 232 130; $rPort.DropDownStyle='DropDown'
New-Label $radioForm 'Baud:' 210 235 45 22 $fSmall $cText | Out-Null
$rBaud    = New-Combo $radioForm 268 232 90
New-Label $radioForm 'Protocol:' 16 271 60 22 $fSmall $cText | Out-Null
$rProto   = New-Combo $radioForm 80 268 320
$rAdd     = New-Button $radioForm 'Add / Update' 16 308 130
$rRemove  = New-Button $radioForm 'Remove' 156 308 100
$rPorts   = New-Button $radioForm 'Refresh Ports' 266 308 120
$rClose   = New-Button $radioForm 'Close' 408 308 100
New-Label $radioForm 'Serial: TM-D710/V71A 57600 8N1; TS-2000/Elecraft/SmartSDR CAT any baud.  rigctld: Port = host:port (e.g. 127.0.0.1:4532) shares one rig across apps.' 16 348 492 40 $fSmall $cDim 'TopLeft' | Out-Null
foreach ($sv in 'S1','S2') { [void]$rSampler.Items.Add($sv) }; $rSampler.SelectedIndex=0
foreach ($bv in 4800,9600,19200,38400,57600,115200) { [void]$rBaud.Items.Add($bv) }; $rBaud.SelectedItem=57600
foreach ($pv in 'Kenwood TM-D710 / V71A','Kenwood TS-2000 / Elecraft / SmartSDR CAT','Hamlib rigctld (network: host:port)') { [void]$rProto.Items.Add($pv) }; $rProto.SelectedIndex=0

# ---------- log reader window ----------
$logForm = New-Object System.Windows.Forms.Form
$logForm.Text='W2 Transmission Log'; $logForm.ClientSize=(Z 720 440)
$logForm.FormBorderStyle='Sizable'; $logForm.MaximizeBox=$true; $logForm.MinimizeBox=$false
$logForm.BackColor=$cBg; $logForm.ShowInTaskbar=$false; $logForm.StartPosition='Manual'; $logForm.MinimumSize=(Z 440 260)
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock='Fill'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToResizeRows=$false
$grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='AllCells'; $grid.SelectionMode='FullRowSelect'
$grid.BackgroundColor=$cBg; $grid.BorderStyle='None'; $grid.EnableHeadersVisualStyles=$false; $grid.GridColor=$cTrack; $grid.Font=$fSmall
$grid.DefaultCellStyle.BackColor=$cPanel; $grid.DefaultCellStyle.ForeColor=$cText
$grid.DefaultCellStyle.SelectionBackColor=$cAmber; $grid.DefaultCellStyle.SelectionForeColor=[System.Drawing.Color]::FromArgb(28,28,30)
$grid.ColumnHeadersDefaultCellStyle.BackColor=$cBg; $grid.ColumnHeadersDefaultCellStyle.ForeColor=$cAmber
$logForm.Controls.Add($grid)
$logBar = New-Object System.Windows.Forms.Panel; $logBar.Dock='Bottom'; $logBar.Height=44; $logBar.BackColor=$cBg
$excelBtn      = New-Button $logBar 'Open in Excel' 12 7 130 30
$refreshLogBtn = New-Button $logBar 'Refresh' 150 7 84 30
$plotBtn       = New-Button $logBar 'SWR Plot' 242 7 96 30
$logCloseBtn   = New-Button $logBar 'Close' 346 7 80 30
$logCountLbl   = New-Label  $logBar '' 438 7 280 30 $fSmall $cDim 'MiddleLeft'
$logForm.Controls.Add($logBar)

# ---------- SWR vs frequency plot window ----------
$plotForm = New-Object System.Windows.Forms.Form
$plotForm.Text='SWR vs Frequency'; $plotForm.ClientSize=(Z 760 480)
$plotForm.FormBorderStyle='Sizable'; $plotForm.MaximizeBox=$true; $plotForm.MinimizeBox=$false
$plotForm.BackColor=$cBg; $plotForm.ShowInTaskbar=$false; $plotForm.StartPosition='Manual'; $plotForm.MinimumSize=(Z 520 360)
$plotBar = New-Object System.Windows.Forms.Panel; $plotBar.Dock='Top'; $plotBar.Height=38; $plotBar.BackColor=$cBg
New-Label $plotBar 'Antenna:' 12 9 58 22 $fSmall $cText | Out-Null
$plotFilter = New-Combo $plotBar 72 8 230
$plotRefresh = New-Button $plotBar 'Refresh' 312 6 90 26
$plotCountLbl = New-Label $plotBar '' 412 6 330 26 $fSmall $cDim 'MiddleLeft'
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock='Fill'; $pic.BackColor=$cBg; $pic.SizeMode='Normal'
$plotForm.Controls.Add($pic)
$plotForm.Controls.Add($plotBar)

# ---------- font + layout ----------
function Apply-MainFonts {
  $titleLbl.Font=$fTitle; $fwLbl.Font=$fSmallM; $setupBtn.Font=$fSmallM; $statusLbl.Font=$fStat
  $fwdCap.Font=$fCap; $swrCap.Font=$fCap; $freqCap.Font=$fCap; $revCap.Font=$fCap; $rlCap.Font=$fCap; $pkCap.Font=$fCap; $txCap.Font=$fCap
  $fwdVal.Font=$fBig; $swrVal.Font=$fBig
  $freqVal.Font=$fMed; $revVal.Font=$fMed; $rlVal.Font=$fMed; $pkVal.Font=$fMed; $txVal.Font=$fMed
}
function Update-Layout {
  $script:scaling=$true
  $cw=S 462
  $titleLbl.Location=(P (S 16) (S 12)); $titleLbl.Size=(Z (S 210) (S 28))
  $setupBtn.Size=(Z (S 92) (S 30)); $setupBtn.Location=(P ($cw-(S 92)-(S 16)) (S 12))
  $dot.Size=(Z (S 12) (S 12)); $dot.Location=(P ($setupBtn.Left-(S 24)) (S 22))
  $fwLbl.Size=(Z (S 150) (S 18)); $fwLbl.Location=(P ($dot.Left-(S 150)-(S 8)) (S 16))

  $y=S 46
  if ($show.statusLine) { $statusLbl.Visible=$true; $statusLbl.Location=(P (S 16) $y); $statusLbl.Size=(Z ($cw-(S 32)) (S 22)); $y+=S 30 } else { $statusLbl.Visible=$false }

  $colL=S 16; $colR=[int]($cw/2)+(S 6); $colW=[int]($cw/2)-(S 22)
  $fwdCap.Location=(P $colL $y); $fwdCap.Size=(Z $colW (S 18)); $swrCap.Location=(P $colR $y); $swrCap.Size=(Z $colW (S 18))
  $fwdVal.Location=(P $colL ($y+(S 18))); $fwdVal.Size=(Z $colW (S 50)); $swrVal.Location=(P $colR ($y+(S 18))); $swrVal.Size=(Z $colW (S 50))
  $by=$y+(S 72); $anyBar=$false
  if ($show.powerBar) { $t=$fwdBar.Parent; $t.Visible=$true; $t.Size=(Z $colW (S 14)); $t.Location=(P $colL $by); $fwdBar.Height=(S 14); $anyBar=$true } else { $fwdBar.Parent.Visible=$false }
  if ($show.swrBar)   { $t=$swrBar.Parent; $t.Visible=$true; $t.Size=(Z $colW (S 14)); $t.Location=(P $colR $by); $swrBar.Height=(S 14); $anyBar=$true } else { $swrBar.Parent.Visible=$false }
  $y=$by + $(if ($anyBar) { S 24 } else { S 6 })

  foreach ($row in @(
      @{on=$show.freq;       cap=$freqCap; val=$freqVal},
      @{on=$show.tx;         cap=$txCap;  val=$txVal},
      @{on=$show.reflected;  cap=$revCap; val=$revVal},
      @{on=$show.returnLoss; cap=$rlCap;  val=$rlVal},
      @{on=$show.peak;       cap=$pkCap;  val=$pkVal})) {
    if ($row.on) {
      $row.cap.Visible=$true; $row.val.Visible=$true
      $row.cap.Location=(P (S 16) $y); $row.cap.Size=(Z (S 180) (S 24))
      $row.val.Location=(P (S 204) $y); $row.val.Size=(Z ($cw-(S 204)-(S 16)) (S 24))
      $y+=S 32
    } else { $row.cap.Visible=$false; $row.val.Visible=$false }
  }
  $form.ClientSize=(Z $cw ($y+(S 12)))
  $script:scaling=$false
}

function Set-Cmds($on) { foreach ($b in $cmdButtons) { $b.Enabled = $on } }
function Set-Text($lbl,$txt) { if ($lbl.Text -ne $txt) { $lbl.Text=$txt } }
function Style-Btn($b,$on) {
  if ($on) { $b.BackColor=$cAmber; $b.ForeColor=[System.Drawing.Color]::FromArgb(28,28,30); $b.FlatAppearance.BorderColor=$cAmber }
  else     { $b.BackColor=$cPanel; $b.ForeColor=$cText; $b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(80,80,86) }
}
$flashTimer = New-Object System.Windows.Forms.Timer
$flashTimer.Interval=200
$flashTimer.Add_Tick({ $flashTimer.Stop(); if ($script:flashBtn) { Style-Btn $script:flashBtn $false; $script:flashBtn=$null } })
function Flash-Btn($b) { if ($script:flashBtn) { Style-Btn $script:flashBtn $false }; Style-Btn $b $true; $script:flashBtn=$b; $flashTimer.Stop(); $flashTimer.Start() }

function Save-Config {
  try {
    $cfg = [ordered]@{
      x=$form.Location.X; y=$form.Location.Y; scale=$script:scale; topMost=$topMost.Checked
      meters=@($script:meters | ForEach-Object { [ordered]@{ id=$_.Id; name=$_.Name; port=$_.Port } })
      radios=@($script:radios | ForEach-Object { [ordered]@{ meterId=$_.MeterId; sampler=$_.Sampler; port=$_.Port; baud=$_.Baud; proto=$_.Proto; name=$_.Name } })
      timeoutSec=$script:timeoutSec; logTx=$script:logTx
      show=[ordered]@{ statusLine=$show.statusLine; powerBar=$show.powerBar; swrBar=$show.swrBar; reflected=$show.reflected; returnLoss=$show.returnLoss; peak=$show.peak; tx=$show.tx; freq=$show.freq }
    }
    if ($script:logShown) { $cfg.logX=$logForm.Location.X; $cfg.logY=$logForm.Location.Y; $cfg.logW=$logForm.Width; $cfg.logH=$logForm.Height }
    if ($script:plotShown) { $cfg.plotX=$plotForm.Location.X; $cfg.plotY=$plotForm.Location.Y; $cfg.plotW=$plotForm.Width; $cfg.plotH=$plotForm.Height }
    ($cfg | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8
  } catch {}
}
function Load-Config {
  if (-not (Test-Path $cfgPath)) { return }
  try {
    $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($null -ne $c.scale) { $script:scale=[math]::Max(0.8,[math]::Min(3.0,[double]$c.scale)) }
    if ($null -ne $c.timeoutSec) { $script:timeoutSec=[math]::Max(30,[math]::Min(1800,[int]$c.timeoutSec)) }
    if ($null -ne $c.logTx) { $script:logTx=[bool]$c.logTx }
    if ($c.show) { foreach ($k in 'statusLine','powerBar','swrBar','reflected','returnLoss','peak','tx','freq') { if ($null -ne $c.show.$k) { $show[$k]=[bool]$c.show.$k } } }
    if ($c.meters) {
      foreach ($mc in $c.meters) {
        $id = if ($mc.id) { [string]$mc.id } else { (New-Uid) }
        $nm = if ($mc.name) { [string]$mc.name } else { 'W2' }
        $pt = if ($mc.port) { [string]$mc.port } else { '' }
        $script:meters += (New-Meter $id $nm $pt)
      }
    } elseif ($c.port) {
      $script:meters += (New-Meter 'm1' 'W2 #1' ([string]$c.port))
    }
    if ($c.radios) {
      foreach ($rc in $c.radios) {
        $rp = if ($rc.port) { [string]$rc.port } else { '' }
        $rb = if ($rc.baud) { [int]$rc.baud } else { 57600 }
        $rsm = if ($rc.sampler) { [string]$rc.sampler } else { '1' }
        $rpr = if ($rc.proto) { [string]$rc.proto } else { 'kenwood' }
        $rnm = if ($rc.name) { [string]$rc.name } else { 'Radio' }
        $script:radios += (New-Radio (New-Uid) ([string]$rc.meterId) $rsm $rp $rb $rpr $rnm)
      }
    }
    if ($null -ne $c.topMost) { $topMost.Checked=[bool]$c.topMost; $form.TopMost=[bool]$c.topMost }
    if ($null -ne $c.x -and $null -ne $c.y) {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      if ([int]$c.x -ge $vs.Left -and [int]$c.y -ge $vs.Top -and [int]$c.x -lt ($vs.Right-60) -and [int]$c.y -lt ($vs.Bottom-60)) {
        $form.StartPosition='Manual'; $form.Location=(P ([int]$c.x) ([int]$c.y))
      }
    }
    if ($null -ne $c.logX -and $null -ne $c.logY -and $null -ne $c.logW -and $null -ne $c.logH) {
      $vs2=[System.Windows.Forms.SystemInformation]::VirtualScreen
      if ([int]$c.logX -ge $vs2.Left -and [int]$c.logY -ge $vs2.Top -and [int]$c.logX -lt ($vs2.Right-60) -and [int]$c.logY -lt ($vs2.Bottom-60)) {
        $logForm.Size=(Z ([math]::Max(440,[int]$c.logW)) ([math]::Max(260,[int]$c.logH))); $logForm.Location=(P ([int]$c.logX) ([int]$c.logY)); $script:logShown=$true
      }
    }
    if ($null -ne $c.plotX -and $null -ne $c.plotY -and $null -ne $c.plotW -and $null -ne $c.plotH) {
      $vs3=[System.Windows.Forms.SystemInformation]::VirtualScreen
      if ([int]$c.plotX -ge $vs3.Left -and [int]$c.plotY -ge $vs3.Top -and [int]$c.plotX -lt ($vs3.Right-60) -and [int]$c.plotY -lt ($vs3.Bottom-60)) {
        $plotForm.Size=(Z ([math]::Max(520,[int]$c.plotW)) ([math]::Max(360,[int]$c.plotH))); $plotForm.Location=(P ([int]$c.plotX) ([int]$c.plotY)); $script:plotShown=$true
      }
    }
  } catch {}
}

function Write-TxLog($meter,$freq,$startT,$dur,$pk,$swr,$sensor,$range,$type,$timedout) {
  try {
    $hdr='Timestamp,Meter,Freq_MHz,Duration_s,PeakFwd_W,MaxSWR,MinReturnLoss_dB,Sensor,Range,SensorType,TimedOut'
    if (Test-Path $logPath) {
      $first = Get-Content $logPath -TotalCount 1
      if ($first -ne $hdr) { try { Move-Item $logPath ($logPath -replace '\.csv$',('_'+(Get-Date -Format 'yyyyMMddHHmmss')+'.csv')) -Force } catch {} }
    }
    if (-not (Test-Path $logPath)) { $hdr | Set-Content -Path $logPath -Encoding UTF8 }
    $rl = if ($swr -gt 1) { '{0:N1}' -f (-20*[math]::Log10(($swr-1)/($swr+1))) } else { '' }
    $fq = if ($freq) { '{0:N4}' -f $freq } else { '' }
    $row = '{0},{1},{2},{3},{4:N1},{5:N2},{6},{7},{8},{9},{10}' -f $startT.ToString('yyyy-MM-dd HH:mm:ss'),$meter,$fq,$dur,$pk,$swr,$rl,$sensor,$range,$type,$(if ($timedout) {'yes'} else {'no'})
    Add-Content -Path $logPath -Value $row -Encoding UTF8
    $lines = @(Get-Content $logPath | Where-Object { $_ -ne '' })
    if (($lines.Count-1) -gt $script:logMax) {
      $kept = @($lines[0]) + @($lines[($lines.Count-$script:logMax)..($lines.Count-1)])
      Set-Content -Path $logPath -Value $kept -Encoding UTF8
    }
  } catch {}
}

function Load-LogGrid {
  $grid.SuspendLayout(); $grid.Rows.Clear(); $grid.Columns.Clear()
  if (Test-Path $logPath) {
    $lines = @(Get-Content $logPath | Where-Object { $_ -ne '' })
    if ($lines.Count -ge 1) {
      foreach ($h in $lines[0].Split(',')) { $ci=$grid.Columns.Add($h,$h); $grid.Columns[$ci].SortMode='NotSortable' }
      for ($k=$lines.Count-1; $k -ge 1; $k--) { [void]$grid.Rows.Add($lines[$k].Split(',')) }
      $logCountLbl.Text = "$($lines.Count-1) transmissions (newest first)"
    }
  } else { $logCountLbl.Text='No log file yet.' }
  $grid.ResumeLayout()
}

# ---------- SWR vs frequency plot ----------
$plotColors = @(
  [System.Drawing.Color]::FromArgb(255,176,0),  [System.Drawing.Color]::FromArgb(60,200,80),
  [System.Drawing.Color]::FromArgb(90,170,255), [System.Drawing.Color]::FromArgb(235,90,200),
  [System.Drawing.Color]::FromArgb(80,210,210), [System.Drawing.Color]::FromArgb(235,130,60),
  [System.Drawing.Color]::FromArgb(180,140,255),[System.Drawing.Color]::FromArgb(200,200,90)
)
function Get-LogPoints {
  $pts=@()
  if (-not (Test-Path $logPath)) { return ,$pts }
  $lines=@(Get-Content $logPath | Where-Object { $_ -ne '' })
  if ($lines.Count -lt 2) { return ,$pts }
  $hdr=$lines[0].Split(','); $iF=[array]::IndexOf($hdr,'Freq_MHz'); $iS=[array]::IndexOf($hdr,'MaxSWR'); $iM=[array]::IndexOf($hdr,'Meter'); $iSe=[array]::IndexOf($hdr,'Sensor')
  if ($iF -lt 0 -or $iS -lt 0) { return ,$pts }
  for ($k=1; $k -lt $lines.Count; $k++) {
    $c=$lines[$k].Split(','); if ($c.Count -le [math]::Max($iF,$iS)) { continue }
    $f=0.0; $s=0.0
    if (-not [double]::TryParse($c[$iF],[ref]$f)) { continue }
    if (-not [double]::TryParse($c[$iS],[ref]$s)) { continue }
    if ($f -le 0) { continue }
    $mn= if ($iM -ge 0 -and $c.Count -gt $iM -and $c[$iM]) { $c[$iM] } else { '?' }
    $se= if ($iSe -ge 0 -and $c.Count -gt $iSe -and $c[$iSe]) { $c[$iSe] } else { '?' }
    $pts += [pscustomobject]@{ Freq=$f; Swr=$s; Key="$mn / $se" }
  }
  return ,$pts
}
function Populate-PlotFilter {
  $sel=[string]$plotFilter.SelectedItem
  $keys=@(Get-LogPoints | Select-Object -ExpandProperty Key -Unique | Sort-Object)
  $script:plotLoading=$true
  $plotFilter.Items.Clear(); [void]$plotFilter.Items.Add('All antennas')
  foreach ($k in $keys) { [void]$plotFilter.Items.Add($k) }
  if ($sel -and $plotFilter.Items.Contains($sel)) { $plotFilter.SelectedItem=$sel } else { $plotFilter.SelectedIndex=0 }
  $script:plotLoading=$false
}
function Render-Plot {
  $w=[math]::Max(200,$pic.ClientSize.Width); $h=[math]::Max(150,$pic.ClientSize.Height)
  $bmp=New-Object System.Drawing.Bitmap($w,$h)
  $g=[System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'; $g.Clear($cBg)
  $all=@(Get-LogPoints)
  $filter=[string]$plotFilter.SelectedItem
  $pts = if ($filter -and $filter -ne 'All antennas') { @($all | Where-Object { $_.Key -eq $filter }) } else { $all }
  $lblBr=New-Object System.Drawing.SolidBrush($cDim); $fnt=New-Object System.Drawing.Font('Segoe UI',8)
  $ml=58; $mr=170; $mt=16; $mb=46; $px0=$ml; $py0=$mt; $pw=$w-$ml-$mr; $ph=$h-$mt-$mb
  $plotCountLbl.Text = "$($pts.Count) point(s)" + $(if ($filter -and $filter -ne 'All antennas') { " $BULL $filter" } else { " $BULL all antennas" })
  if ($pw -lt 60 -or $ph -lt 60) { $g.Dispose(); return $bmp }
  if ($pts.Count -eq 0) {
    $g.DrawString('No logged transmissions with frequency + SWR yet.',(New-Object System.Drawing.Font('Segoe UI',11)),$lblBr,[float]($px0+10),[float]($py0+10))
    $g.Dispose(); return $bmp
  }
  $fmin=($pts|Measure-Object Freq -Minimum).Minimum; $fmax=($pts|Measure-Object Freq -Maximum).Maximum
  if ($fmax-$fmin -lt 0.0005) { $fmin-=0.05; $fmax+=0.05 }
  $fp=($fmax-$fmin)*0.08; $fmin-=$fp; $fmax+=$fp
  $smin=1.0; $smax=[math]::Max(2.5,([double](($pts|Measure-Object Swr -Maximum).Maximum))*1.12)
  $fr=$fmax-$fmin; $sr=$smax-$smin
  $gridPen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,45,45,50),1)
  $step= if ($smax -le 3) { 0.5 } elseif ($smax -le 6) { 1.0 } else { 2.0 }
  for ($sv=1.0; $sv -le $smax+0.001; $sv+=$step) {
    $yy=$py0+$ph-($sv-$smin)/$sr*$ph
    $g.DrawLine($gridPen,[float]$px0,[float]$yy,[float]($px0+$pw),[float]$yy)
    $g.DrawString(('{0:N1}' -f $sv),$fnt,$lblBr,[float]($px0-34),[float]($yy-7))
  }
  for ($i=0; $i -le 5; $i++) {
    $fv=$fmin+$fr*$i/5.0; $xx=$px0+($fv-$fmin)/$fr*$pw
    $g.DrawLine($gridPen,[float]$xx,[float]$py0,[float]$xx,[float]($py0+$ph))
    $g.DrawString(('{0:N3}' -f $fv),$fnt,$lblBr,[float]($xx-22),[float]($py0+$ph+6))
  }
  foreach ($thr in @(@{v=1.5;c=$cGreen},@{v=2.0;c=$cAmber})) {
    if ($thr.v -ge $smin -and $thr.v -le $smax) {
      $yy=$py0+$ph-($thr.v-$smin)/$sr*$ph; $tp=New-Object System.Drawing.Pen($thr.c,1); $tp.DashStyle='Dash'
      $g.DrawLine($tp,[float]$px0,[float]$yy,[float]($px0+$pw),[float]$yy)
    }
  }
  $g.DrawRectangle((New-Object System.Drawing.Pen($cTrack,1)),[int]$px0,[int]$py0,[int]$pw,[int]$ph)
  $g.DrawString('SWR',$fnt,$lblBr,[float]2,[float]($py0-2))
  $g.DrawString('Frequency (MHz)',$fnt,$lblBr,[float]($px0+$pw/2-40),[float]($py0+$ph+24))
  $keys=@($all | Select-Object -ExpandProperty Key -Unique | Sort-Object)
  $cmap=@{}; for ($i=0;$i -lt $keys.Count;$i++){ $cmap[$keys[$i]]=$plotColors[$i % $plotColors.Count] }
  foreach ($p in $pts) {
    $xx=$px0+($p.Freq-$fmin)/$fr*$pw; $yy=$py0+$ph-([math]::Min($p.Swr,$smax)-$smin)/$sr*$ph
    $col=$cmap[$p.Key]; if (-not $col) { $col=$cAmber }
    $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210,$col.R,$col.G,$col.B))),[float]($xx-3.5),[float]($yy-3.5),7,7)
  }
  $lx=$px0+$pw+14; $ly=$py0+2
  $g.DrawString('Antennas',(New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold)),$lblBr,[float]$lx,[float]$ly); $ly+=18
  $tbr=New-Object System.Drawing.SolidBrush($cText)
  foreach ($k in $keys) {
    $col=$cmap[$k]; $cnt=@($all | Where-Object { $_.Key -eq $k }).Count
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($col)),[float]$lx,[float]($ly+2),9,9)
    $g.DrawString("$k ($cnt)",$fnt,$tbr,[float]($lx+14),[float]$ly)
    $ly+=18; if ($ly -gt $py0+$ph-14) { break }
  }
  $g.Dispose(); return $bmp
}
function Draw-Plot {
  if (-not $plotForm.Visible) { return }
  $bmp=Render-Plot; $old=$pic.Image; $pic.Image=$bmp; if ($old) { $old.Dispose() }
}
function Refresh-Plot { Populate-PlotFilter; Draw-Plot }

# ---------- per-meter parse / TX tracking / focus ----------
function Parse-Meter($m) {
  $st=$m.State; $L=$m.Last; $L.connected=[bool]$st.Connected
  if (-not $st.Connected) { $L.f=$null;$L.r=$null;$L.s=$null;$L.active=$DASH;$L.range=$DASH;$L.type=$DASH;$L.autoOn=$false;$L.ledOn=$false;$L.alarm=$false;$L.fs=200.0; return }
  $L.f=Get-Power $st.F; $L.r=Get-Power $st.R; $L.s=Get-Swr $st.S
  $info=(''+$st.I) -replace '[^\x20-\x7E]',''
  $L.alarm=($info -match '^[Aa]!')
  $L.active=$DASH;$L.range=$DASH;$L.type=$DASH;$L.autoOn=$false;$L.ledOn=$false;$L.fs=200.0
  if (-not $L.alarm -and $info.Length -ge 2 -and ($info[0] -eq 'I' -or $info[0] -eq 'i')) {
    $b=$info.TrimEnd(';').Substring(1)
    if ($b.Length -ge 7) { $L.active=switch ("$($b[6])") { '1' {'S1'} '2' {'S2'} default {$DASH} } }
    if ($b.Length -ge 2) { $rk="$($b[1])"; if ($rangeNm.ContainsKey($rk)){$L.range=$rangeNm[$rk]}; if ($rangeFS.ContainsKey($rk)){$L.fs=$rangeFS[$rk]} }
    if ($b.Length -ge 4) { $tk="$($b[3])"; if ($typeNm.ContainsKey($tk)){$L.type=$typeNm[$tk]} }
    if ($b.Length -ge 3) { $L.autoOn=("$($b[2])" -eq '1') }
    if ($b.Length -ge 6) { $L.ledOn =("$($b[5])" -eq '1') }
  }
}
function Sampler-Num($active) { if ($active -eq 'S1') { return '1' } elseif ($active -eq 'S2') { return '2' } else { return '' } }
function Track-Tx($m) {
  $L=$m.Last; $T=$m.Tx; $now=[DateTime]::Now
  $valid = ($L.connected -and $null -ne $L.f)   # we actually got a power number this tick
  $txOn  = ($valid -and $L.f -gt 0.1)
  if ($null -ne $L.f -and $L.f -gt $m.Peak) { $m.Peak=$L.f }
  if ($txOn) {
    if (-not $T.active) { $T.active=$true; $T.start=$now; $T.peakF=0.0; $T.maxSwr=0.0; $T.sensor=$L.active; $T.range=$L.range; $T.type=$L.type; $T.freq=$null }
    $T.last=$now
    if ($null -ne $L.f -and $L.f -gt $T.peakF) { $T.peakF=$L.f }
    if ($null -ne $L.s -and $L.s -gt $T.maxSwr) { $T.maxSwr=$L.s }
    if ($L.active -ne $DASH){$T.sensor=$L.active}; if ($L.range -ne $DASH){$T.range=$L.range}; if ($L.type -ne $DASH){$T.type=$L.type}
    $sn=Sampler-Num $L.active
    if ($sn) { $rd=Get-RadioFor $m.Id $sn; if ($rd -and $rd.State.Connected -and $rd.State.Freq) { $T.freq=$rd.State.Freq } }
  } elseif ($T.active) {
    # End the over only on a confirmed key-up: a disconnect, or a *valid* low reading that
    # has persisted past the hang time. Read dropouts (null power) are ignored, so a serial
    # glitch can't reset or restart the timer.
    if ((-not $L.connected) -or ($valid -and ($now-$T.last).TotalSeconds -gt $script:txHang)) {
      $T.active=$false
      $dur=[int]($T.last-$T.start).TotalSeconds
      if ($script:logTx -and $dur -ge 1) { Write-TxLog $m.Name $T.freq $T.start $dur $T.peakF $T.maxSwr $T.sensor $T.range $T.type ($dur -ge $script:timeoutSec) }
    }
  }
}
function Get-Focus {
  $cands=@($script:meters | Where-Object { $_.Last.connected })
  if ($cands.Count -eq 0) { return $null }
  $tx=@($cands | Where-Object { $_.Tx.active })
  if ($tx.Count -gt 0) { return (@($tx | Sort-Object { $_.Tx.peakF } -Descending))[0] }
  if ($script:focusId) { $prev=@($cands | Where-Object { $_.Id -eq $script:focusId }); if ($prev.Count) { return $prev[0] } }
  return $cands[0]
}
function Refresh-MeterList {
  $sig = (@($script:meters | ForEach-Object { "$($_.Name)|$($_.Port)|$($_.State.Connected)|$([bool]$_.State.Error)" }) -join ';')
  if ($sig -eq $script:meterSig) { return }
  $script:meterSig=$sig; $sel=$meterList.SelectedIndex
  $meterList.BeginUpdate(); $meterList.Items.Clear()
  foreach ($m in $script:meters) {
    $stat = if ($m.State.Connected) { 'on' } elseif ($m.State.Error) { 'err' } else { 'off' }
    $pt = if ($m.Port) { $m.Port } else { '(no port)' }
    [void]$meterList.Items.Add(('{0}   {1}   [{2}]' -f $m.Name,$pt,$stat))
  }
  if ($sel -ge 0 -and $sel -lt $meterList.Items.Count) { $meterList.SelectedIndex=$sel }
  $meterList.EndUpdate()
}
function Refresh-RadioList {
  $sig=(@($script:radios | ForEach-Object { "$($_.MeterId)|$($_.Sampler)|$($_.Port)|$($_.Baud)|$($_.State.Connected)|$($_.State.Freq)" }) -join ';')
  if ($sig -eq $script:radioSig) { return }
  $script:radioSig=$sig; $sel=$radioList.SelectedIndex
  $script:radioListLoading=$true
  $radioList.BeginUpdate(); $radioList.Items.Clear()
  foreach ($r in $script:radios) {
    $mn=@($script:meters | Where-Object { $_.Id -eq $r.MeterId } | ForEach-Object { $_.Name }); $mn = if ($mn.Count) { $mn[0] } else { '?' }
    $stat = if ($r.State.Connected) { 'on' } elseif ($r.State.Error) { 'err' } else { 'off' }
    $fq = if ($r.State.Freq) { '{0:N4} MHz' -f $r.State.Freq } else { $DASH }
    $pc = switch ($r.Proto) { 'ts2000' {'TS2K'} 'rigctld' {'NET '} default {'D710'} }
    [void]$radioList.Items.Add(('{0}  S{1}  {2}  ->  {3} @{4}  [{5}]  {6}' -f $mn,$r.Sampler,$pc,$r.Port,$r.Baud,$stat,$fq))
  }
  if ($sel -ge 0 -and $sel -lt $radioList.Items.Count) { $radioList.SelectedIndex=$sel }
  $radioList.EndUpdate()
  $script:radioListLoading=$false
}
function Populate-RadioCombos {
  $selM=$rMeter.SelectedIndex; $rMeter.Items.Clear()
  foreach ($m in $script:meters) { [void]$rMeter.Items.Add($m.Name) }
  if ($rMeter.Items.Count) { if ($selM -ge 0 -and $selM -lt $rMeter.Items.Count) { $rMeter.SelectedIndex=$selM } else { $rMeter.SelectedIndex=0 } }
  $selP=$rPort.SelectedItem; $rPort.Items.Clear()
  foreach ($p in (Get-Ports)) { [void]$rPort.Items.Add($p) }
  if ($selP -and $rPort.Items.Contains($selP)) { $rPort.SelectedItem=$selP } elseif ($rPort.Items.Count) { $rPort.SelectedIndex=0 }
}
function Detect-Meters {
  $optStatus.Text='Detecting W2 meters...'; $opt.Refresh()
  $assigned = @($script:meters | ForEach-Object { $_.Port })
  $found=@()
  foreach ($p in (Get-Ports)) {
    if ($assigned -contains $p) { continue }
    try {
      $tp=New-Object System.IO.Ports.SerialPort $p,9600,'None',8,'One'
      $tp.ReadTimeout=250; $tp.WriteTimeout=250; $tp.DtrEnable=$true; $tp.RtsEnable=$true
      $tp.Open(); Start-Sleep -Milliseconds 120; $tp.DiscardInBuffer(); $tp.Write('V')
      $sw=[System.Diagnostics.Stopwatch]::StartNew(); $resp=''
      while ($sw.ElapsedMilliseconds -lt 300) { while ($tp.BytesToRead -gt 0){ $ch=[char]$tp.ReadByte(); $resp+=$ch; if ($ch -eq ';'){break} }; if ($resp -match ';'){break}; Start-Sleep -Milliseconds 5 }
      $tp.Close()
      if ($resp -match '^[Vv]\d') { $found+=$p }
    } catch {}
  }
  foreach ($p in $found) {
    $n=1; while (@($script:meters | Where-Object { $_.Name -eq "W2 #$n" }).Count) { $n++ }
    $m=New-Meter (New-Uid) "W2 #$n" $p; $script:meters += $m; Start-MeterWorker $m; $m.State.ConnectTo=$p
  }
  $script:meterSig=''; Refresh-MeterList; Save-Config
  $optStatus.Text = if ($found.Count) { "Found $($found.Count) W2 meter(s): $($found -join ', ')" } else { 'No new W2 meters found.' }
}

# ---------- populate, load, init ----------
foreach ($p in (Get-Ports)) { [void]$combo.Items.Add($p) }
Load-Config
if ($script:meters.Count -eq 0) {
  $p = if ($combo.Items.Contains($Port)) { $Port } elseif ($combo.Items.Count) { [string]$combo.Items[0] } else { $Port }
  $script:meters += (New-Meter 'm1' 'W2 #1' $p)
}
if ($combo.Items.Count) { if ($script:meters[0].Port -and $combo.Items.Contains($script:meters[0].Port)) { $combo.SelectedItem=$script:meters[0].Port } else { $combo.SelectedIndex=0 } }
Build-MainFonts; Apply-MainFonts
$cbStatus.Checked=$show.statusLine; $cbPwrBar.Checked=$show.powerBar; $cbSwrBar.Checked=$show.swrBar
$cbRefl.Checked=$show.reflected;    $cbRl.Checked=$show.returnLoss;   $cbPeak.Checked=$show.peak
$cbTx.Checked=$show.tx; $cbFreq.Checked=$show.freq; $cbLog.Checked=$script:logTx
$numTimeout.Value=[decimal]([math]::Max(30,[math]::Min(1800,$script:timeoutSec)))
Set-Cmds $false
Refresh-MeterList; if ($meterList.Items.Count) { $meterList.SelectedIndex=0 }
Update-Layout
try {
  $icoPath = Join-Path $scriptDir 'W2Monitor.ico'
  if (Test-Path $icoPath) { $ico = New-Object System.Drawing.Icon($icoPath); $form.Icon=$ico; $opt.Icon=$ico; $logForm.Icon=$ico; $radioForm.Icon=$ico; $plotForm.Icon=$ico }
} catch {}
foreach ($m in $script:meters) { Start-MeterWorker $m }
foreach ($r in $script:radios) { Start-RadioWorker $r }

# ---------- events ----------
$setupBtn.Add_Click({ if (-not $opt.Visible) { $opt.Location=(P ($form.Location.X+$form.Width+8) $form.Location.Y) }; $opt.Show(); $opt.BringToFront() })
$closeBtn.Add_Click({ $opt.Hide() })
$opt.Add_FormClosing({ param($s,$e) if (-not $script:exiting) { $e.Cancel=$true; $opt.Hide() } })

$form.Add_ResizeEnd({
  if ($script:scaling) { return }
  $ns=[math]::Round(($form.ClientSize.Width/462.0),3); $ns=[math]::Max(0.8,[math]::Min(3.0,$ns))
  if ([math]::Abs($ns-$script:scale) -lt 0.02) { return }
  $script:scale=$ns; Build-MainFonts; Apply-MainFonts; Update-Layout; Save-Config
})

$refreshBtn.Add_Click({
  $sel=$combo.SelectedItem; $combo.Items.Clear()
  foreach ($p in (Get-Ports)) { [void]$combo.Items.Add($p) }
  if ($sel -and $combo.Items.Contains($sel)) { $combo.SelectedItem=$sel } elseif ($combo.Items.Count) { $combo.SelectedIndex=0 }
})
$connectBtn.Add_Click({
  $anyConn=@($script:meters | Where-Object { $_.State.Connected -or $_.State.ConnectTo }).Count -gt 0
  if ($anyConn) { Disconnect-All } else { Connect-All; Connect-AllRadios; Save-Config }
})
$meterList.Add_SelectedIndexChanged({
  $i=$meterList.SelectedIndex
  if ($i -ge 0 -and $i -lt $script:meters.Count) { $p=$script:meters[$i].Port; if ($p -and $combo.Items.Contains($p)) { $combo.SelectedItem=$p } }
})
$addBtn.Add_Click({
  $p=[string]$combo.SelectedItem
  $n=1; while (@($script:meters | Where-Object { $_.Name -eq "W2 #$n" }).Count) { $n++ }
  $m=New-Meter (New-Uid) "W2 #$n" $p; $script:meters += $m; Start-MeterWorker $m
  if ($p) { $m.State.ConnectTo=$p }
  $script:meterSig=''; Refresh-MeterList; Save-Config
})
$removeBtn.Add_Click({
  $i=$meterList.SelectedIndex; if ($i -lt 0 -or $i -ge $script:meters.Count) { return }
  $m=$script:meters[$i]; Stop-MeterWorker $m
  foreach ($r in @($script:radios | Where-Object { $_.MeterId -eq $m.Id })) { Stop-RadioWorker $r }
  $script:radios = @($script:radios | Where-Object { $_.MeterId -ne $m.Id })
  $script:meters = @($script:meters | Where-Object { $_.Id -ne $m.Id })
  $script:meterSig=''; $script:radioSig=''; Refresh-MeterList; Save-Config
})
$detectBtn.Add_Click({ Detect-Meters })

$radiosBtn.Add_Click({ Populate-RadioCombos; $script:radioSig=''; Refresh-RadioList; if (-not $radioForm.Visible) { $radioForm.Location=(P ($opt.Location.X+20) ($opt.Location.Y+40)) }; $radioForm.Show(); $radioForm.BringToFront() })
$rClose.Add_Click({ $radioForm.Hide() })
$rPorts.Add_Click({ Populate-RadioCombos })
$radioList.Add_SelectedIndexChanged({
  if ($script:radioListLoading) { return }
  $i=$radioList.SelectedIndex; if ($i -lt 0 -or $i -ge $script:radios.Count) { return }
  $r=$script:radios[$i]
  $mi=-1; for ($k=0; $k -lt $script:meters.Count; $k++) { if ($script:meters[$k].Id -eq $r.MeterId) { $mi=$k; break } }
  if ($mi -ge 0 -and $mi -lt $rMeter.Items.Count) { $rMeter.SelectedIndex=$mi }
  $rSampler.SelectedItem = if ($r.Sampler -eq '2') { 'S2' } else { 'S1' }
  $rPort.Text = [string]$r.Port
  if ($rBaud.Items.Contains($r.Baud)) { $rBaud.SelectedItem=$r.Baud }
  $rProto.SelectedIndex = switch ($r.Proto) { 'ts2000' {1} 'rigctld' {2} default {0} }
})
$rProto.Add_SelectedIndexChanged({
  if ($rProto.SelectedIndex -eq 2 -and -not (([string]$rPort.Text) -match ':')) { $rPort.Text='127.0.0.1:4532' }
})
$radioForm.Add_FormClosing({ param($s,$e) if (-not $script:exiting) { $e.Cancel=$true; $radioForm.Hide() } })
$rAdd.Add_Click({
  $mi=$rMeter.SelectedIndex; if ($mi -lt 0 -or $mi -ge $script:meters.Count) { return }
  $meter=$script:meters[$mi]; $sn = if ($rSampler.SelectedItem -eq 'S2') { '2' } else { '1' }
  $port=([string]$rPort.Text).Trim(); $baud=[int]$rBaud.SelectedItem
  $proto = switch ($rProto.SelectedIndex) { 1 {'ts2000'} 2 {'rigctld'} default {'kenwood'} }
  if (-not $port) { return }
  $existing=Get-RadioFor $meter.Id $sn
  if ($existing) {
    Stop-RadioWorker $existing
    $existing.Port=$port; $existing.Baud=$baud; $existing.Proto=$proto; $existing.Name=$meter.Name
    $existing.State.Stop=$false; $existing.State.Baud=$baud; $existing.State.Proto=$proto
    $existing.State.Connected=$false; $existing.State.Error=''; $existing.State.Freq=$null; $existing.State.DisconnectReq=$false; $existing.State.ConnectTo=$null
    Start-RadioWorker $existing; $existing.State.ConnectTo=$port
  } else {
    $r=New-Radio (New-Uid) $meter.Id $sn $port $baud $proto $meter.Name
    $script:radios += $r; Start-RadioWorker $r; $r.State.ConnectTo=$port
  }
  $script:radioSig=''; Refresh-RadioList; Save-Config
})
$rRemove.Add_Click({
  $i=$radioList.SelectedIndex; if ($i -lt 0 -or $i -ge $script:radios.Count) { return }
  $r=$script:radios[$i]; Stop-RadioWorker $r
  $script:radios = @($script:radios | Where-Object { $_.Id -ne $r.Id })
  $script:radioSig=''; Refresh-RadioList; Save-Config
})

$btnSensor.Add_Click({ if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('O') }; Flash-Btn $btnSensor })
$btnAuto.Add_Click({   if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('0') } })
$btnRange.Add_Click({  $script:rstep=($script:rstep % 3)+1; if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add("$($script:rstep)") }; Flash-Btn $btnRange })
$btnAvg.Add_Click({    if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('N') }; $script:tg.pep=(-not $script:tg.pep); Style-Btn $btnAvg $script:tg.pep })
$btnPkHold.Add_Click({ if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('P') }; $script:tg.pkhold=(-not $script:tg.pkhold); Style-Btn $btnPkHold $script:tg.pkhold })
$btnLeds.Add_Click({   if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('L') } })
$btnReset.Add_Click({  if ($script:focusMeter) { $script:focusMeter.Peak=0.0 }; Flash-Btn $btnReset })
$topMost.Add_CheckedChanged({ $form.TopMost=$topMost.Checked; Save-Config })

$cbStatus.Add_CheckedChanged({ $show.statusLine=$cbStatus.Checked; Update-Layout; Save-Config })
$cbPwrBar.Add_CheckedChanged({ $show.powerBar=$cbPwrBar.Checked;   Update-Layout; Save-Config })
$cbSwrBar.Add_CheckedChanged({ $show.swrBar=$cbSwrBar.Checked;     Update-Layout; Save-Config })
$cbRefl.Add_CheckedChanged({   $show.reflected=$cbRefl.Checked;    Update-Layout; Save-Config })
$cbRl.Add_CheckedChanged({     $show.returnLoss=$cbRl.Checked;     Update-Layout; Save-Config })
$cbPeak.Add_CheckedChanged({   $show.peak=$cbPeak.Checked;         Update-Layout; Save-Config })
$cbTx.Add_CheckedChanged({     $show.tx=$cbTx.Checked;             Update-Layout; Save-Config })
$cbFreq.Add_CheckedChanged({   $show.freq=$cbFreq.Checked;         Update-Layout; Save-Config })
$cbLog.Add_CheckedChanged({    $script:logTx=$cbLog.Checked;       Save-Config })
$numTimeout.Add_ValueChanged({ $script:timeoutSec=[int]$numTimeout.Value; Save-Config })
$viewLogBtn.Add_Click({ if (-not $script:logShown -and -not $logForm.Visible) { $logForm.Location=(P ($opt.Location.X+30) ($opt.Location.Y+30)); $script:logShown=$true }; Load-LogGrid; $logForm.Show(); $logForm.BringToFront() })
$excelBtn.Add_Click({ if (Test-Path $logPath) { try { Start-Process $logPath } catch { $logCountLbl.Text='Could not open Excel.' } } else { $logCountLbl.Text='No log file yet.' } })
$refreshLogBtn.Add_Click({ Load-LogGrid })
$logCloseBtn.Add_Click({ $logForm.Hide(); Save-Config })
$logForm.Add_ResizeEnd({ if ($logForm.Visible) { $script:logShown=$true; Save-Config } })
$logForm.Add_FormClosing({ param($s,$e) if (-not $script:exiting) { $e.Cancel=$true; $logForm.Hide(); Save-Config } })
$plotBtn.Add_Click({ if (-not $script:plotShown -and -not $plotForm.Visible) { $plotForm.Location=(P ($form.Location.X+40) ($form.Location.Y+40)); $script:plotShown=$true }; Refresh-Plot; $plotForm.Show(); $plotForm.BringToFront() })
$plotRefresh.Add_Click({ Refresh-Plot })
$plotFilter.Add_SelectedIndexChanged({ if ($script:plotLoading) { return }; Draw-Plot })
$pic.Add_SizeChanged({ Draw-Plot })
$plotForm.Add_ResizeEnd({ if ($plotForm.Visible) { $script:plotShown=$true; Save-Config } })
$plotForm.Add_FormClosing({ param($s,$e) if (-not $script:exiting) { $e.Cancel=$true; $plotForm.Hide(); Save-Config } })

# ---------- UI refresh timer ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
 try {
  $script:tickN++
  foreach ($m in $script:meters) { Parse-Meter $m; Track-Tx $m }
  Refresh-MeterList
  if ($radioForm.Visible) { Refresh-RadioList }
  $connCount = @($script:meters | Where-Object { $_.Last.connected }).Count
  if ($connCount -gt 0) { if ($connectBtn.Text -ne 'Disconnect') { $connectBtn.Text='Disconnect' } } else { if ($connectBtn.Text -ne 'Connect') { $connectBtn.Text='Connect' } }

  $foc = Get-Focus; $script:focusMeter=$foc
  if ($foc) {
    $script:focusId=$foc.Id; $L=$foc.Last
    Set-Cmds $true; $dot.BackColor=$cGreen
    if ($foc.State.FW) { Set-Text $fwLbl "FW $((''+$foc.State.FW).TrimEnd(';'))" }
    $f=$L.f; $r=$L.r; $s=$L.s; $script:fs=$L.fs
    $rangeDisp = if ($L.autoOn) { if ($foc.Tx.active) { "Auto $($L.range)" } else { 'Auto' } } else { $L.range }

    if ($L.alarm) {
      Set-Text $statusLbl '** SWR ALARM **'; $statusLbl.ForeColor=$cRed; $script:stPending=''; $script:stCount=0
    } else {
      $statusLbl.ForeColor=$cText
      $st="Sensor $($L.active)     $BULL     $($L.type)     $BULL     Range $rangeDisp"
      if ($connCount -gt 1) { $st = "$($foc.Name)     $BULL     " + $st }
      if ($st -ne $statusLbl.Text) {
        if ($st -eq $script:stPending) { $script:stCount++ } else { $script:stPending=$st; $script:stCount=1 }
        if ($script:stCount -ge 3) { $statusLbl.Text=$st }
      } else { $script:stCount=0 }
    }

    if ($L.autoOn -ne $script:autoLit) { Style-Btn $btnAuto $L.autoOn; $script:autoLit=$L.autoOn }
    if ($L.ledOn  -ne $script:ledLit)  { Style-Btn $btnLeds $L.ledOn;  $script:ledLit=$L.ledOn }

    $sn=Sampler-Num $L.active
    $rd = if ($sn) { Get-RadioFor $foc.Id $sn } else { $null }
    Set-Text $freqVal $(if ($rd -and $rd.State.Connected -and $rd.State.Freq) { '{0:N4} MHz' -f $rd.State.Freq } else { "$DASH" })

    $now=[DateTime]::Now
    $el = if ($foc.Tx.active) { [int]($now-$foc.Tx.start).TotalSeconds } else { 0 }
    $warnAt=[math]::Max(0,$script:timeoutSec-30); $totAt=$script:timeoutSec
    Set-Text $txVal ('{0}:{1:D2}' -f [int][math]::Floor($el/60),($el%60))
    # green while OK; solid YELLOW from 30s before TOT; RED + flash at/after TOT (keeps counting)
    $txBase = if ($el -ge $totAt) { $cRed } elseif ($el -ge $warnAt) { $cAmber } elseif ($foc.Tx.active) { $cGreen } else { $cDim }
    if ($foc.Tx.active -and $el -ge $totAt) { $txVal.ForeColor = $(if (($script:tickN % 6) -lt 3) { $cRed } else { $cBg }) } else { $txVal.ForeColor=$txBase }

    if ($null -ne $f) { Set-Text $fwdVal ('{0:N1} W' -f $f) } else { Set-Text $fwdVal "$DASH W" }
    Set-Text $revVal $(if ($null -ne $r) { '{0:N2} W' -f $r } else { "$DASH W" })
    Set-Text $pkVal ('{0:N1} W' -f $foc.Peak)

    if ($null -ne $s -and $null -ne $f -and $f -gt 0.05) {
      Set-Text $swrVal ('{0:N2}:1' -f $s)
      $swrVal.ForeColor = if ($s -le 1.5) { $cGreen } elseif ($s -le 2.0) { $cAmber } else { $cRed }
      $rl = if ($s -gt 1) { -20 * [math]::Log10(($s-1)/($s+1)) } else { $null }
      Set-Text $rlVal $(if ($null -ne $rl) { '{0:N1} dB' -f $rl } else { "$DASH dB" })
      $swrBar.BackColor=$swrVal.ForeColor
      $swrBar.Width=[int]([math]::Max(0.0,[math]::Min(1.0,($s-1)/2.0)) * $swrBar.Parent.Width)
    } else { Set-Text $swrVal $DASH; $swrVal.ForeColor=$cDim; Set-Text $rlVal "$DASH dB"; $swrBar.Width=0 }
    $fwdBar.Width = if ($null -ne $f) { [int]([math]::Min(1.0,$f/$script:fs) * $fwdBar.Parent.Width) } else { 0 }

    $nm = if ($connCount -gt 1) { "$connCount meters" } else { "$($foc.Name) $($foc.Port)" }
    $optStatus.Text = "Connected: $nm`r`n9600 8N1  $BULL  $((Get-Date).ToString('HH:mm:ss'))"
  } else {
    $script:focusId=$null
    Set-Cmds $false
    $script:tg.pep=$false; $script:tg.pkhold=$false; $script:autoLit=$null; $script:ledLit=$null
    foreach ($b in $cmdButtons) { Style-Btn $b $false }
    $dot.BackColor=$cDim
    Set-Text $statusLbl 'Disconnected'; $statusLbl.ForeColor=$cText; $script:stPending=''; $script:stCount=0
    Set-Text $fwdVal "$DASH W"; Set-Text $swrVal $DASH; $swrVal.ForeColor=$cDim
    Set-Text $revVal "$DASH W"; Set-Text $rlVal "$DASH dB"; Set-Text $freqVal $DASH; $fwdBar.Width=0; $swrBar.Width=0
    Set-Text $txVal '0:00'; $txVal.ForeColor=$cDim; $script:txAlertLevel=0
    $errs=@($script:meters | Where-Object { $_.State.Error })
    if ($errs.Count) { $optStatus.Text="Could not connect: $($errs[0].State.Error)`r`nIf 'access denied', close the old W2 Utility (one app owns the port)." }
    else { $optStatus.Text="Disconnected.`r`nAdd a meter and press Connect." }
  }
 } catch { try { Add-Content -Path (Join-Path $scriptDir 'W2Monitor-error.log') -Value ('{0}  TICK  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) } catch {} }
})
$timer.Start()

# ---------- lifecycle ----------
$form.Add_Shown({ Connect-All; Connect-AllRadios })
$form.Add_FormClosing({
  $script:exiting=$true; Save-Config; $timer.Stop()
  foreach ($m in $script:meters) { try { $m.State.Stop=$true } catch {} }
  foreach ($r in $script:radios) { try { $r.State.Stop=$true } catch {} }
  Start-Sleep -Milliseconds 200
  try { $opt.Close() } catch {}; try { $logForm.Close() } catch {}; try { $radioForm.Close() } catch {}; try { $plotForm.Close() } catch {}
})
[void]$form.ShowDialog()

# ---------- teardown ----------
foreach ($m in $script:meters) { Stop-MeterWorker $m }
foreach ($r in $script:radios) { Stop-RadioWorker $r }

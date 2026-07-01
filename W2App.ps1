<#
  W2 Monitor - desktop monitor for Elecraft W2 RF power / SWR meters
  Version 0.10.0-beta
  Copyright (C) 2026  David Erickson (AB0R)

  Created by David Erickson (AB0R) in collaboration with Claude (Anthropic),
  which did the heavy lifting on the code.

  Each W2 runs on its own background runspace so serial I/O never blocks the UI.
  The main window auto-focuses whichever meter is transmitting; a Setup window
  manages meters, W2 controls, and display options. Put the W2 in Search mode
  (front panel or the Search button) to have it follow whichever sampler has RF.

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

  Elecraft is a trademark of its respective owner. This is an independent project,
  not affiliated with or endorsed by Elecraft.
#>
param([string]$Port = 'COM8')

$AppVersion = '0.10.0-beta'

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
$script:rstep=0; $script:exiting=$false; $script:scaling=$false
$script:stPending=''; $script:stCount=0; $script:flashBtn=$null
$script:tg=@{ pkhold=$false; pep=$false; search=$false }
$script:fs=200.0; $script:tickN=0; $script:autoLit=$null; $script:ledLit=$null
$script:timeoutSec=180; $script:txHang=2.0
$script:scale=1.05
$show=@{ statusLine=$true; powerBar=$true; swrBar=$true; reflected=$true; returnLoss=$true; peak=$true; tx=$true }

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $scriptDir) { $scriptDir = [Environment]::GetFolderPath('MyDocuments') }
$cfgPath = Join-Path $scriptDir 'W2Monitor.config.json'

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
    Tx=@{ active=$false; start=$null; last=$null; peakF=0.0 }
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
$opt.Text='W2 Setup'; $opt.ClientSize=(Z 372 660)
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
$btnSearch = New-Button $opt 'Search'        248 310 108
$topMost   = New-Check  $opt 'Always on top' 132 314
$cmdButtons = @($btnSensor,$btnAuto,$btnRange,$btnPkHold,$btnAvg,$btnLeds,$btnSearch)

New-Label $opt 'DISPLAY' 16 350 200 18 $fHdr $cAmber | Out-Null
$cbStatus = New-Check $opt 'Status line'        16 372
$cbPwrBar = New-Check $opt 'Forward power bar'  16 396
$cbSwrBar = New-Check $opt 'SWR bar'            16 420
$cbRefl   = New-Check $opt 'Reflected power'    16 444
$cbRl     = New-Check $opt 'Return loss'        16 468
$cbPeak   = New-Check $opt 'Peak forward'       16 492
$cbTx     = New-Check $opt 'TX timer'           16 516
New-Label $opt 'TX timeout (sec)' 16 546 120 24 $fSmall $cText | Out-Null
$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Location=(P 140 543); $numTimeout.Size=(Z 80 24); $numTimeout.Minimum=30; $numTimeout.Maximum=1800; $numTimeout.Increment=15
$numTimeout.BackColor=$cPanel; $numTimeout.ForeColor=$cText; $numTimeout.BorderStyle='FixedSingle'; $opt.Controls.Add($numTimeout)
$closeBtn   = New-Button $opt 'Close' 16 590 120 30
New-Label $opt "W2 Monitor v$AppVersion   $BULL   GPLv3   $BULL   AB0R + Claude" 16 630 344 22 $fSmall $cDim 'MiddleLeft' | Out-Null

# ---------- font + layout ----------
function Apply-MainFonts {
  $titleLbl.Font=$fTitle; $fwLbl.Font=$fSmallM; $setupBtn.Font=$fSmallM; $statusLbl.Font=$fStat
  $fwdCap.Font=$fCap; $swrCap.Font=$fCap; $revCap.Font=$fCap; $rlCap.Font=$fCap; $pkCap.Font=$fCap; $txCap.Font=$fCap
  $fwdVal.Font=$fBig; $swrVal.Font=$fBig
  $revVal.Font=$fMed; $rlVal.Font=$fMed; $pkVal.Font=$fMed; $txVal.Font=$fMed
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
      timeoutSec=$script:timeoutSec
      show=[ordered]@{ statusLine=$show.statusLine; powerBar=$show.powerBar; swrBar=$show.swrBar; reflected=$show.reflected; returnLoss=$show.returnLoss; peak=$show.peak; tx=$show.tx }
    }
    ($cfg | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8
  } catch {}
}
function Load-Config {
  if (-not (Test-Path $cfgPath)) { return }
  try {
    $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($null -ne $c.scale) { $script:scale=[math]::Max(0.8,[math]::Min(3.0,[double]$c.scale)) }
    if ($null -ne $c.timeoutSec) { $script:timeoutSec=[math]::Max(30,[math]::Min(1800,[int]$c.timeoutSec)) }
    if ($c.show) { foreach ($k in 'statusLine','powerBar','swrBar','reflected','returnLoss','peak','tx') { if ($null -ne $c.show.$k) { $show[$k]=[bool]$c.show.$k } } }
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
    if ($null -ne $c.topMost) { $topMost.Checked=[bool]$c.topMost; $form.TopMost=[bool]$c.topMost }
    if ($null -ne $c.x -and $null -ne $c.y) {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      if ([int]$c.x -ge $vs.Left -and [int]$c.y -ge $vs.Top -and [int]$c.x -lt ($vs.Right-60) -and [int]$c.y -lt ($vs.Bottom-60)) {
        $form.StartPosition='Manual'; $form.Location=(P ([int]$c.x) ([int]$c.y))
      }
    }
  } catch {}
}

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
function Track-Tx($m) {
  $L=$m.Last; $T=$m.Tx; $now=[DateTime]::Now
  $valid = ($L.connected -and $null -ne $L.f)   # we actually got a power number this tick
  $txOn  = ($valid -and $L.f -gt 0.1)
  if ($null -ne $L.f -and $L.f -gt $m.Peak) { $m.Peak=$L.f }
  if ($txOn) {
    if (-not $T.active) { $T.active=$true; $T.start=$now; $T.peakF=0.0 }
    $T.last=$now
    if ($null -ne $L.f -and $L.f -gt $T.peakF) { $T.peakF=$L.f }
  } elseif ($T.active) {
    # End the over only on a confirmed key-up: a disconnect, or a *valid* low reading that
    # has persisted past the hang time. Read dropouts (null power) are ignored, so a serial
    # glitch can't reset or restart the timer.
    if ((-not $L.connected) -or ($valid -and ($now-$T.last).TotalSeconds -gt $script:txHang)) {
      $T.active=$false
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
$cbTx.Checked=$show.tx
$numTimeout.Value=[decimal]([math]::Max(30,[math]::Min(1800,$script:timeoutSec)))
Set-Cmds $false
Refresh-MeterList; if ($meterList.Items.Count) { $meterList.SelectedIndex=0 }
Update-Layout
try {
  $icoPath = Join-Path $scriptDir 'W2Monitor.ico'
  if (Test-Path $icoPath) { $ico = New-Object System.Drawing.Icon($icoPath); $form.Icon=$ico; $opt.Icon=$ico }
} catch {}
foreach ($m in $script:meters) { Start-MeterWorker $m }

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
  if ($anyConn) { Disconnect-All } else { Connect-All; Save-Config }
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
  $script:meters = @($script:meters | Where-Object { $_.Id -ne $m.Id })
  $script:meterSig=''; Refresh-MeterList; Save-Config
})
$detectBtn.Add_Click({ Detect-Meters })

$btnSensor.Add_Click({ if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('O') }; Flash-Btn $btnSensor })
$btnAuto.Add_Click({   if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('0') } })
$btnRange.Add_Click({  $script:rstep=($script:rstep % 3)+1; if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add("$($script:rstep)") }; Flash-Btn $btnRange })
$btnAvg.Add_Click({    if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('N') }; $script:tg.pep=(-not $script:tg.pep); Style-Btn $btnAvg $script:tg.pep })
$btnPkHold.Add_Click({ if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('P') }; $script:tg.pkhold=(-not $script:tg.pkhold); Style-Btn $btnPkHold $script:tg.pkhold })
$btnLeds.Add_Click({   if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('L') } })
$btnSearch.Add_Click({ if ($script:focusMeter) { [void]$script:focusMeter.State.Cmds.Add('Y') }; $script:tg.search=(-not $script:tg.search); Style-Btn $btnSearch $script:tg.search })
$btnReset.Add_Click({  if ($script:focusMeter) { $script:focusMeter.Peak=0.0 }; Flash-Btn $btnReset })
$topMost.Add_CheckedChanged({ $form.TopMost=$topMost.Checked; Save-Config })

$cbStatus.Add_CheckedChanged({ $show.statusLine=$cbStatus.Checked; Update-Layout; Save-Config })
$cbPwrBar.Add_CheckedChanged({ $show.powerBar=$cbPwrBar.Checked;   Update-Layout; Save-Config })
$cbSwrBar.Add_CheckedChanged({ $show.swrBar=$cbSwrBar.Checked;     Update-Layout; Save-Config })
$cbRefl.Add_CheckedChanged({   $show.reflected=$cbRefl.Checked;    Update-Layout; Save-Config })
$cbRl.Add_CheckedChanged({     $show.returnLoss=$cbRl.Checked;     Update-Layout; Save-Config })
$cbPeak.Add_CheckedChanged({   $show.peak=$cbPeak.Checked;         Update-Layout; Save-Config })
$cbTx.Add_CheckedChanged({     $show.tx=$cbTx.Checked;             Update-Layout; Save-Config })
$numTimeout.Add_ValueChanged({ $script:timeoutSec=[int]$numTimeout.Value; Save-Config })

# ---------- UI refresh timer ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
 try {
  $script:tickN++
  foreach ($m in $script:meters) { Parse-Meter $m; Track-Tx $m }
  Refresh-MeterList
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
    $script:tg.pep=$false; $script:tg.pkhold=$false; $script:tg.search=$false; $script:autoLit=$null; $script:ledLit=$null
    foreach ($b in $cmdButtons) { Style-Btn $b $false }
    $dot.BackColor=$cDim
    Set-Text $statusLbl 'Disconnected'; $statusLbl.ForeColor=$cText; $script:stPending=''; $script:stCount=0
    Set-Text $fwdVal "$DASH W"; Set-Text $swrVal $DASH; $swrVal.ForeColor=$cDim
    Set-Text $revVal "$DASH W"; Set-Text $rlVal "$DASH dB"; $fwdBar.Width=0; $swrBar.Width=0
    Set-Text $txVal '0:00'; $txVal.ForeColor=$cDim
    $errs=@($script:meters | Where-Object { $_.State.Error })
    if ($errs.Count) { $optStatus.Text="Could not connect: $($errs[0].State.Error)`r`nIf 'access denied', close the old W2 Utility (one app owns the port)." }
    else { $optStatus.Text="Disconnected.`r`nAdd a meter and press Connect." }
  }
 } catch { try { Add-Content -Path (Join-Path $scriptDir 'W2Monitor-error.log') -Value ('{0}  TICK  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) } catch {} }
})
$timer.Start()

# ---------- lifecycle ----------
$form.Add_Shown({ Connect-All })
$form.Add_FormClosing({
  $script:exiting=$true; Save-Config; $timer.Stop()
  foreach ($m in $script:meters) { try { $m.State.Stop=$true } catch {} }
  Start-Sleep -Milliseconds 200
  try { $opt.Close() } catch {}
})
[void]$form.ShowDialog()

# ---------- teardown ----------
foreach ($m in $script:meters) { Stop-MeterWorker $m }

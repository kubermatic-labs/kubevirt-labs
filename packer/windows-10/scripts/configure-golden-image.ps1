# Configure golden image settings before sysprep.
# Machine-level (HKLM) settings persist through sysprep /generalize.
# Per-user settings are applied to the Default User profile so new users inherit them.

# --- Enable Remote Desktop ---
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
# Disable NLA requirement for easier RDP access
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 0
# Open firewall for RDP
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# --- Minimal diagnostic data ---
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name AllowTelemetry -Value 1

# --- Disable location services ---
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -Name DisableLocation -Value 1

# --- Disable Find My Device ---
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' -Name AllowFindMyDevice -Value 0

# --- Disable Advertising ID ---
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -Name DisabledByGroupPolicy -Value 1

# --- Disable Cortana ---
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name AllowCortana -Value 0

# --- Disable Edge first-run / browser import ---
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name HideFirstRunExperience -Value 1

# --- Apply per-user settings to Default User profile ---
# New users (e.g. root) inherit these on first login.
reg load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT" | Out-Null

# Disable tailored experiences
reg add "HKU\DefaultUser\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f | Out-Null

# Disable improve inking & typing
reg add "HKU\DefaultUser\SOFTWARE\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f | Out-Null
reg add "HKU\DefaultUser\SOFTWARE\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f | Out-Null

# Disable online speech recognition
reg add "HKU\DefaultUser\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" /v HasAccepted /t REG_DWORD /d 0 /f | Out-Null

reg unload "HKU\DefaultUser" | Out-Null

Write-Host "Golden image configuration complete."
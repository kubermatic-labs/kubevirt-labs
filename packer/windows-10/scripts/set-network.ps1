# Set network category from Public to Private (required to enable WinRM)
$profile = Get-NetConnectionProfile
Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory Private

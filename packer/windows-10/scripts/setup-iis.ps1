# Install IIS Web Server with management tools
Install-WindowsFeature -Name Web-Server -IncludeManagementTools

# Deploy demo page
$html = @"
<!DOCTYPE html>
<html>
<head>
    <title>KubeVirt Windows 10 VM</title>
    <style>
        body { font-family: Segoe UI, sans-serif; margin: 60px; background: #f0f0f0; }
        .card { background: white; padding: 40px; border-radius: 8px; max-width: 600px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; }
        code { background: #e8e8e8; padding: 2px 6px; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Hello from KubeVirt!</h1>
        <p>This IIS web server is running on a <strong>Windows 10</strong> golden image built with Packer.</p>
        <p>Host: <code>$($env:COMPUTERNAME)</code></p>
    </div>
</body>
</html>
"@
Set-Content -Path C:\inetpub\wwwroot\index.html -Value $html -Encoding UTF8

# Ensure IIS starts automatically
Set-Service -Name W3SVC -StartupType Automatic
Start-Service -Name W3SVC

# Open firewall for HTTP
New-NetFirewallRule -Name "HTTP_In" -DisplayName "HTTP Inbound" `
  -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue

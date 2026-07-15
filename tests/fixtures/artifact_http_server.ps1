param([string]$Root, [int]$Port)
$ErrorActionPreference = 'Stop'
[IO.Directory]::CreateDirectory($Root) | Out-Null
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Output 'READY'
try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $context.Response.KeepAlive = $false
    $name = $context.Request.Url.AbsolutePath.TrimStart('/')
    if ($name -notmatch '^[0-9a-f]{64}$') { $context.Response.StatusCode = 400; $context.Response.Close(); continue }
    $path = Join-Path $Root $name
    switch ($context.Request.HttpMethod) {
      'HEAD' { $context.Response.StatusCode = if (Test-Path -LiteralPath $path) { 200 } else { 404 }; $context.Response.ContentLength64 = 0; $context.Response.Close() }
      'GET' {
        if (!(Test-Path -LiteralPath $path)) { $context.Response.StatusCode = 404; $context.Response.Close(); continue }
        $data = [IO.File]::ReadAllBytes($path); $context.Response.StatusCode = 200; $context.Response.ContentLength64 = $data.Length; $context.Response.OutputStream.Write($data, 0, $data.Length); $context.Response.Close()
      }
      'PUT' {
        $target = [IO.File]::Create($path); try { $context.Request.InputStream.CopyTo($target) } finally { $target.Close() }; $context.Response.StatusCode = 201; $context.Response.ContentLength64 = 0; $context.Response.Close()
      }
      default { $context.Response.StatusCode = 405; $context.Response.Close() }
    }
  }
} finally { $listener.Close() }

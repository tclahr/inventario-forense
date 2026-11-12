BeforeAll {
  . "$PSScriptRoot/../../InventarioForense.ps1"

  function New-PastaTeste {
    param([string]$Pasta)
    $null = New-Item -ItemType Directory -Path (Join-Path $Pasta 'csv') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $Pasta 'brutos/Prefetch') -Force
    [IO.File]::WriteAllText((Join-Path $Pasta 'Coleta.txt'), 'texto de coleta')
    [IO.File]::WriteAllText((Join-Path $Pasta 'csv/01_Resumo.csv'), 'a;b')
    [IO.File]::WriteAllBytes((Join-Path $Pasta 'brutos/Prefetch/JOSÉ.EXE-1.pf'), [byte[]](1, 2, 3, 4))
  }
}

Describe 'Integridade' {
  BeforeEach {
    $Script:Pasta = Join-Path $TestDrive 'InventarioForense_H_20261112143000'
    Remove-Item -LiteralPath $Script:Pasta, "$Script:Pasta.zip", "$Script:Pasta.zip.sha256" -Recurse -Force -ErrorAction SilentlyContinue
    New-PastaTeste -Pasta $Script:Pasta
    Mock Write-Host {}
  }

  It 'Get-PastaSaida junta raiz e nome' {
    Get-PastaSaida -RaizScript (Join-Path $TestDrive 'r') -NomeColeta 'N' | Should -Be (Join-Path (Join-Path $TestDrive 'r') 'N')
  }

  It 'Get-Sha256Arquivo retorna minusculas e aceita colchetes' {
    $p = Join-Path $TestDrive 'a[1].txt'
    [IO.File]::WriteAllText($p, 'abc')
    Get-Sha256Arquivo -Caminho $p | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
  }

  It 'Manifesto ordenado, LF, sem BOM, caminhos com /' {
    $m = Write-Manifesto -Pasta $Script:Pasta
    (Split-Path $m -Leaf) | Should -Be 'SHA256SUMS.txt'
    $bytes = [IO.File]::ReadAllBytes($m)
    $bytes[0] | Should -Not -Be 0xEF
    $bytes | Should -Not -Contain 13
    $bytes[$bytes.Length - 1] | Should -Be 10
    $texto = [Text.Encoding]::UTF8.GetString($bytes)
    $linhas = $texto.TrimEnd("`n").Split("`n")
    $linhas.Count | Should -Be 3
    ($linhas | ForEach-Object { $_.Substring(66) }) -join '|' | Should -Be 'Coleta.txt|brutos/Prefetch/JOSÉ.EXE-1.pf|csv/01_Resumo.csv'
    $linhas[0] | Should -Be ("$(Get-Sha256Arquivo -Caminho (Join-Path $Script:Pasta 'Coleta.txt'))  Coleta.txt")
  }

  It 'Fluxo completo OK apaga a pasta' {
    $r = Complete-Coleta -Pasta $Script:Pasta
    $r.Ok | Should -BeTrue
    Test-Path -LiteralPath $Script:Pasta | Should -BeFalse
    Test-Path -LiteralPath $r.Zip | Should -BeTrue
    Test-Path -LiteralPath $r.HashZip | Should -BeTrue
    $esperado = "$(Get-Sha256Arquivo -Caminho $r.Zip)  InventarioForense_H_20261112143000.zip`n"
    [IO.File]::ReadAllText($r.HashZip) | Should -BeExactly $esperado
    $r.Hash | Should -Be (Get-Sha256Arquivo -Caminho $r.Zip)
    [IO.File]::ReadAllBytes($r.HashZip)[0] | Should -Not -Be 0xEF
  }

  It 'Divergencia mantem a pasta' {
    $null = Write-Manifesto -Pasta $Script:Pasta
    $zip = New-ZipColeta -Pasta $Script:Pasta
    (Test-ZipContraManifesto -Zip $zip).Ok | Should -BeTrue
    $a = [IO.Compression.ZipFile]::Open($zip, 'Update')
    try {
      $e = $a.Entries | Where-Object { $_.FullName -match 'Coleta\.txt$' } | Select-Object -First 1
      $nome = $e.FullName
      $e.Delete()
      $n = $a.CreateEntry($nome)
      $w = New-Object IO.StreamWriter($n.Open())
      $w.Write('adulterado'); $w.Dispose()
    } finally { $a.Dispose() }
    $r = Test-ZipContraManifesto -Zip $zip
    $r.Ok | Should -BeFalse
    $r.Divergencias | Should -Contain 'Hash: Coleta.txt'

    Remove-Item -LiteralPath $zip -Force
    Mock Test-ZipContraManifesto { @{ Ok = $false; Divergencias = @('Hash: x') } }
    $c = Complete-Coleta -Pasta $Script:Pasta
    $c.Ok | Should -BeFalse
    Test-Path -LiteralPath $Script:Pasta | Should -BeTrue
  }

  It 'Detecta Ausente e Extra' {
    $null = Write-Manifesto -Pasta $Script:Pasta
    Remove-Item -LiteralPath (Join-Path $Script:Pasta 'csv/01_Resumo.csv')
    [IO.File]::WriteAllText((Join-Path $Script:Pasta 'novo.txt'), 'x')
    $zip = New-ZipColeta -Pasta $Script:Pasta
    $r = Test-ZipContraManifesto -Zip $zip
    $r.Ok | Should -BeFalse
    $r.Divergencias | Should -Contain 'Ausente: csv/01_Resumo.csv'
    $r.Divergencias | Should -Contain 'Extra: novo.txt'
  }

  It 'Zip existente nao e sobrescrito' {
    $null = Write-Manifesto -Pasta $Script:Pasta
    $null = New-ZipColeta -Pasta $Script:Pasta
    { New-ZipColeta -Pasta $Script:Pasta } | Should -Throw
  }

  It 'Caminho com espacos' {
    $p = Join-Path $TestDrive 'Coleta Campo/InventarioForense_X'
    New-PastaTeste -Pasta $p
    $r = Complete-Coleta -Pasta $p
    $r.Ok | Should -BeTrue
    Test-Path -LiteralPath $p | Should -BeFalse
    Test-Path -LiteralPath $r.Zip | Should -BeTrue
  }

  It 'Entrada na raiz do ZIP e Extra e a pasta e mantida' {
    $null = Write-Manifesto -Pasta $Script:Pasta
    $zip = New-ZipColeta -Pasta $Script:Pasta
    $a = [IO.Compression.ZipFile]::Open($zip, 'Update')
    try {
      $n = $a.CreateEntry('solto.txt')
      $w = New-Object IO.StreamWriter($n.Open()); $w.Write('x'); $w.Dispose()
    } finally { $a.Dispose() }
    $r = Test-ZipContraManifesto -Zip $zip
    $r.Ok | Should -BeFalse
    $r.Divergencias | Should -Contain 'Extra: solto.txt'

    Remove-Item -LiteralPath $zip -Force
    $c = Complete-Coleta -Pasta $Script:Pasta
    $c.Ok | Should -BeTrue
  }

  It 'Entradas duplicadas apos normalizar sao Duplicado e a pasta e mantida' {
    $null = Write-Manifesto -Pasta $Script:Pasta
    $zip = New-ZipColeta -Pasta $Script:Pasta
    $base = Split-Path -Leaf $Script:Pasta
    $a = [IO.Compression.ZipFile]::Open($zip, 'Update')
    try {
      $n = $a.CreateEntry("$base\csv\01_Resumo.csv")
      $w = New-Object IO.StreamWriter($n.Open()); $w.Write('outro'); $w.Dispose()
    } finally { $a.Dispose() }
    $r = Test-ZipContraManifesto -Zip $zip
    $r.Ok | Should -BeFalse
    $r.Divergencias | Should -Contain 'Duplicado: csv/01_Resumo.csv'

    Remove-Item -LiteralPath $zip -Force
    Mock Test-ZipContraManifesto { @{ Ok = $false; Divergencias = @('Duplicado: x') } }
    $c = Complete-Coleta -Pasta $Script:Pasta
    $c.Ok | Should -BeFalse
    Test-Path -LiteralPath $Script:Pasta | Should -BeTrue
  }

  It 'Pasta gravavel e somente leitura' {
    Test-PastaGravavel -Pasta $TestDrive | Should -BeTrue
    Test-PastaGravavel -Pasta (Join-Path $TestDrive 'inexistente/x') | Should -BeFalse
  }

  It 'Pasta somente leitura nao e gravavel' -Skip:(-not $IsLinux -or (id -u) -eq '0') {
    $ro = Join-Path $TestDrive 'ro'
    $null = New-Item -ItemType Directory -Path $ro
    chmod 555 $ro
    try { Test-PastaGravavel -Pasta $ro | Should -BeFalse } finally { chmod 755 $ro }
  }
  It 'Entradas do ZIP usam / mesmo sem _tmp (CreateFromDirectory do .NET Framework grava \\)' {
    $null = New-Item -ItemType Directory -Path (Join-Path $Script:Pasta 'brutos/Prefetch') -Force
    [IO.File]::WriteAllBytes((Join-Path $Script:Pasta 'brutos/Prefetch/A.pf'), [byte[]](1))
    $null = Write-Manifesto -Pasta $Script:Pasta
    $zip = New-ZipColeta -Pasta $Script:Pasta
    $a = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $nomes = @($a.Entries | ForEach-Object { $_.FullName }) } finally { $a.Dispose() }
    $nomes | Should -Contain 'InventarioForense_H_20261112143000/brutos/Prefetch/A.pf'
    @($nomes | Where-Object { $_.Contains('\') }).Count | Should -Be 0
    (Get-Command New-ZipColeta).Definition | Should -Not -Match 'CreateFromDirectory'
  }

  It '_tmp que nao pode ser removida fica fora do manifesto e do ZIP' {
    $null = New-Item -ItemType Directory -Path (Join-Path $Script:Pasta '_tmp/COLETA_1') -Force
    [IO.File]::WriteAllBytes((Join-Path $Script:Pasta '_tmp/COLETA_1/NTUSER.DAT'), [byte[]](9, 9, 9))
    $m = Write-Manifesto -Pasta $Script:Pasta
    [IO.File]::ReadAllText($m) | Should -Not -Match '_tmp'
    $zip = New-ZipColeta -Pasta $Script:Pasta
    $a = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $nomes = @($a.Entries | ForEach-Object { $_.FullName }) } finally { $a.Dispose() }
    ($nomes -join '|') | Should -Not -Match '_tmp'
    $nomes | Should -Contain 'InventarioForense_H_20261112143000/csv/01_Resumo.csv'
    $nomes | Should -Contain 'InventarioForense_H_20261112143000/SHA256SUMS.txt'
    $v = Test-ZipContraManifesto -Zip $zip
    $v.Ok | Should -BeTrue
  }

  It 'Fluxo completo com _tmp presente passa na verificacao' {
    $null = New-Item -ItemType Directory -Path (Join-Path $Script:Pasta '_tmp') -Force
    [IO.File]::WriteAllBytes((Join-Path $Script:Pasta '_tmp/Amcache.hve'), [byte[]](1))
    $r = Complete-Coleta -Pasta $Script:Pasta
    $r.Ok | Should -BeTrue
  }

  It 'Carrega System.IO.Compression antes de FileSystem (enum CompressionLevel no PS 5.1)' {
    $Script:Carregadas = New-Object System.Collections.Generic.List[string]
    Mock Add-Type { $Script:Carregadas.Add($AssemblyName -join ',') }
    Import-AssemblyCompressao
    ($Script:Carregadas -join '|') | Should -Be 'System.IO.Compression|System.IO.Compression.FileSystem'
  }

  It 'Falha do Add-Type vira aviso e nao interrompe' {
    Mock Add-Type { throw 'sem GAC' }
    Mock Write-Warning {}
    { Import-AssemblyCompressao } | Should -Not -Throw
    Should -Invoke Write-Warning -Times 2 -Exactly
  }

  It 'New-ZipColeta e Test-ZipContraManifesto usam o carregador das duas assemblies' {
    foreach ($f in 'New-ZipColeta', 'Test-ZipContraManifesto') {
      (Get-Command $f).ScriptBlock.ToString() | Should -Match 'Import-AssemblyCompressao'
    }
  }
}

BeforeAll {
  . "$PSScriptRoot/../../InventarioForense.ps1"
}

Describe 'Saidas' {
  BeforeEach {
    $null = New-ContextoColeta -Parametros @{ Etiqueta = 'E1'; Setor = 'TI'; ExecutadoPor = 'Bia'; Observacao = 'obs'; Completa = $false }
    $Script:Ctx.Hostname = 'H'
    $Script:Ctx.IdEquipamento = 'ID1'
    $Script:Ctx.IdEquipamentoOrigem = 'UUID=A|BIOS=B|PLACA=C|DISCO=D'
    $Script:Ctx.Admin = $true
    $Script:Ctx.Resultados['07'] = @(1..3 | ForEach-Object { [pscustomobject]@{ Fonte = 'x'; Nome = "n$_" } })
    Mock Write-Host {}
  }

  It 'Resumo nao lanca sem CIM' {
    Mock Get-CimSafe { throw 'x' }
    $r = Get-ColetaResumo
    foreach ($c in $Script:Contrato['01'].Colunas) { $r.PSObject.Properties.Name | Should -Contain $c }
    $r.TotalSoftwaresInstalados | Should -Be 3
    $r.Etiqueta | Should -Be 'E1'
    $r.ExecutadoPor | Should -Be 'Bia'
    $r.PSObject.Properties.Name | Should -Not -Contain 'Responsavel'
    $r.Modo | Should -Be 'Padrao'
    $r.PSObject.Properties.Name | Should -Not -Contain 'VersaoScript'
    $r.PSObject.Properties.Name | Should -Not -Contain 'HashScript'
  }

  It 'Resumo usa registro quando CIM falha' {
    Mock Get-CimSafe { throw 'x' }
    Mock Get-RegValores { @{ EditionID = 'Professional'; CurrentBuild = '26100'; UBR = 2605; DisplayVersion = '24H2' } }
    $r = Get-ColetaResumo
    $r.Edicao | Should -Be 'Professional'
    $r.Build | Should -Be '26100.2605'
    $r.Versao | Should -Be '24H2'
  }

  It 'Resumo com WMI legado converte datas DMTF' {
    Mock Get-CimSafe { @() }
    Mock Get-CimSafe { @([pscustomobject]@{ Caption = 'Windows 11 Pro'; OSArchitecture = '64 bits'; InstallDate = '20240115103000.000000-180'; LastBootUpTime = '20261112080910.500000-180'; BuildNumber = '26100' }) } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
    $r = Get-ColetaResumo
    $r.SOAtualizadoEm | Should -Be '2024-01-15 10:30:00'
    $r.UltimoBoot | Should -Be '2026-11-12 08:09:10'
  }

  It 'Resumo pega a instalacao original das chaves Source OS' {
    Mock Get-CimSafe { @() }
    Mock Get-CimSafe { @([pscustomobject]@{ InstallDate = '20260901100000.000000-180' }) } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
    Mock Get-RegSubchaves { @('Source OS (Updated on 9/1/2026 10:00:00)', 'Source OS (Updated on 3/2/2024 08:00:00)', 'ChildCompletion') } -ParameterFilter { $Caminho -like '*\SYSTEM\Setup' }
    Mock Get-RegValores { @{ InstallDate = 1710000000 } } -ParameterFilter { $Caminho -like '*Source OS (Updated on 9/1/2026*' }
    Mock Get-RegValores { @{ InstallDate = 1577880000 } } -ParameterFilter { $Caminho -like '*Source OS (Updated on 3/2/2024*' }
    $r = Get-ColetaResumo
    $esperado = ConvertTo-DataTexto ([DateTimeOffset]::FromUnixTimeSeconds(1577880000).LocalDateTime)
    $r.SOAtualizadoEm | Should -Be '2026-09-01 10:00:00'
    $r.SOInstaladoEm | Should -Be $esperado
  }

  It 'Resumo sem Source OS repete a instalacao atual' {
    Mock Get-CimSafe { @() }
    Mock Get-CimSafe { @([pscustomobject]@{ InstallDate = '20240115103000.000000-180' }) } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
    Mock Get-RegSubchaves { @() } -ParameterFilter { $Caminho -like '*\SYSTEM\Setup' }
    $r = Get-ColetaResumo
    $r.SOInstaladoEm | Should -Be '2024-01-15 10:30:00'
  }

  It 'Resumo sem WMI usa InstallDate do registro' {
    Mock Get-CimSafe { throw 'x' }
    Mock Get-RegValores { @{ InstallDate = 1577880000; CurrentBuild = '26100' } }
    Mock Get-RegSubchaves { @() }
    $r = Get-ColetaResumo
    $esperado = ConvertTo-DataTexto ([DateTimeOffset]::FromUnixTimeSeconds(1577880000).LocalDateTime)
    $r.SOAtualizadoEm | Should -Be $esperado
    $r.SOInstaladoEm | Should -Be $esperado
  }

  It 'Resumo ativacao' {
    Mock Get-CimSafe { @() }
    $Script:Ctx.Resultados['09'] = @([pscustomobject]@{ Produto = 'Windows(R), Professional edition'; EstadoLicenca = 'Licenciado' })
    (Get-ColetaResumo).AtivacaoWindows | Should -Be 'Licenciado'
  }

  It 'Resumo soma discos sem USB e lista IP/MAC' {
    Mock Get-CimSafe { @() }
    $Script:Ctx.Resultados['02'] = @(
      [pscustomobject]@{ Tipo = 'Disco'; Capacidade = [double]100.5; Detalhe = 'Interface=SCSI;x' },
      [pscustomobject]@{ Tipo = 'Disco'; Capacidade = [double]500; Detalhe = 'Interface=USB;x' },
      [pscustomobject]@{ Tipo = 'BIOS'; Capacidade = $null; Detalhe = '' })
    $Script:Ctx.Resultados['04'] = @([pscustomobject]@{ Tipo = 'Adaptador'; MAC = 'AA'; EnderecosIP = '10.0.0.1' },
      [pscustomobject]@{ Tipo = 'Adaptador'; MAC = 'BB'; EnderecosIP = '' })
    $r = Get-ColetaResumo
    $r.DiscoTotalGB | Should -Be 100.5
    $r.EnderecosIP | Should -Be '10.0.0.1'
    $r.EnderecosMAC | Should -Be 'AA'
  }

  It 'JSON array de 1 item' {
    $Script:Ctx.Resultados['05'] = @([pscustomobject]@{ Nome = 'u' })
    $Script:Ctx.Resultados['06'] = @()
    $p = Join-Path $TestDrive 'a.json'
    Write-ColetaJson -Caminho $p
    $j = Get-Content $p -Raw | ConvertFrom-Json
    ($j.Contas -is [array]) | Should -BeTrue
    @($j.Contas).Count | Should -Be 1
    @($j.Perfis).Count | Should -Be 0
    (Get-Content $p -Raw) | Should -Match '"Perfis":\s*\[\s*\]'
  }

  It 'JSON datas como texto' {
    $Script:Ctx.Resultados['05'] = @([pscustomobject]@{ Nome = 'u'; Quando = [datetime]'2026-01-02 03:04:05'; Ok = $true })
    $p = Join-Path $TestDrive 'b.json'
    Write-ColetaJson -Caminho $p
    $raw = Get-Content $p -Raw
    $raw | Should -Match '"2026-01-02 03:04:05"'
    $raw | Should -Not -Match 'Date\('
    $raw | Should -Match '"Sim"'
  }

  It 'JSON acentos e BOM' {
    $Script:Ctx.Resultados['05'] = @([pscustomobject]@{ Nome = 'ção' })
    $p = Join-Path $TestDrive 'c.json'
    Write-ColetaJson -Caminho $p
    $b = [IO.File]::ReadAllBytes($p)
    $b[0] | Should -Be 0xEF; $b[1] | Should -Be 0xBB; $b[2] | Should -Be 0xBF
    ([IO.File]::ReadAllText($p) | ConvertFrom-Json).Contas[0].Nome | Should -Be 'ção'
    ([IO.File]::ReadAllText($p) | ConvertFrom-Json).Identificacao.IdEquipamentoOrigem | Should -Be 'UUID=A|BIOS=B|PLACA=C|DISCO=D'
    $ident = ([IO.File]::ReadAllText($p) | ConvertFrom-Json).Identificacao
    $ident.ExecutadoPor | Should -Be 'Bia'
    foreach ($c in 'VersaoScript', 'HashScript', 'Autor', 'EmailAutor', 'Responsavel') { $ident.PSObject.Properties.Name | Should -Not -Contain $c }
  }

  It 'TXT contem secoes e status' {
    $Script:Ctx.Resultados['01'] = @([pscustomobject]@{ Etiqueta = 'E1' })
    $Script:Ctx.Resultados['08'] = @([pscustomobject]@{ Fonte = 'Amcache'; Item = 'a' }, [pscustomobject]@{ Fonte = 'BAM'; Item = 'b' })
    $Script:Ctx.Status.Add([pscustomobject]@{ Numero = '07'; Nome = 'Software instalado'; Status = 'OK'; Itens = 3; Segundos = 1; Mensagem = '' })
    $Script:Ctx.Status.Add([pscustomobject]@{ Numero = '10'; Nome = 'Servicos'; Status = 'Falha'; Itens = 0; Segundos = 1; Mensagem = 'boom' })
    $p = Join-Path $TestDrive 'a.txt'
    Write-ColetaTxt -Caminho $p
    $t = [IO.File]::ReadAllText($p)
    $t | Should -Match 'INVENTÁRIO DA ESTAÇÃO'
    $t | Should -Not -Match 'INVENTARIO DA ESTACAO'
    $t | Should -Match 'ExecutadoPor\s*: Bia'
    $t | Should -Not -Match 'Responsavel'
    $t | Should -Not -Match 'VersaoScript|HashScript|Thiago|peritoemti'
    [IO.File]::ReadAllBytes($p)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    $t | Should -Match 'IdEquipamentoOrigem\s*: UUID=A'
    $t | Should -Match '07 - Software instalado \(3 itens\)'
    $t | Should -Match '08 - Vestigios de software \(2 itens\)'
    $t | Should -Match '10\s+Servicos\s+Falha'
    $t | Should -Match 'Amcache'
  }

  It 'TXT: areas 15 e 16 so com a contagem e referencia ao CSV' {
    $Script:Ctx.Resultados['15'] = @(1..3 | ForEach-Object { [pscustomobject]@{ Local = 'Downloads'; Arquivo = "instalador$_.exe" } })
    $Script:Ctx.Resultados['16'] = @([pscustomobject]@{ Local = 'Disco C'; Arquivo = 'outro.msi' })
    $p = Join-Path $TestDrive 'b.txt'
    Write-ColetaTxt -Caminho $p
    $t = [IO.File]::ReadAllText($p)
    $t | Should -Match '15 - Arquivos instaladores \(3 itens\)\r\n=+\r\n3 itens - ver csv\\15_Arquivos_Instaladores\.csv'
    $t | Should -Match '1 itens - ver csv\\16_Arquivos_Completa\.csv'
    $t | Should -Not -Match 'instalador1\.exe'
    $t | Should -Not -Match 'outro\.msi'
  }

  It 'TXT: Fonte do 08 com mais de 2000 linhas vira contagem; as menores continuam em tabela' {
    $grande = @(1..2001 | ForEach-Object { [pscustomobject]@{ Fonte = 'AmcacheArquivo'; Item = "arq$_" } })
    $Script:Ctx.Resultados['08'] = @($grande) + @([pscustomobject]@{ Fonte = 'BAM'; Item = 'pequeno' })
    $p = Join-Path $TestDrive 'c.txt'
    Write-ColetaTxt -Caminho $p
    $t = [IO.File]::ReadAllText($p)
    $t | Should -Match '--- Fonte: AmcacheArquivo \(2001 itens\) ---\r\n2001 itens - ver csv\\08_Software_Vestigios\.csv'
    $t | Should -Not -Match 'arq17'
    $t | Should -Match '--- Fonte: BAM \(1 itens\) ---'
    $t | Should -Match 'pequeno'
  }

  It 'TXT: Fonte do 08 com exatamente 2000 linhas continua em tabela' {
    $Script:Ctx.Resultados['08'] = @(1..2000 | ForEach-Object { [pscustomobject]@{ Fonte = 'Prefetch'; Item = "p$_" } })
    $p = Join-Path $TestDrive 'd.txt'
    Write-ColetaTxt -Caminho $p
    [IO.File]::ReadAllText($p) | Should -Match 'p1999'
  }

  It 'TXT: Argumentos da area 11 truncados em 200 caracteres; o CSV mantem completo' {
    $longo = 'a' * 199 + 'b' + 'FIMDOARGUMENTO'
    $Script:Ctx.Resultados['11'] = @([pscustomobject]@{ Caminho = '\'; Nome = 'T'; Argumentos = $longo })
    $p = Join-Path $TestDrive 'e.txt'
    Write-ColetaTxt -Caminho $p
    $t = [IO.File]::ReadAllText($p)
    $t | Should -Match ('a{199}b\.\.\.')
    $t | Should -Not -Match 'FIMDOARGUMENTO'
    $csv = Join-Path $TestDrive 'e.csv'
    Export-CsvPadrao -Caminho $csv -Colunas $Script:Contrato['11'].Colunas -Itens $Script:Ctx.Resultados['11'] -Comum ([ordered]@{ Hostname = 'H'; IdEquipamento = 'I'; DataColeta = 'D' })
    [IO.File]::ReadAllText($csv) | Should -Match 'FIMDOARGUMENTO'
  }
}

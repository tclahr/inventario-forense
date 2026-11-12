BeforeAll {
  . "$PSScriptRoot/../../InventarioForense.ps1"
  $Script:Comum = [ordered]@{ Hostname = 'H'; IdEquipamento = 'ID'; DataColeta = '2026-11-12 14:30:00' }
  function Script:Novo-Caminho { Join-Path ([IO.Path]::GetTempPath()) ("csvtest_" + [guid]::NewGuid().ToString('N') + '\sub\x.csv') }
  function Script:Ler-Linhas($p) { , @([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) -split "`r`n" | Where-Object { $_ -ne '' }) }
}

Describe 'Contrato' {
  It 'Contrato tem 16 areas e colunas da spec' {
    $Script:Contrato.Keys.Count | Should -Be 16
    ($Script:Contrato['08'].Colunas -join ';') | Should -Be 'Fonte;Item;Caminho;Fabricante;Versao;Data;TipoData;Usuario;Detalhe'
    ($Script:Contrato['07'].Colunas -join ';') | Should -Be 'Fonte;Nome;Versao;Fabricante;DataInstalacao;LocalInstalacao;Desinstalador;Usuario;ComponenteSistema;ChaveRegistro'
    $Script:Contrato['16'].Colunas | Should -Be $Script:Contrato['15'].Colunas
    foreach ($k in $Script:Contrato.Keys) {
      foreach ($c in $Script:Contrato[$k].Colunas) { $c | Should -Match '^[A-Za-z0-9]+$' }
    }
  }
  It 'arquivos e chaves conforme o brief' {
    $Script:Contrato['01'].Arquivo | Should -Be '01_Resumo.csv'
    $Script:Contrato['16'].Chave | Should -Be 'ArquivosCompleta'
    $Script:Contrato['05'].Nome | Should -Be 'Contas locais'
    ($Script:ColunasComuns -join ';') | Should -Be 'Hostname;IdEquipamento;DataColeta'
  }
}

Describe 'Export-CsvPadrao' {
  BeforeEach { $Script:P = Novo-Caminho }
  AfterEach { Remove-Item (Split-Path (Split-Path $Script:P)) -Recurse -Force -ErrorAction SilentlyContinue }

  It 'CSV vazio tem so cabecalho' {
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A', 'B') -Itens @() -Comum $Script:Comum
    $l = Ler-Linhas $Script:P
    $l.Count | Should -Be 1
    $l[0] | Should -Be '"Hostname";"IdEquipamento";"DataColeta";"A";"B"'
    ([IO.File]::ReadAllBytes($Script:P))[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
  }
  It 'Campos com ; aspas e quebra de linha' {
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A', 'B') -Itens @([pscustomobject]@{A = 'x;y "z"'; B = "l1`r`nl2" }) -Comum $Script:Comum
    $l = Ler-Linhas $Script:P
    $l.Count | Should -Be 2
    $l[1] | Should -Be '"H";"ID";"2026-11-12 14:30:00";"x;y ""z""";"l1 l2"'
  }
  It 'Decimal com virgula' {
    $old = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
      [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'en-US'
      Export-CsvPadrao -Caminho $Script:P -Colunas @('A', 'B') -Itens @([pscustomobject]@{A = 4.5; B = 1234567 }) -Comum $Script:Comum
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    (Ler-Linhas $Script:P)[1] | Should -Be '"H";"ID";"2026-11-12 14:30:00";"4,5";"1234567"'
  }
  It 'Bool, nulo e data' {
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A', 'B') -Itens @([pscustomobject]@{A = $true; B = $null }) -Comum $Script:Comum
    (Ler-Linhas $Script:P)[1] | Should -BeLike '*;"Sim";""'
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A') -Itens @([pscustomobject]@{A = [datetime]'2026-01-02 03:04:05' }) -Comum $Script:Comum
    (Ler-Linhas $Script:P)[1] | Should -BeLike '*;"2026-01-02 03:04:05"'
  }
  It 'Coluna ausente e extra' {
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A', 'B') -Itens @(@{A = '1'; Z = 'ignorada' }) -Comum $Script:Comum
    (Ler-Linhas $Script:P)[1] | Should -BeLike '*;"1";""'
    [IO.File]::ReadAllText($Script:P) | Should -Not -Match 'ignorada'
  }
  It 'Ida e volta' {
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A') -Itens @([pscustomobject]@{A = 'ção' }) -Comum $Script:Comum
    (Import-Csv -Path $Script:P -Delimiter ';' -Encoding UTF8).A | Should -Be 'ção'
  }
  It 'termina com CRLF' {
    Export-CsvPadrao -Caminho $Script:P -Colunas @('A') -Itens @([pscustomobject]@{A = '1' }) -Comum $Script:Comum
    [IO.File]::ReadAllText($Script:P) | Should -Match "\r\n$"
  }
}

Describe 'ConvertTo-CampoTexto' {
  It 'array unido' { ConvertTo-CampoTexto @(1, 'a', $true) | Should -Be '1, a, Sim' }
  It 'double inteiro' { ConvertTo-CampoTexto ([double]8.0) | Should -Be '8' }
  It 'TAB e trim' { ConvertTo-CampoTexto " a`tb " | Should -Be 'a b' }
  It 'funcao simples (sem CmdletBinding) com parametro posicional' {
    (Get-Command ConvertTo-CampoTexto).CmdletBinding | Should -BeFalse
    ConvertTo-CampoTexto "  x`r`n`ty  " | Should -Be 'x y'
    ConvertTo-CampoTexto -Valor ' z ' | Should -Be 'z'
    ConvertTo-CampoTexto $null | Should -Be ''
    ConvertTo-CampoTexto '' | Should -Be ''
    ConvertTo-CampoTexto ([int64]5) | Should -Be '5'
  }
}

Describe 'Export-CsvPadrao em volume' {
  It 'Dicionario e objeto, comum vazio e texto com quebras geram o mesmo formato' {
    $p = Novo-Caminho
    $itens = @([ordered]@{ A = 'a"1'; B = $false }, [pscustomobject]@{ A = " b`n2 "; B = 3.25 })
    Export-CsvPadrao -Caminho $p -Colunas @('A', 'B') -Itens $itens -Comum $Script:Comum
    $l = Ler-Linhas $p
    $l[1] | Should -Be '"H";"ID";"2026-11-12 14:30:00";"a""1";"Nao"'
    $l[2] | Should -Be '"H";"ID";"2026-11-12 14:30:00";"b 2";"3,25"'
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  }
  It '20 mil linhas em poucos segundos' {
    $p = Novo-Caminho
    $itens = @(for ($i = 0; $i -lt 20000; $i++) { [pscustomobject]@{ A = "C:\pasta $i\a.exe"; B = $i; C = 'x'; D = 'y'; E = 'z' } })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Export-CsvPadrao -Caminho $p -Colunas @('A', 'B', 'C', 'D', 'E') -Itens $itens -Comum $Script:Comum
    $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
    (Ler-Linhas $p).Count | Should -Be 20001
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  }
}

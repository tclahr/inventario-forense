BeforeAll {
    . "$PSScriptRoot/../../InventarioForense.ps1"
    function New-ShimEntrada([string]$c,[datetime]$d){ $b=[Text.Encoding]::Unicode.GetBytes($c); $ms=New-Object IO.MemoryStream; $w=New-Object IO.BinaryWriter $ms
      $corpo=New-Object IO.MemoryStream; $wc=New-Object IO.BinaryWriter $corpo; $wc.Write([uint16]$b.Length); $wc.Write($b); $wc.Write([int64]$d.ToFileTime()); $wc.Write([uint32]0)
      $w.Write([Text.Encoding]::ASCII.GetBytes('10ts')); $w.Write([uint32]0); $w.Write([uint32]$corpo.Length); $w.Write($corpo.ToArray()); $ms.ToArray() }
    function New-ShimCache($entradas){ $h=New-Object byte[] 0x34; [BitConverter]::GetBytes([uint32]0x34).CopyTo($h,0); [byte[]]($h + ($entradas | ForEach-Object { $_ })) }
}

Describe 'ConvertFrom-ShimCache' {
    It 'Duas entradas' {
        $d1 = Get-Date '2026-03-04 05:06:07'
        $e1 = New-ShimEntrada 'C:\A\x.exe' $d1
        $e2 = New-ShimEntrada 'C:\Program Files\Ç\y.exe' $d1
        $r = @(ConvertFrom-ShimCache -Dados (New-ShimCache @(,$e1 + ,$e2)))
        $r.Count | Should -Be 2
        $r[0].Posicao | Should -Be 1
        $r[1].Posicao | Should -Be 2
        $r[0].Caminho | Should -Be 'C:\A\x.exe'
        $r[1].Caminho | Should -Be 'C:\Program Files\Ç\y.exe'
        $r[0].Modificado | Should -Be '2026-03-04 05:06:07'
    }
    It 'Assinatura invalida lanca' {
        $h = New-Object byte[] 0x34; [BitConverter]::GetBytes([uint32]0x34).CopyTo($h,0)
        $buf = [byte[]]($h + [Text.Encoding]::ASCII.GetBytes('XXXX') + (New-Object byte[] 8))
        { ConvertFrom-ShimCache -Dados $buf } | Should -Throw '*nao suportado*'
    }
    It 'So cabecalho, sem entradas (Win11 25H2, build 26200), devolve vazio sem lancar' {
        $h = New-Object byte[] 0x34; [BitConverter]::GetBytes([uint32]0x34).CopyTo($h,0); $h[16] = 4
        @(ConvertFrom-ShimCache -Dados $h).Count | Should -Be 0
    }
    It 'Buffer curto lanca' {
        { ConvertFrom-ShimCache -Dados ([byte[]](1,2,3)) } | Should -Throw '*nao suportado*'
    }
    It 'Ultima entrada truncada devolve as anteriores' {
        $d = Get-Date '2026-03-04 05:06:07'
        $e1 = New-ShimEntrada 'C:\A\x.exe' $d
        $e2 = New-ShimEntrada 'C:\B\z.exe' $d
        $buf = New-ShimCache @(,$e1 + ,$e2)
        $cortado = [byte[]]($buf[0..($buf.Length - 6)])
        $r = @(ConvertFrom-ShimCache -Dados $cortado)
        $r.Count | Should -Be 1
        $r[0].Caminho | Should -Be 'C:\A\x.exe'
    }
}

Describe 'ConvertFrom-Rot13' {
    It 'Decodifica letras e preserva o resto' {
        ConvertFrom-Rot13 'P:\Cebtenz Svyrf\nqbor.rkr' | Should -Be 'C:\Program Files\adobe.exe'
        ConvertFrom-Rot13 '123-_.' | Should -Be '123-_.'
    }
}

Describe 'ConvertFrom-UserAssistValor' {
    It 'Decodifica execucoes e ultima execucao' {
        $b = New-Object byte[] 72
        [BitConverter]::GetBytes([uint32]7).CopyTo($b, 4)
        [BitConverter]::GetBytes([int64](Get-Date '2026-05-06 07:08:09').ToFileTime()).CopyTo($b, 60)
        $r = ConvertFrom-UserAssistValor -Dados $b
        $r.Execucoes | Should -Be 7
        $r.UltimaExecucao | Should -Be '2026-05-06 07:08:09'
    }
    It 'Menos de 68 bytes devolve null' {
        ConvertFrom-UserAssistValor -Dados (New-Object byte[] 16) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-WmiCharArray' {
    It 'Para nos zeros' {
        ConvertFrom-WmiCharArray -Valor ([uint16[]](68,69,76,76,0,0)) | Should -Be 'DELL'
    }
}

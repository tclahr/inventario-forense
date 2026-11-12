BeforeAll { . "$PSScriptRoot/../../InventarioForense.ps1" }

Describe 'Get-IdEquipamento' {
    It 'Origem formatada' {
        $o = Get-IdEquipamento -Uuid 'abc-1' -SerialBios ' x 1 ' -SerialPlaca 'P9' -SeriaisDisco @('d2','D1')
        $o.Origem | Should -Be 'UUID=ABC-1|BIOS=X1|PLACA=P9|DISCO=D1,D2'
    }
    It 'Hash = SHA-256 UTF-8 sem BOM da origem' {
        $o = Get-IdEquipamento -Uuid 'abc-1' -SerialBios 'x1' -SerialPlaca 'P9' -SeriaisDisco @('d1')
        $sha = [Security.Cryptography.SHA256]::Create()
        $h = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($o.Origem)) | ForEach-Object { $_.ToString('X2') }) -join ''
        $o.Id | Should -BeExactly $h
        $o.Id | Should -Match '^[0-9A-F]{64}$'
    }
    It 'Genericos descartados' {
        $o = Get-IdEquipamento -Uuid 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF' -SerialBios 'To be filled by O.E.M.' -SerialPlaca 'Default string' -SeriaisDisco @('0','S1')
        $o.Origem | Should -Be 'UUID=|BIOS=|PLACA=|DISCO=S1'
    }
    It 'Ordem ordinal' {
        $o = Get-IdEquipamento -Uuid 'u' -SerialBios 'b' -SerialPlaca 'p' -SeriaisDisco @('b','B','a')
        $o.Origem | Should -Be 'UUID=U|BIOS=B|PLACA=P|DISCO=A,B,B'
        $antiga = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]'tr-TR'
            $t = Get-IdEquipamento -Uuid 'u' -SerialBios 'b' -SerialPlaca 'p' -SeriaisDisco @('i','I')
            $t.Origem | Should -Be 'UUID=U|BIOS=B|PLACA=P|DISCO=I,I'
        } finally { [cultureinfo]::CurrentCulture = $antiga }
    }
    It 'Estavel' {
        $a = Get-IdEquipamento -Uuid 'u1' -SerialBios 'b' -SerialPlaca 'p' -SeriaisDisco @('x','y')
        $b = Get-IdEquipamento -Uuid 'u1' -SerialBios 'b' -SerialPlaca 'p' -SeriaisDisco @('x','y')
        $a.Id | Should -Be $b.Id
    }
}

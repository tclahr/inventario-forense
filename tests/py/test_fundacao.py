import hashlib
import re
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py import fabrica  # noqa: E402


class TestFundacao(unittest.TestCase):
    def test_contrato_igual_ao_coletor(self):
        texto = (RAIZ / 'InventarioForense.ps1').read_text(encoding='utf-8-sig')
        padrao = re.compile(
            r"'(\d\d)'\s*=\s*@\{\s*Arquivo\s*=\s*'([^']+)';.*?Colunas\s*=\s*\[string\[\]\]@\((.*?)\)\s*\}",
            re.S)
        achados = {m.group(1): (m.group(2), re.findall(r"'([^']*)'", m.group(3)))
                   for m in padrao.finditer(texto)}
        self.assertEqual(sorted(achados), [f'{i:02d}' for i in range(1, 17)])
        self.assertEqual(sorted(cc.AREAS), sorted(achados))
        for num, (arquivo, colunas) in achados.items():
            self.assertEqual(cc.AREAS[num].arquivo, arquivo)
            self.assertEqual(list(cc.AREAS[num].colunas), colunas)

    def test_descobrir_zips_so_prefixo_inventarioforense(self):
        with tempfile.TemporaryDirectory() as t:
            raiz = Path(t)
            for nome in ('InventarioForense_A_1.zip', 'ColetaForense_B_1.zip', 'Outro_C_1.zip'):
                (raiz / nome).write_bytes(b'x')
            (raiz / 'InventarioForense_dir.zip').mkdir()
            achados = [p.name for p in cc.descobrir_zips(raiz)]
        self.assertEqual(achados, ['InventarioForense_A_1.zip'])
        self.assertEqual(cc._hostname_do_nome('InventarioForense_PC-01_1'), 'PC-01')
        self.assertEqual(cc._hostname_do_nome('ColetaForense_PC-02_1'), '')
        self.assertEqual(cc._hostname_do_nome('Outro_PC-03_1'), '')

    def test_csv_ida_e_volta(self):
        valor = {'A': '"C:\\Program Files\\7-Zip\\Uninstall.exe"', 'B': 'x;y\r\nz ção'}
        with tempfile.TemporaryDirectory() as t:
            caminho = Path(t) / 'sub' / 'a.csv'
            n = cc.escrever_csv(caminho, ['A', 'B'], [valor])
            dados = caminho.read_bytes()
        self.assertEqual(n, 1)
        self.assertTrue(dados.startswith(b'\xef\xbb\xbf'))
        self.assertEqual(dados[3:].split(b'\r\n')[0], b'"A";"B"')
        cab, linhas = cc.ler_csv(dados)
        self.assertEqual(cab, ['A', 'B'])
        self.assertEqual(linhas, [valor])

    def test_campo_grande_ida_e_volta(self):
        valor = {'A': 'x' * 140000}
        with tempfile.TemporaryDirectory() as t:
            caminho = Path(t) / 'g.csv'
            cc.escrever_csv(caminho, ['A'], [valor])
            _, linhas = cc.ler_csv(caminho.read_bytes())
        self.assertEqual(linhas, [valor])

    def test_ler_csv_erro_do_csv_vira_erro_csv(self):
        # NUL so falha em Python 3.10; o limite de campo falha em qualquer versao
        import csv
        antigo = csv.field_size_limit(50)
        try:
            with self.assertRaises(cc.ErroCsv):
                cc.ler_csv(('"A"\r\n"' + 'x' * 100 + '"\r\n').encode('utf-8'))
        finally:
            csv.field_size_limit(antigo)

    def test_formatar_valor(self):
        self.assertEqual(cc.formatar_valor(True), 'Sim')
        self.assertEqual(cc.formatar_valor(False), 'Nao')
        self.assertEqual(cc.formatar_valor(None), '')
        self.assertEqual(cc.formatar_valor(7.98), '7,98')
        self.assertEqual(cc.formatar_valor(3), '3')

    def test_ler_csv_invalido(self):
        with self.assertRaises(cc.ErroCsv):
            cc.ler_csv(b'\xff\xfe')
        with self.assertRaises(cc.ErroCsv):
            cc.ler_csv(b'')
        with self.assertRaises(cc.ErroCsv):
            cc.ler_csv(b'\xef\xbb\xbf"A"\r\n"1";"2"\r\n')

    def test_sha256(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / 'x'
            p.write_bytes(b'abc')
            self.assertEqual(cc.sha256_arquivo(p), cc.sha256_bytes(b'abc'))
        self.assertEqual(cc.sha256_bytes(b'abc'), hashlib.sha256(b'abc').hexdigest())

    def test_fabrica_gera_zip_valido(self):
        with tempfile.TemporaryDirectory() as t:
            z = fabrica.nova_coleta(Path(t))
            sha = Path(str(z) + '.sha256')
            self.assertTrue(z.exists() and sha.exists())
            esperado = sha.read_text(encoding='utf-8')
            self.assertEqual(esperado, f'{cc.sha256_arquivo(z)}  {z.name}\n')
            with zipfile.ZipFile(z) as zf:
                raiz = z.stem
                sums = zf.read(f'{raiz}/SHA256SUMS.txt').decode('utf-8')
                self.assertIn('csv/01_Resumo.csv', sums)
                self.assertNotIn('16_Arquivos', ' '.join(zf.namelist()))
                cab, linhas = cc.ler_csv(zf.read(f'{raiz}/csv/01_Resumo.csv'))
            self.assertEqual(cab[:3], list(cc.COLUNAS_COMUNS))
            self.assertEqual(linhas[0]['Modo'], 'Padrao')


if __name__ == '__main__':
    unittest.main()

import sys
import unittest
from unittest import mock
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py.test_carga_selecao import Base  # noqa: E402

HASH = 'ab' * 32


class TestAnalises(Base):
    def test_instaladores_por_hash(self):
        c1, _ = self.carregar(hostname='PC1', areas={'15': [
            {'Arquivo': 'setup.exe', 'Caminho': 'C:/a', 'TamanhoBytes': '10', 'SHA256': HASH}]})
        c2, _ = self.carregar(hostname='PC2', id_equipamento='B' * 64, modo='Completa', areas={'16': [
            {'Arquivo': 'setup.exe', 'Caminho': 'D:/b', 'TamanhoBytes': '10', 'SHA256': HASH}]})
        r = cc.instaladores(self.con, [c1, c2])
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]['Maquinas'], 2)
        self.assertEqual(r[0]['Caminhos'], 'C:/a | D:/b')
        self.assertEqual(r[0]['Hostnames'], 'PC1 | PC2')
        self.assertEqual(list(r[0]), list(cc.COLUNAS_INSTALADORES))

    def test_instaladores_sem_hash(self):
        c1, _ = self.carregar(hostname='PC1', areas={'15': [
            {'Arquivo': 'Setup.exe', 'Caminho': 'C:/a', 'TamanhoBytes': '10', 'SHA256': ''}]})
        c2, _ = self.carregar(hostname='PC2', id_equipamento='B' * 64, areas={'15': [
            {'Arquivo': 'setup.exe', 'Caminho': 'C:/z', 'TamanhoBytes': '10', 'SHA256': ''},
            {'Arquivo': 'setup.exe', 'Caminho': 'C:/y', 'TamanhoBytes': '11', 'SHA256': ''}]})
        r = cc.instaladores(self.con, [c1, c2])
        self.assertEqual(len(r), 2)
        self.assertEqual(r[0]['Maquinas'], 2)
        self.assertEqual(r[0]['Arquivo'], 'Setup.exe | setup.exe')

    def test_instaladores_so_area_15(self):
        c1, _ = self.carregar(hostname='PC1', modo='Completa', areas={
            '15': [{'Arquivo': 'a.exe', 'SHA256': 'aa'}],
            '16': [{'Arquivo': 'b.exe', 'SHA256': 'bb'}]})
        self.assertEqual(sorted(r['Arquivo'] for r in cc.instaladores(self.con, [c1])),
                         ['a.exe', 'b.exe'])
        self.assertEqual([r['Arquivo'] for r in cc.instaladores(self.con, [c1], ('15',))],
                         ['a.exe'])

    def test_instaladores_agrupa_no_sqlite(self):
        c1, _ = self.carregar(hostname='PC1', modo='Completa', areas={
            '15': [{'Arquivo': 'Instalação.exe', 'TamanhoBytes': '5'}],
            '16': [{'Arquivo': 'INSTALAÇÃO.EXE', 'TamanhoBytes': '5', 'Caminho': 'C:/x'}]})
        with mock.patch.object(cc, 'linhas_area', side_effect=AssertionError('linha a linha')):
            r = cc.instaladores(self.con, [c1])
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]['Arquivo'], 'INSTALAÇÃO.EXE | Instalação.exe')
        self.assertEqual(r[0]['Maquinas'], 1)
        self.assertEqual(r[0]['Caminhos'], 'C:/x')

    def test_licencas_inclui_windows(self):
        c, _ = self.carregar(resumo={'AtivacaoWindows': 'Licenciado'}, areas={'09': [
            {'Produto': 'Office', 'EstadoLicenca': 'Notificacao'}]})
        r = cc.licencas(self.con, [c])
        self.assertEqual(r[0]['Produto'], 'Windows')
        self.assertEqual(r[0]['EstadoLicenca'], 'Licenciado')
        self.assertEqual(r[1]['Produto'], 'Office')
        self.assertEqual(r[1]['Hostname'], 'PC1')
        self.assertEqual(list(r[1]), list(cc.COLUNAS_LICENCAS))

    def test_linhas_coletas(self):
        c1, _ = self.carregar(data='2026-11-12 10:00:00')
        c2, _ = self.carregar(data='2026-11-13 10:00:00')
        cc.selecionar_coletas([c1, c2])
        r = {l['IdColeta']: l for l in cc.linhas_coletas([c1, c2])}
        l = r[c1.id_coleta]
        self.assertEqual(l['Situacao'], 'Substituida')
        self.assertEqual(l['SubstituidaPor'], c2.id_coleta)
        self.assertEqual(list(l), list(cc.COLUNAS_COLETAS))
        self.assertEqual(r[c2.id_coleta]['Situacao'], 'Usada')


if __name__ == '__main__':
    unittest.main()

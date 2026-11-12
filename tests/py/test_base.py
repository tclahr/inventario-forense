import sys
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402


class TestBase(unittest.TestCase):
    def setUp(self):
        self.con = cc.abrir_base(Path(':memory:'))
        self.addCleanup(self.con.close)

    def test_tabelas_e_colunas(self):
        cols = [r[1] for r in self.con.execute('PRAGMA table_info(software_instalado)')]
        self.assertEqual(cols, ['IdColeta', 'Hostname', 'IdEquipamento', 'DataColeta']
                         + list(cc.AREAS['07'].colunas))
        cols = [r[1] for r in self.con.execute('PRAGMA table_info(coletas)')]
        self.assertEqual(cols[0], 'IdColeta')
        self.assertIn('MotivoSelecao', cols)

    def test_inserir_e_ler(self):
        area = cc.AREAS['07']
        c0, c1 = area.colunas[0], area.colunas[1]
        valor = 'a;b "c"\r\nd ção'
        n = cc.inserir_linhas(self.con, area, 'X1', [
            {'Hostname': 'H', c0: valor, 'Extra': 'ignorada'},
            {'Hostname': 'H2', c1: 'z'},
        ])
        self.assertEqual(n, 2)
        linhas = cc.linhas_area(self.con, '07', 'X1')
        self.assertEqual(len(linhas), 2)
        self.assertEqual(linhas[0][c0], valor)
        self.assertEqual(linhas[0][c1], '')
        self.assertEqual(linhas[1]['Hostname'], 'H2')
        self.assertEqual(linhas[1][c1], 'z')
        self.assertNotIn('Extra', linhas[0])
        self.assertNotIn('IdColeta', linhas[0])
        self.assertEqual(cc.linhas_area(self.con, '07', 'outro'), [])

    def test_views_filtram_situacao(self):
        area = cc.AREAS['01']
        for idc, sit in (('U', 'Usada'), ('S', 'Substituida')):
            self.con.execute('INSERT INTO coletas (IdColeta, Situacao) VALUES (?, ?)', (idc, sit))
            cc.inserir_linhas(self.con, area, idc, [{'Hostname': idc}])
        cc.criar_indices_e_views(self.con)
        rows = self.con.execute('SELECT IdColeta FROM v_resumo').fetchall()
        self.assertEqual(rows, [('U',)])

    def test_q(self):
        self.assertEqual(cc.q('a"b'), '"a""b"')


if __name__ == '__main__':
    unittest.main()

import logging
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py import fabrica  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        logging.getLogger('consolida').addHandler(logging.NullHandler())
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pasta = Path(self.tmp.name)
        self.con = cc.abrir_base(Path(':memory:'))
        self.addCleanup(self.con.close)

    def carregar(self, aceitar=False, **kw):
        zp = fabrica.nova_coleta(self.pasta, **kw)
        v = cc.verificar_zip(zp)
        sit, mot = cc.situacao_inicial(v, aceitar)
        return cc.carregar_coleta(self.con, v, sit, mot)

    @staticmethod
    def tipos(alertas):
        return [a.tipo for a in alertas]


class TestCarga(Base):
    def test_carga_basica(self):
        col_sw = cc.AREAS['07'].colunas[0]
        linhas = [{col_sw: f'Prog{i}'} for i in range(3)]
        c, alertas = self.carregar(areas={'07': linhas})
        self.assertEqual(c.situacao, 'Verificada')
        self.assertEqual(alertas, [])
        self.assertEqual(c.hostname, 'PC1')
        self.assertEqual(c.modo, 'Padrao')
        self.assertTrue(c.admin)
        self.assertTrue(c.verificada)
        self.assertIn('07', c.areas_carregadas)
        self.assertEqual(len(cc.linhas_area(self.con, '07', c.id_coleta)), 3)
        self.assertEqual(len(cc.linhas_area(self.con, '01', c.id_coleta)), 1)

    def test_resumo_antigo(self):
        antigas = [c for c in cc.AREAS['01'].colunas if c != 'ExecutadoPor'] + \
            ['Responsavel', 'VersaoScript', 'HashScript']
        c, alertas = self.carregar(colunas_resumo=antigas)
        self.assertNotEqual(c.situacao, 'Rejeitada')
        a = [x for x in alertas if x.tipo == 'ColunaAusente']
        self.assertEqual(len(a), 1)
        self.assertIn('ExecutadoPor', a[0].mensagem)

    def test_area_ausente(self):
        c, alertas = self.carregar(omitir_areas=['10'])
        self.assertIn('AreaAusente', self.tipos(alertas))
        c, alertas = self.carregar(omitir_areas=['10'], hostname='PC2',
                                   resumo={'AreasComFalha': '10 Servicos'})
        self.assertNotIn('AreaAusente', self.tipos(alertas))
        self.assertIn('AreaComFalha', self.tipos(alertas))
        c, alertas = self.carregar(omitir_areas=['10'], hostname='PC5', resumo={'AreasComFalha': '10'})
        self.assertIn('AreaAusente', self.tipos(alertas))
        c, alertas = self.carregar(hostname='PC3', modo='Padrao')
        self.assertNotIn('AreaAusente', self.tipos(alertas))
        c, alertas = self.carregar(hostname='PC4', modo='Completa', omitir_areas=['16'])
        self.assertIn('AreaAusente', self.tipos(alertas))

    def test_resumo_ausente_rejeita(self):
        c, alertas = self.carregar(omitir_areas=['01'])
        self.assertEqual(c.situacao, 'Rejeitada')
        self.assertEqual(c.motivo, 'Resumo ausente')
        self.assertEqual(self.tipos(alertas), ['ColetaRejeitada'])

    def test_rejeitada_na_chegada(self):
        zp = fabrica.nova_coleta(self.pasta)
        v = cc.verificar_zip(zp)
        c, alertas = cc.carregar_coleta(self.con, v, 'Rejeitada', 'hash difere')
        self.assertEqual(self.tipos(alertas), ['ColetaRejeitada'])
        self.assertEqual(alertas[0].mensagem, 'hash difere')
        self.assertEqual(c.resumo, {})
        self.assertEqual(cc.linhas_area(self.con, '01', c.id_coleta), [])

    def test_alertas_do_resumo(self):
        c, alertas = self.carregar(admin='Nao', resumo={'AreasPuladas': '16 Arquivos, 07:Fonte'})
        t = self.tipos(alertas)
        self.assertIn('SemAdmin', t)
        self.assertEqual(t.count('AreaPulada'), 2)

    def test_nao_verificada(self):
        c, alertas = self.carregar(aceitar=True, com_sha256=False)
        self.assertEqual(c.situacao, 'NaoVerificada')
        self.assertFalse(c.verificada)
        self.assertIn('ColetaNaoVerificada', self.tipos(alertas))


def col(**kw):
    return kw


class TestSelecao(Base):
    def test_selecao_completa_vence(self):
        a, _ = self.carregar(modo='Padrao', data='2026-11-12 12:00:00')
        b, _ = self.carregar(modo='Completa', data='2026-11-12 10:00:00')
        al = cc.selecionar_coletas([a, b])
        self.assertEqual(b.situacao, 'Usada')
        self.assertEqual(a.situacao, 'Substituida')
        self.assertEqual(a.substituida_por, b.id_coleta)
        self.assertEqual(a.motivo_selecao, f'Substituida por {b.id_coleta}')
        self.assertEqual(self.tipos(al), ['Substituida'])
        self.assertTrue(b.motivo_selecao.startswith('Completa; admin'))

    def test_admin_vence(self):
        a, _ = self.carregar(admin='Nao', data='2026-11-12 12:00:00')
        b, _ = self.carregar(admin='Sim', data='2026-11-12 10:00:00')
        cc.selecionar_coletas([a, b])
        self.assertEqual((a.situacao, b.situacao), ('Substituida', 'Usada'))

    def test_mais_recente_vence(self):
        a, _ = self.carregar(data='2026-11-12 10:00:00')
        b, _ = self.carregar(data='2026-11-12 12:00:00')
        cc.selecionar_coletas([a, b])
        self.assertEqual((a.situacao, b.situacao), ('Substituida', 'Usada'))
        self.assertIn('mais recente', b.motivo_selecao)

    def test_verificada_vence_nao_verificada(self):
        a, _ = self.carregar(aceitar=True, com_sha256=False, data='2026-11-12 12:00:00')
        b, _ = self.carregar(data='2026-11-12 12:00:00', nome='InventarioForense_PC1_20261112120000b.zip')
        cc.selecionar_coletas([a, b])
        self.assertEqual(a.situacao, 'Substituida')
        self.assertEqual(b.situacao, 'Usada')

    def test_nao_verificada_unica_continua(self):
        a, _ = self.carregar(aceitar=True, com_sha256=False)
        cc.selecionar_coletas([a])
        self.assertEqual(a.situacao, 'NaoVerificada')
        self.assertIn('unica coleta', a.motivo_selecao)

    def test_rejeitada_fora_da_selecao(self):
        a, _ = self.carregar(omitir_areas=['01'])
        b, _ = self.carregar(hostname='PC2')
        cc.selecionar_coletas([a, b])
        self.assertEqual(a.situacao, 'Rejeitada')
        self.assertEqual(b.situacao, 'Usada')

    def test_hostname_repetido(self):
        a, _ = self.carregar(id_equipamento='A' * 64)
        b, _ = self.carregar(id_equipamento='B' * 64, data='2026-11-12 11:00:00')
        al = cc.selecionar_coletas([a, b])
        self.assertEqual((a.situacao, b.situacao), ('Usada', 'Usada'))
        rep = [x for x in al if x.tipo == 'HostnameRepetido']
        self.assertEqual(len(rep), 1)
        self.assertEqual(rep[0].mensagem, 'Hostname PC1 com 2 IdEquipamento distintos: AAAAAAAA, BBBBBBBB')

    def test_hostname_repetido_ignora_id_vazio(self):
        a, _ = self.carregar(id_equipamento='')
        b, _ = self.carregar(id_equipamento='B' * 64, data='2026-11-12 11:00:00')
        al = cc.selecionar_coletas([a, b])
        self.assertNotIn('HostnameRepetido', self.tipos(al))

    def test_gravar_coletas(self):
        a, _ = self.carregar(aceitar=True, com_sha256=False)
        b, _ = self.carregar(hostname='PC9', id_equipamento='C' * 64)
        cc.selecionar_coletas([a, b])
        cc.gravar_coletas(self.con, [a, b])
        r = self.con.execute('SELECT Hostname, HashConfere, ManifestoConfere, Situacao, Arquivo '
                             'FROM coletas WHERE IdColeta = ?', (b.id_coleta,)).fetchone()
        self.assertEqual(r[0], 'PC9')
        self.assertEqual(r[1:4], ('Sim', 'Sim', 'Usada'))
        self.assertTrue(r[4].endswith('.zip'))
        r = self.con.execute('SELECT HashConfere FROM coletas WHERE IdColeta = ?', (a.id_coleta,)).fetchone()
        self.assertEqual(r[0], '')


if __name__ == '__main__':
    unittest.main()

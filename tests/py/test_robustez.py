import contextlib
import io
import logging
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime
from pathlib import Path
from unittest import mock

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py import fabrica  # noqa: E402

ID_A, ID_B = 'A' * 64, 'B' * 64
RELOGIO = datetime(2026, 11, 12, 12, 0, 0)
SW = {'07': [{'Fonte': 'Uninstall', 'Nome': 'Foo 1.0', 'Versao': '1.0', 'Fabricante': 'Acme'}],
      '08': [{'Fonte': 'Prefetch', 'Item': f'app{i}.exe'} for i in range(50)]}


def corromper(zpath: Path, sufixo: str, refazer_sha256: bool = True) -> None:
    """Estraga o fluxo deflate da entrada que termina com `sufixo` (zlib.error na leitura)."""
    with zipfile.ZipFile(zpath) as zf:
        info = next(i for i in zf.infolist() if i.filename.endswith(sufixo))
    dados = bytearray(zpath.read_bytes())
    o = info.header_offset
    inicio = o + 30 + int.from_bytes(dados[o + 26:o + 28], 'little') + \
        int.from_bytes(dados[o + 28:o + 30], 'little')
    n = min(10, info.compress_size)
    dados[inicio:inicio + n] = b'\xff' * n
    zpath.write_bytes(bytes(dados))
    if refazer_sha256:
        import hashlib
        h = hashlib.sha256(bytes(dados)).hexdigest()
        Path(str(zpath) + '.sha256').write_text(f'{h}  {zpath.name}\n', encoding='utf-8')


def ler_csv_saida(caminho: Path):
    _, linhas = cc.ler_csv(caminho.read_bytes())
    return linhas


def sem_manifesto(arquivos):
    del arquivos['SHA256SUMS.txt']


class Base(unittest.TestCase):
    def setUp(self):
        logging.getLogger('consolida').addHandler(logging.NullHandler())
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.raiz = Path(self.tmp.name)
        self.entrada = self.raiz / 'entrada'
        self.saida = self.raiz / 'saida'
        self.mapa = cc.Mapa.de_texto(cc.MAPA_EMBUTIDO, 'embutido')

    def rodar(self, aceitar=False):
        with mock.patch.object(cc, '_agora', return_value=RELOGIO):
            return cc.consolidar(self.entrada, self.saida, self.mapa, aceitar, 'teste')

    def situacoes(self, pasta):
        return {l['Hostname']: l['Situacao']
                for l in ler_csv_saida(pasta / 'csv' / 'A_Coletas.csv')}

    def sem_handlers(self):
        self.assertFalse([h for h in cc.log.handlers if not isinstance(h, logging.NullHandler)])


class TestZipDanificado(Base):
    def test_verificar_deflate_corrompido(self):
        z = fabrica.nova_coleta(self.entrada, areas=SW)
        corromper(z, '08_Software_Vestigios.csv')
        v = cc.verificar_zip(z)
        self.assertTrue(v.erro_fatal.startswith('ZIP ilegivel'), v.erro_fatal)
        self.assertEqual(cc.situacao_inicial(v, True)[0], 'Rejeitada')

    def test_verificar_arquivo_sem_leitura(self):
        z = fabrica.nova_coleta(self.entrada, areas=SW)
        with mock.patch.object(cc, 'sha256_arquivo', side_effect=PermissionError('negado')):
            v = cc.verificar_zip(z)
        self.assertTrue(v.erro_fatal.startswith('ZIP ilegivel'), v.erro_fatal)
        self.assertIn('negado', v.erro_fatal)

    def test_carregar_corrompido_rejeita_sem_linhas_parciais(self):
        z = fabrica.nova_coleta(self.entrada, areas=SW, adulterar=sem_manifesto)
        corromper(z, '08_Software_Vestigios.csv')
        v = cc.verificar_zip(z)
        sit, mot = cc.situacao_inicial(v, True)
        self.assertEqual(sit, 'NaoVerificada')
        con = cc.abrir_base(Path(':memory:'))
        self.addCleanup(con.close)
        c, alertas = cc.carregar_coleta(con, v, sit, mot)
        self.assertEqual(c.situacao, 'Rejeitada')
        self.assertTrue(c.motivo.startswith('ZIP ilegivel'), c.motivo)
        self.assertIn('ColetaRejeitada', [a.tipo for a in alertas])
        for t in ('resumo', 'software_instalado'):
            self.assertEqual(con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0], 0, t)

    def test_consolidar_continua_apos_zip_corrompido(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        z = fabrica.nova_coleta(self.entrada, hostname='PCB', id_equipamento=ID_B, areas=SW)
        corromper(z, '08_Software_Vestigios.csv')
        codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        self.assertEqual(self.situacoes(pasta), {'PCA': 'Usada', 'PCB': 'Rejeitada'})
        alertas = ler_csv_saida(pasta / 'csv' / 'A_Alertas.csv')
        rej = [a for a in alertas if a['Tipo'] == 'ColetaRejeitada']
        self.assertEqual(len(rej), 1)
        self.assertIn('ZIP ilegivel', rej[0]['Mensagem'])
        self.assertTrue((pasta / 'SHA256SUMS.txt').is_file())
        self.sem_handlers()

    def test_consolidar_arquivo_sem_leitura(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        fabrica.nova_coleta(self.entrada, hostname='PCB', id_equipamento=ID_B, areas=SW)
        real = cc.sha256_arquivo

        def falha(caminho):
            if 'PCB' in Path(caminho).name:
                raise PermissionError('acesso negado')
            return real(caminho)

        with mock.patch.object(cc, 'sha256_arquivo', side_effect=falha):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        self.assertEqual(self.situacoes(pasta), {'PCA': 'Usada', 'PCB': 'Rejeitada'})

    def test_consolidar_verificacao_com_erro_inesperado(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        fabrica.nova_coleta(self.entrada, hostname='PCB', id_equipamento=ID_B, areas=SW)
        real = cc.verificar_zip

        def falha(caminho):
            if 'PCB' in Path(caminho).name:
                raise RuntimeError('inesperado')
            return real(caminho)

        with mock.patch.object(cc, 'verificar_zip', side_effect=falha):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        self.assertEqual(self.situacoes(pasta), {'PCA': 'Usada', 'PCB': 'Rejeitada'})

    def test_pasta_com_nome_de_zip_ignorada(self):
        (self.entrada / 'InventarioForense_x.zip').mkdir(parents=True)
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cc.main([str(self.entrada), '-o', str(self.saida)]), 2)
        self.assertFalse(self.saida.exists())
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        codigo, pasta = self.rodar()
        self.assertEqual(codigo, 0)
        self.assertEqual(self.situacoes(pasta), {'PCA': 'Usada'})


class TestFalhaNaCarga(Base):
    def test_primeira_coleta_mantem_linhas(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        z = fabrica.nova_coleta(self.entrada, hostname='PCB', id_equipamento=ID_B, areas=SW,
                                adulterar=sem_manifesto)
        corromper(z, '08_Software_Vestigios.csv')
        codigo, pasta = self.rodar(aceitar=True)
        self.assertEqual(codigo, 1)
        self.assertEqual(self.situacoes(pasta), {'PCA': 'Usada', 'PCB': 'Rejeitada'})
        spm = ler_csv_saida(pasta / 'csv' / 'A_Softwares_Por_Maquina.csv')
        self.assertEqual([(r['Hostname'], r['Produto']) for r in spm], [('PCA', 'Foo')])
        con = sqlite3.connect(str(pasta / 'Consolidacao.sqlite'))
        self.addCleanup(con.close)
        self.assertEqual(con.execute('SELECT Hostname FROM resumo').fetchall(), [('PCA',)])
        self.assertEqual(con.execute('SELECT COUNT(*) FROM software_vestigios').fetchone()[0], 50)
        self.assertEqual(con.execute(
            "SELECT COUNT(*) FROM software_instalado WHERE Hostname='PCB'").fetchone()[0], 0)

    def test_erro_inesperado_na_carga_preserva_anteriores(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        fabrica.nova_coleta(self.entrada, hostname='PCB', id_equipamento=ID_B, areas=SW)
        real = cc.inserir_linhas

        def falha(con, area, id_coleta, linhas):
            if 'PCB' in id_coleta and area.numero == '08':
                raise RuntimeError('falha de carga')
            return real(con, area, id_coleta, linhas)

        with mock.patch.object(cc, 'inserir_linhas', side_effect=falha):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 1)
        self.assertEqual(self.situacoes(pasta), {'PCA': 'Usada', 'PCB': 'Rejeitada'})
        con = sqlite3.connect(str(pasta / 'Consolidacao.sqlite'))
        self.addCleanup(con.close)
        self.assertEqual(con.execute('SELECT Hostname FROM resumo').fetchall(), [('PCA',)])

    def test_base_com_journal_em_memoria(self):
        con = cc.abrir_base(self.raiz / 'b.sqlite')
        self.addCleanup(con.close)
        self.assertEqual(con.execute('PRAGMA journal_mode').fetchone()[0], 'memory')


class TestErroInesperado(Base):
    def test_consolidar_codigo_3_e_pasta_selada(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        with mock.patch.object(cc, 'selecionar_coletas', side_effect=RuntimeError('quebrou')):
            codigo, pasta = self.rodar()
        self.assertEqual(codigo, 3)
        soma = (pasta / 'SHA256SUMS.txt').read_text(encoding='utf-8')
        self.assertIn('Consolidacao.log', soma)
        log = (pasta / 'Consolidacao.log').read_text(encoding='utf-8-sig')
        self.assertIn('Traceback', log)
        self.assertIn('quebrou', log)
        self.assertIn('incompleta', log)
        self.assertIn('Codigo de saida: 3', log)
        alertas = ler_csv_saida(pasta / 'csv' / 'A_Alertas.csv')
        self.assertIn('ErroInesperado', [a['Tipo'] for a in alertas])
        self.sem_handlers()

    def test_main_codigo_3(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        err = io.StringIO()
        with mock.patch.object(cc, '_criar_pasta_saida', side_effect=PermissionError('negado')), \
                contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            codigo = cc.main([str(self.entrada), '-o', str(self.saida)])
        self.assertEqual(codigo, 3)
        self.assertIn('incompleta', err.getvalue())
        self.assertIn('negado', err.getvalue())
        self.sem_handlers()

    def test_main_codigo_3_depois_de_criar_pasta(self):
        fabrica.nova_coleta(self.entrada, hostname='PCA', id_equipamento=ID_A, areas=SW)
        err = io.StringIO()
        with mock.patch.object(cc, 'gravar_coletas', side_effect=OSError('disco cheio')), \
                contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            codigo = cc.main([str(self.entrada), '-o', str(self.saida)])
        self.assertEqual(codigo, 3)
        pasta = next(self.saida.glob('Consolidacao_*'))
        self.assertTrue((pasta / 'SHA256SUMS.txt').is_file())
        self.sem_handlers()


if __name__ == '__main__':
    unittest.main()

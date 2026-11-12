import hashlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ))

import ConsolidaColetas as cc  # noqa: E402
from tests.py import fabrica  # noqa: E402


class TestVerificacao(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.pasta = Path(self._tmp.name)

    def test_integro(self):
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta))
        self.assertEqual(v.motivos, [])
        self.assertEqual(v.erro_fatal, '')
        self.assertIs(v.hash_confere, True)
        self.assertIs(v.manifesto_confere, True)
        self.assertEqual(cc.situacao_inicial(v, False), ('Verificada', ''))

    def test_entradas_com_barra_invertida(self):
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta, separador='\\'))
        self.assertEqual(cc.situacao_inicial(v, False)[0], 'Verificada')
        self.assertIn('csv/01_Resumo.csv', v.entradas)

    def test_sem_sha256(self):
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta, com_sha256=False))
        self.assertIsNone(v.hash_confere)
        self.assertEqual(v.motivos, ['Sem arquivo .zip.sha256'])
        self.assertEqual(cc.situacao_inicial(v, False)[0], 'Rejeitada')
        self.assertEqual(cc.situacao_inicial(v, True),
                         ('NaoVerificada', 'Sem arquivo .zip.sha256'))

    def test_hash_zip_divergente(self):
        z = fabrica.nova_coleta(self.pasta)
        Path(str(z) + '.sha256').write_text('0' * 64 + f'  {z.name}\n', encoding='utf-8')
        v = cc.verificar_zip(z)
        self.assertIs(v.hash_confere, False)
        self.assertIn('Hash do ZIP diverge do .zip.sha256', v.motivos)

    def test_sha256_invalido_ou_outro_nome(self):
        z = fabrica.nova_coleta(self.pasta)
        h = cc.sha256_arquivo(z)
        Path(str(z) + '.sha256').write_text(f'{h}  outro.zip\n', encoding='utf-8')
        self.assertIs(cc.verificar_zip(z).hash_confere, False)
        Path(str(z) + '.sha256').write_text('lixo\n', encoding='utf-8')
        self.assertIs(cc.verificar_zip(z).hash_confere, False)

    def test_arquivo_interno_adulterado(self):
        def adulterar(a):
            a['csv/07_Software_Instalado.csv'] = b'outro conteudo'
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta, adulterar=adulterar))
        self.assertIn('Manifesto: Hash: csv/07_Software_Instalado.csv', v.motivos)
        self.assertIs(v.manifesto_confere, False)

    def test_extra_e_ausente(self):
        def adulterar(a):
            del a['Coleta.txt']
            a['novo.txt'] = b'x'
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta, adulterar=adulterar))
        self.assertIn('Manifesto: Ausente: Coleta.txt', v.motivos)
        self.assertIn('Manifesto: Extra: novo.txt', v.motivos)

    def test_sem_manifesto(self):
        def adulterar(a):
            del a['SHA256SUMS.txt']
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta, adulterar=adulterar))
        self.assertIn('Sem SHA256SUMS.txt', v.motivos)

    def test_manifesto_crlf_e_asterisco(self):
        def adulterar(a):
            linhas = []
            for k in sorted(k for k in a if k != 'SHA256SUMS.txt'):
                linhas.append(f'{hashlib.sha256(a[k]).hexdigest()} *{k}\r\n')
            a['SHA256SUMS.txt'] = ''.join(linhas).encode('utf-8')
        v = cc.verificar_zip(fabrica.nova_coleta(self.pasta, adulterar=adulterar))
        self.assertEqual(v.motivos, [])

    def test_entradas_de_diretorio_ignoradas(self):
        z = fabrica.nova_coleta(self.pasta)
        with zipfile.ZipFile(z, 'a') as zf:
            zf.writestr(f'{z.stem}/csv/', b'')
        v = cc.verificar_zip(z)
        self.assertEqual(v.erro_fatal, '')
        self.assertNotIn('Manifesto: Extra: csv/', v.motivos)
        self.assertFalse([m for m in v.motivos if m.startswith('Manifesto')])

    def _com_duplicada(self, segundo):
        import warnings
        z = fabrica.nova_coleta(self.pasta)
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            with zipfile.ZipFile(z, 'a') as zf:
                zf.writestr(f'{z.stem}{segundo}', b'copia oculta')
        return cc.verificar_zip(z)

    def test_entrada_duplicada_nome_exato(self):
        v = self._com_duplicada('/Coleta.txt')
        self.assertEqual(v.erro_fatal, 'ZIP com entrada duplicada: Coleta.txt')
        self.assertEqual(cc.situacao_inicial(v, True)[0], 'Rejeitada')

    def test_entrada_duplicada_barra_invertida(self):
        v = self._com_duplicada('\\Coleta.txt')
        self.assertEqual(v.erro_fatal, 'ZIP com entrada duplicada: Coleta.txt')

    def test_zip_ilegivel(self):
        z = self.pasta / 'InventarioForense_X_1.zip'
        z.write_bytes(b'nao e zip')
        v = cc.verificar_zip(z)
        self.assertTrue(v.erro_fatal.startswith('ZIP ilegivel'))
        self.assertEqual(cc.situacao_inicial(v, True)[0], 'Rejeitada')

    def test_duas_raizes(self):
        z = self.pasta / 'InventarioForense_Y_1.zip'
        with zipfile.ZipFile(z, 'w') as zf:
            zf.writestr('a/x', b'1')
            zf.writestr('b/y', b'2')
        v = cc.verificar_zip(z)
        self.assertEqual(v.erro_fatal, 'ZIP sem pasta raiz unica')
        self.assertEqual(cc.situacao_inicial(v, True),
                         ('Rejeitada', 'ZIP sem pasta raiz unica'))


if __name__ == '__main__':
    unittest.main()

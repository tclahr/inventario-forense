"""Fabrica de coletas InventarioForense_*.zip sinteticas para os testes."""
import csv
import hashlib
import io
import json
import re
import zipfile
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence

import ConsolidaColetas as cc


def _csv_bytes(colunas: Sequence[str], linhas: List[dict]) -> bytes:
    buf = io.StringIO(newline='')
    w = csv.writer(buf, delimiter=';', quotechar='"', quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    w.writerow(colunas)
    for l in linhas:
        w.writerow([cc.formatar_valor(l.get(c, '')) for c in colunas])
    return b'\xef\xbb\xbf' + buf.getvalue().encode('utf-8')


def nova_coleta(pasta: Path, hostname='PC1', id_equipamento='A' * 64, data='2026-11-12 10:00:00',
                modo='Padrao', admin='Sim', resumo: Optional[dict] = None,
                areas: Optional[Dict[str, List[dict]]] = None, omitir_areas: Iterable[str] = (),
                colunas_resumo: Optional[Sequence[str]] = None, separador='/', com_sha256=True,
                adulterar: Optional[Callable[[Dict[str, bytes]], None]] = None,
                extras: Optional[Dict[str, bytes]] = None, nome: Optional[str] = None) -> Path:
    pasta = Path(pasta)
    pasta.mkdir(parents=True, exist_ok=True)
    areas = areas or {}
    omitir = set(omitir_areas)
    if nome is None:
        nome = f"InventarioForense_{hostname}_{re.sub(r'[^0-9]', '', data)}.zip"
    raiz = nome[:-4] if nome.lower().endswith('.zip') else nome
    comuns = {'Hostname': hostname, 'IdEquipamento': id_equipamento, 'DataColeta': data}
    arquivos: Dict[str, bytes] = {}
    for num, area in cc.AREAS.items():
        if num in omitir:
            continue
        if num == '16' and modo != 'Completa' and num not in areas:
            continue
        if num == '01':
            linha = {'ExecutadoComoAdmin': admin, 'Modo': modo, 'AreasComFalha': '', 'AreasPuladas': ''}
            linha.update(resumo or {})
            linhas = [linha]
            cols = list(colunas_resumo) if colunas_resumo is not None else list(area.colunas)
        else:
            linhas = areas.get(num, [])
            cols = list(area.colunas)
        linhas = [dict(comuns, **l) for l in linhas]
        arquivos[f'csv/{area.arquivo}'] = _csv_bytes(list(cc.COLUNAS_COMUNS) + cols, linhas)
    arquivos['Coleta.txt'] = f'Coleta {hostname} {data}\r\n'.encode('utf-8')
    arquivos['Coleta.json'] = json.dumps({'Hostname': hostname, 'Modo': modo}).encode('utf-8')
    arquivos['Coleta.log'] = b'\xef\xbb\xbf[log] inicio\r\n'
    arquivos.update(extras or {})
    soma = ''.join(f'{hashlib.sha256(arquivos[k]).hexdigest()}  {k}\n' for k in sorted(arquivos))
    arquivos['SHA256SUMS.txt'] = soma.encode('utf-8')
    if adulterar:
        adulterar(arquivos)
    zpath = pasta / nome
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as zf:
        for k, v in arquivos.items():
            zf.writestr(f'{raiz}/{k}'.replace('/', separador), v)
    if com_sha256:
        h = hashlib.sha256(zpath.read_bytes()).hexdigest()
        Path(str(zpath) + '.sha256').write_text(f'{h}  {nome}\n', encoding='utf-8')
    return zpath

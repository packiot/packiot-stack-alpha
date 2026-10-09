-- t-i18n-ptbr-missing-desktop-keys — fill the 17 front4 (desktop) keys the pt-BR pack lacked.
--
-- Found by the Bispharma pt-BR demo rehearsal (2026-09-24): front4 renders
-- `language?.<key> || '<English>'`, so a missing key silently shows ENGLISH in a pt-BR
-- session (e.g. Mission Control "There aren't any runtimes"). Keys were found by diffing
-- every `language?.key || fallback` on the demo screens against the pt-BR desktop pack.
-- `id_order` inside deleted_po / delete_po is a LITERAL placeholder the code .replace()s —
-- kept verbatim. `taday` is the key's real (misspelled) name in front4.
-- ADD-ONLY: `new || existing` — any key that already exists keeps its current translation.
UPDATE config.language_packs
   SET language_pack_desktop = jsonb_build_object(
         'all_areas',            'Todas as áreas',
         'arent_runtime',        'Não há registros de execução',
         'change_over',          'Troca de produto',
         'deleted_po',           'OP id_order excluída!',
         'delete_po',            'Você está prestes a excluir a OP id_order. Tem certeza?',
         'filter_team',          'Filtrar equipe',
         'gross',                'Bruto',
         'no_sectors_available', 'Nenhum setor disponível',
         'no_teams_available',   'Nenhuma equipe disponível',
         'not_metered',          'Não medido',
         'not_metered_short',    '—',
         'oee',                  'OEE',
         'select_job_replace',   'Selecione a OP para substituir',
         'taday',                'Hoje',
         'team',                 'Equipe',
         'total_scrap',          'Refugo total',
         'unknown',              'Desconhecido'
       ) || language_pack_desktop
 WHERE language_tag = 'pt-BR';

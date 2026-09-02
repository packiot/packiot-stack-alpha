), downtime_codes AS (
         -- ADR-0039 R5 CONTRACT Step 1 (task #12): read the NEOPAC (ent 13) line
         -- downtime-reason category vocabulary from the normalized dimension
         -- (downtime_reason) + junction (equipment_downtime_reason) INSTEAD OF the
         -- inline reasons jsonb. reason_level=1 => categories; the category code
         -- (::int) is the "position"; label is the flattened en-US description.
         -- Same (position, description) output contract as the jsonb block in
         -- sap13_reasons_jsonb.sql, so every downstream CTE is untouched. Swapped
         -- in ONLY when SAP13_REASONS_FROM_DIM=true (default false => byte-identical
         -- jsonb path). See docs/adr/0039-reasons-dimension-contract-plan.md.
         SELECT DISTINCT r.code::integer AS "position",
            COALESCE(r.label, r.label_i18n->>'en-US') AS description
           FROM equipment_downtime_reason j
           JOIN downtime_reason r ON r.id = j.id_reason
           JOIN equipments e ON e.id_equipment = j.id_equipment
          WHERE e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
            AND j.active AND r.active AND r.reason_level = 1
          ORDER BY 1

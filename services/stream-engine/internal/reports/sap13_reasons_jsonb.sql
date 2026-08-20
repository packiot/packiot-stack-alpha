), top_level AS (
         SELECT id_equipment,jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE equipments.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)--708 --(TL205)
        ), category_level AS (
         SELECT 
         	id_equipment,
         	--jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'position'::text AS "position",
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code')::int as position
          FROM top_level
           order by 1,2          
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position"::integer AS "position",
            category_level.description
            --id_equipment
           FROM category_level
          ORDER BY 1--(category_level."position"::integer)  

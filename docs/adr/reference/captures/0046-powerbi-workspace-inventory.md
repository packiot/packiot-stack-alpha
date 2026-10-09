# Power BI workspace inventory — capture (READ-ONLY, 2026-08-10)

Workspace `635f5c34-4183-4211-831b-241fbf1ec3dc` (name `packiot40`), dedicated capacity `AF1A798C-7D8B-4E78-9595-482E1E680A8A` (Premium/PPU/Fabric — isOnDedicatedCapacity=True).
Enumerated via the back4 service principal (client-credentials) against the Power BI REST API.
75 reports (74 PowerBIReport + 1 PaginatedReport), 67 datasets, 0 dashboards.
pbix Export API works (capacity confirms it) — 17 priority reports exported + layout-parsed.

## Reports (id | name | datasetId | reportType | pages)

| id | name | pages |
|---|---|---|
| `768e4497-9aec-40e6-aa11-3ac1fd4a86ae` | 000_SESSIONS_PACKIOT_POSTGRESQL | Sessions |
| `3a47b0a6-6f30-4efc-be64-496be72828ab` | 00_CQ_LOGS_POWER_BI | CQ-Report |
| `65a11a26-8bfb-41c5-b9b1-c18e642976c7` | 00_test_report_A4 | Speed Montebello |
| `a662e67b-209d-4d73-97d4-00bca40011d2` | 01_CPACK_Sensors_Report | SENSORES CPACK |
| `9746cfa2-10d7-494f-8fc2-b3a9a2ee55a2` | 01_INCOPLAST_PACKIOT | Setup / Downtime / Downtime_Shift |
| `72d438d6-fe4f-4e3b-b69b-c50631ee9f46` | 01_SC_StopsReports | Downtime List / Lista de Paradas |
| `40252f93-8047-4c24-b498-f52744a609b3` | 02_Incoplast_Timeline2 | Incoplast |
| `30293fc0-5663-4d0a-8e4d-daa902a0a3e6` | 04_Production_Control_Bruno | Turno / POs / Caixas / Prensa_Etiquetas / Sensores |
| `9c885a96-1f4e-4456-950b-86ff3f24d12d` | 04_Relatorio_Francielle_DOWNTIME | Stops / MicroStops / Resumo MicroStops |
| `4ee99246-3950-4d06-b6de-9df1c0d31651` | 04_Relatorio_Francielle_Producao | Turno / Duplicate of Turno |
| `47c1dac1-4fe3-40d0-90c8-3c9dd88c6ea0` | 04_Relatorio_Francielle_Producao2 | Turno / Duplicate of Turno |
| `52440e4e-7aed-4a53-82cd-53778c073a06` | 05_Diameter_Product_Client_OPs | Geral / Cliente_FOs / Cliente_Referência / Mensal / Page 1 |
| `ed947e87-a543-483d-843f-cafc023d99e3` | 05_Tempo_Finalizar_OP | Page 1 |
| `d5ce26a7-1e45-492a-9d76-fb3e8c7f0018` | 06_12h_LEBANON_piot4_FTS | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `7579b6df-a14a-4e58-8bf3-bc7d7c2e09a2` | 06_12h_VIRGINIA_piot4_NEW_DOWNTIME | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `f604d004-77bc-4bd1-a2e0-872782a563a6` | 06_DATA_SYNC | Data Sync Analysis |
| `df2c79cb-4b53-4b38-9419-ae8065277ae6` | 06_FROM_AUG2023_HWK_ShiftReports | Shift Report |
| `db0172f0-34eb-44ae-9bc6-f6f9b51eb379` | 06_HARRISON_ShiftReport_PB_Dataset | Shift Report / Downtime / Downtime List / DT Sectors |
| `eba2e2c6-ed5f-40c2-9d7f-81fa9a508664` | 06_HAWKES_ShiftReport_PB_Dataset | Shift Report / Downtime / Downtime List / DT Sectors |
| `40f91c8e-5a31-4b6d-b60e-d498564ac58e` | 06_HWK_ShiftReport24h | Shift Report / Downtime / Downtime-List |
| `d2d67e75-4baf-4ca6-a6fe-c7c37443ae8d` | 06_HWK_ShiftReports | Shift_Report / Downtime / Downtime List / DT Sectors |
| `9f766223-d8bb-4e47-b358-8e1914fbaf9c` | 06_HWK_piot4_NEW_DOWNTIME | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List / Duplicate of JOBs |
| `9a762e91-7203-4388-8252-57183026b135` | 06_LEBANON_ShiftReport_PB_Dataset | Shift Report / Downtime / Downtime List / DT Sectors |
| `c411bf0a-45d5-409b-8d5e-f5998d434aaf` | 06_LEBANON_piot4_CANS_12h | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `7cfad958-2f6e-46cd-9518-4366b75273e3` | 06_LEBANON_piot4_CANS_8h | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `fcd4724b-3728-4614-b34f-332fe4cb9011` | 06_LEBANON_piot4_NEW_DOWNTIME | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `e18e202c-0ac0-499f-a8d3-08484dfb4b8c` | 06_MONTREAL_ShiftReport_PB_Dataset | Shift Report / Downtime / Downtime List |
| `d36353a9-e96c-45cf-914e-8deda79c18b9` | 06_MONTREAL_piot4_NEW_DOWNTIME | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `0f5fc3a7-c996-434e-afd8-d733490ff91e` | 06_Montebello_KENTUCKY_Shift_Report | Shift Report / Current Shift / JOBs / Report_Details / Shift Report 2 / LineStructure |
| `28865801-2876-417e-81bd-2960e9067049` | 06_Prod_Report_ALL_Sites | Prod. Report / Downtime / DT Sectors / Downtime List / JOBS |
| `adae5f0c-30d7-466f-ace8-2a783f3f8b99` | 06_SETUP_ANALYSIS | Setup Analysis / Details |
| `0abfa7bd-c721-46cc-aed1-4d120d275549` | 06_VIRGINIA_piot4_NEW_DOWNTIME | Current Shift / Shift Report / Downtime / Speed / JOBs / Report_Details / Downtime-List |
| `d6a0e032-0964-4a0f-b521-2b40f5dd4fd9` | 07_SAP_BigQuery | SAP_HU |
| `1d7174b7-6f55-4a22-b5ff-253b51c2b531` | 07_SAP_Postgres | Shift_Report |
| `37e68bb5-3e9e-4a2e-960b-c0748e56f477` | 10_GULF_CANS_OEE_main_report | OEE / Work Orders / Speed / Stops / Check_Resets / Speed_New |
| `d1f6d9e4-5cf3-4ae7-b96c-6fb5191ed41b` | 10_list_of_stops | List of Stops / Downtime-Analisys / Page 1 |
| `fc61c82e-e08e-4469-969b-b5b30c43f869` | 13_DEB_Sensors_Report | Sensors Report / Sensors Report-All Lines / Last_Minutes / Sensors_pro_Tag / Last_Minutes2 |
| `bdf024cd-460a-4dc0-b035-559bfff5a046` | 13_HU_Intranet_last31days | Prod. Neopac HU |
| `7869e8fb-534d-471a-b02c-92ace84ee8a4` | 13_Intranet_last31days | Prod. Neopac CH |
| `95f8303d-fe7e-4476-8bcf-8ef512781697` | 13_Neopac_DT_2021 | Ausfall-Analyse / Liste der Ausfällen / Ausfall-General |
| `9293d691-39e2-4092-a586-97801eb666a4` | 13_Neopac_DT_Since_Jan2022 | Ausfall-Analyse / Liste der Ausfällen / Ausfall-General |
| `5687d7a2-b135-4ed9-b654-c96cda923da2` | 13_OBD_MOBILE | MOBILE REPORT / MR2 |
| `31234eb7-fd2a-42bf-995c-65dbda29e0d5` | 13_OBD_MOBILE_direct_query | Page 1 |
| `b735cd78-a9cb-40b8-96c6-ef3d4e0204e1` | 13_OBD_Sensors_Report | Sensors Report / Sensors Report-All Lines / Last_Minutes / Sensors_pro_Tag / Last_Minutes2 / SS Gross x Net |
| `89b0eb65-c5ae-4835-815b-51cc7cff5969` | 13_Production_per_Team | Prod. per Team |
| `ebc3a761-ab12-4d1c-831a-5fb5bc011764` | 13_SAP_CH_Postgres_API | Shift_Report / Infos |
| `2bfad1b6-e34e-4153-a688-90d15f90cc49` | 13_WIL_Sensors_Report | Sensors Report / Sensors Report-All Lines / Last_Minutes / Sensors_pro_Tag / Last_Minutes2 |
| `f24ef4c7-1695-4721-89e4-ce7ebb8f17a3` | 13_comparison_piot1_piot4 | piot1 x piot4 |
| `3995512f-5aef-43d7-9ac7-42a44577f684` | 33_Incoplast_Siegwerk_Frank | Test |
| `c5ac69a0-bf0c-4bd5-be2d-ac1f127708d1` | 33_Job_Details_10days | Velocidade Impressão / Detalhes OPs |
| `ee56ad66-c0e3-4165-bc42-0db1d6f65a37` | 33_List_Stops_Production_Jobs10days | Detalhes OPs |
| `989cc162-920b-4106-b447-7fd92397623d` | 35_Job_Details_10days_USE CASE | Relatório Rotomec 2 / ShiftChange |
| `df396d0d-9552-43e0-8917-26c468bfcc18` | 36-ALBEA_OEE_Stops_Production | OEE / Stops / List of Stops / Shifts |
| `9c02bf5e-e817-4fe8-9471-f95c8de342ae` | 37_DowntimeAnalysis | Lista / Categorias / Microparadas / SubCategorias |
| `6c550f80-a70b-4d19-b5d7-234b17f250bd` | 37_Relatorio_de_Bobinas | Bobinas / Bobinas_old / DiametroSpeed |
| `1e7a149a-2f36-4be1-9ed5-386b3135e44d` | 37_Relatorio_de_Turno | ProdTAGs / Refugo / Taxa_Refugo / Base tooltip |
| `4a6aaf6f-3b12-448e-8b6e-3023e2fe606d` | 37_Suzano_OEE_main_report2 | OEE / OEE_week / OEE_a_week / OEE_q_week / OEE_p_week / OEE_month / OEE_a_month / OEE_q_month / OEE_p_month / Net_week / OEE_day / FrontPage |
| `7848e956-c327-488c-846c-ec5af7ba1f14` | 37_Suzano_SPEED_REWINDING_3days | Speed_L1 / Speed_L2 |
| `ec52d8ab-efc1-4036-ad9b-3d9131495624` | 37_list_of_tags | Lista de TAGs |
| `17810993-85a4-4c9c-878e-a07b12d47078` | CPPowerBI | Page 1 / Page 2 / Duplicate of Page 2 / Page 3 / Page 4 / Page 5 / Bought Out / Raw Material / Outsource Pending |
| `8b8c0162-f214-4086-8b34-bc6fd904b21e` | Dashboard Usage Metrics Report | Usage Report |
| `40febf40-e015-4f83-96e0-ff1bc956a320` | Edu_10_GULF_CANS_OEE_main_report | Speed_New |
| `51ebc39a-edb5-427a-a4a0-120cad166c93` | Embedding_LoadingTest | Página 1 |
| `f12ddaea-6e98-4ca4-aa6b-4086b694148a` | Incoplast_Siegwerk_Speed_Analysis | Speed_Analysis / WIEDERHOLUNGEN / Auftragsliste |
| `8fe39374-ea39-48d5-bafe-3f4a461552e5` | Prod30 | Page 1 |
| `22d25d60-164d-4f80-88f9-60e0dd8371c1` | Production | {'error': 401} |
| `1dcd72dd-7f5d-4e69-a40c-9e83c766e5c1` | Production Sheet | Page 1 / Duplicate of Page 1 / Supply Chain / Supply Chain Demand / Duplicate of Supply Chain Demand / Operation Gantt / General View / Page 2 / Duplicate of Page 2 |
| `f001bedb-e597-487e-8f23-8ce7fc071d16` | Report Usage Metrics Report | Usage Report |
| `981e046f-4849-4d15-9c57-720adb096e52` | SupplyChain | Page 1 / Page 2 |
| `1ed4f815-6780-4213-af49-87c620517b59` | SupplyChain2 | Page 1 / Duplicate of Page 1 / Supply Chain / Supply Chain Demand / Duplicate of Supply Chain Demand / Operation Gantt / General View / Page 2 / Duplicate of Page 2 |
| `c463708e-8502-4127-8d33-671f0b5cb58f` | Usage Metrics Report | Report usage / Report performance / Report list / FAQ |
| `426be458-abdd-449f-af72-398f4cf35946` | areas teste db | Page 1 |
| `bc910dcb-402d-4c6d-ba1c-359dd033f479` | graphs_CP | Page 1 / Page 2 / Page 3 |
| `e55093e8-4708-4eb2-81a7-ce7345a26c66` | piot4_CQ_overlap_subcats | CQ_piot4_DT&DT_overlap |
| `90794861-55de-4f17-a4a4-3be27407113c` | teste_paginated | None |

## Datasources for priority datasets (all DirectQuery/Import over LEGACY prod Postgres)

- **01_INCOPLAST_PACKIOT** (dataset `904ce680-b983-45fb-928a-dc29e6e86ec2`): [{"datasourceType": "PostgreSql", "server": "34.122.14.155", "database": "packiot40", "url": null, "path": null}]
- **01_CPACK_Sensors_Report** (dataset `8705e4cc-bd98-4314-9955-9b94c60e83b2`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **01_SC_StopsReports** (dataset `15580032-69cf-4f11-8d4c-78968868b616`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **02_Incoplast_Timeline2** (dataset `89366508-550e-417c-8449-f30a57034977`): [{"datasourceType": "File", "server": null, "database": null, "url": null, "path": "c:\\users\\eduar\\documents\\packiot\\000-siegwerk\\dbeaver\\incoplast\\33_test_powerbi3_full_30dias.xlsx"}, {"datasourceType": "File", "server": null, "database": null, "url": null, "path": "c:\\users\\eduar\\documents\\packiot\\000-siegwerk\\dbeaver\\incoplast\\33_test_powerbi.xlsx"}]
- **13_Neopac_DT_Since_Jan2022** (dataset `7abd5fe9-f4e8-478e-ab1f-34a9cf643c31`): [{"datasourceType": "PostgreSql", "server": "35.225.168.228", "database": "packiot", "url": null, "path": null}, {"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **13_OBD_MOBILE_direct_query** (dataset `92fc5932-9c58-490f-abe9-429243ce71c8`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **06_Montebello_KENTUCKY_Shift_Report** (dataset `8bc8ba36-cc3d-48e2-8404-b6311b121598`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **36-ALBEA_OEE_Stops_Production** (dataset `bfe9df8a-33c3-46a9-bab7-bd7ae7cc3983`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **37_Suzano_OEE_main_report2** (dataset `e3812a2a-fdd4-42d8-a4bc-00678cb338d1`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **10_GULF_CANS_OEE_main_report** (dataset `b91db53f-7692-4b6e-9aa9-bbdcfdb8f7c6`): [{"datasourceType": "PostgreSql", "server": "18.220.223.110", "database": "packiot40", "url": null, "path": null}]
- **33_Incoplast_Siegwerk_Frank** (dataset `804f1592-efdd-4df0-abec-b2787cb47954`): [{"datasourceType": "File", "server": null, "database": null, "url": null, "path": "c:\\users\\eduar\\documents\\packiot\\000-siegwerk\\dbeaver\\incoplast\\33_test_powerbi3_full_30dias.xlsx"}]
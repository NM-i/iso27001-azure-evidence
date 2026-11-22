# ISO/IEC 27001:2022 techninių įrodymų rinkimas Azure aplinkoje

Kursinio darbo prototipas (Kauno kolegija, Kibernetinės sistemos ir sauga). Kas 5 min. renka 11 A priedo technologinių kontrolių įrodymus per „Azure Resource Graph“, įvertina juos, išsaugo nekeičiamoje „Blob Storage“ saugykloje su SHA-256 maiša ir rodo būklę „Azure Monitor Workbooks“ skydelyje.

> Saugumo bandymai ir nukrypimų scenarijai skirti tik **savo** prenumeratai ir išteklių grupėms `rg-iso-proto`, `rg-iso-target`.

## Struktūra
| Kelias | Paskirtis | R-kodai |
| --- | --- | --- |
| `src/catalog.json` | Kontrolių katalogas (11 kontrolių, KQL kriterijai) | R1 |
| `src/function_app.py`, `src/collector.py` | Laikmatis ir rinkimo ciklas | R4, R7, R12, R13 |
| `src/evidence.py` | Įrašas, maiša, įrašymas | R2, R3 |
| `src/ingest.py` | Žurnalas „Log Analytics“ | R5, R8 |
| `infra/main.bicep`, `infra/modules/subscription.bicep` | Prototipo ištekliai, rolės, įspėjimas, biudžetas | R3, R6, R9, R11, R14 |
| `infra/target.bicep` | Stebimi testiniai ištekliai | R7 |
| `workbook/controls.workbook.json` | Skydelis | R5 |
| `deploy.sh` | Diegimas viena komanda | R15 |
| `tests/drift/drift.sh` | Nukrypimai D01–D11 | R7, K3 |
| `tests/unit/` | Vietiniai vienetų testai | R1, R2, R7, R10 |
| `tools/` | Patikros: maiša, schema, konfigūracija, nekeičiamumas, K3, „Defender“ | R2, R3, R9–R11, K3 |
| `tools/runner/` | Automatinis testų vykdytojas (ACI) | Testavimas: R1–R5, R7–R10, R12–R14, K1–K3 |
| `kql/metrics.kql` | Rezultatų užklausos | R4, R8, R12, R13, K1, K3 |
| `docs/ADMIN.md`, `docs/USER.md` | Administratoriaus ir naudotojo instrukcijos | — |

## Greitas paleidimas (automatinis testavimas)
Azure Cloud Shell (Bash), įkėlus ir išskleidus ZIP:
```bash
cd iso27001-azure-evidence
bash setup.sh vardas.pavarde@stud.kauko.lt    # teikėjai, testai, GitHub (pasirinktinai), diegimas, vykdytojo paleidimas
tools/runner/status.sh                         # būsena bet kada (apie svarbius įvykius ateina el. laiškai)
tools/runner/fetch_results.sh                  # kai gausite laišką DONE
tools/runner/cleanup.sh                        # užbaigimas
```
`setup.sh` galima paleisti pakartotinai: atlikti etapai praleidžiami. El. laiškai siunčiami, kai vykdytojas pradeda darbą, baigia etapą, sustoja su klaida arba baigia; jei 3 val. negaunama jokios žinios, kas valandą siunčiamas priminimas.

Vykdytojas (`tools/runner/`) veikia „Azure Container Instances“ konteineryje su vartotojo priskirta valdomąja tapatybe ir atlieka testavimo plano 1–5 etapus: TF-01, TF-03, TS-01–TS-03, „Defender CSPM“ įjungimą ir išjungimą, nukrypimus D01–D11, K3, TF-04 ir TF-10 matavimus, 24 val. veikimą (TF-06, TF-08, TF-09), TF-02, TF-07, K1 ir prototipo K2. Rankiniu būdu lieka rankinio rinkimo K2, sąnaudų ekrano kopija (TF-12), skydelio ekrano kopija ir 3 priedo sutikrinimas.
Išsamiai: [docs/ADMIN.md](docs/ADMIN.md). Naudojimas ir įrodymų patikra: [docs/USER.md](docs/USER.md).

## Vietiniai testai (be Azure)
```bash
pip install -r src/requirements.txt pytest
python -m pytest tests/unit
```

## Technologijos
„Azure Functions“ („Flex Consumption“, „Python“ 3.11), „Azure Resource Graph“, „Azure Blob Storage“ su laiku pagrįsta nekeičiamumo politika, „Log Analytics“ ir „Logs Ingestion API“, „Azure Monitor Workbooks“ ir įspėjimai, „Bicep“. Prieiga – tik valdomąja tapatybe, be raktų.

## Licencija
Mokomasis darbas. Kodas parengtas naudojant DI įrankį „Claude“ (Anthropic). Prieš pateikiant darbą autorius kiekvieną komponentą paleidžia savo prenumeratoje ir patikrina.

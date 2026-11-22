# Naudotojo instrukcija

Skirta atitikties specialistui ir auditoriui.

## 1. Kontrolių būklė (R5)
Portalas → „Monitor“ → „Workbooks“ → **„ISO/IEC 27001 kontrolių būklė“**.
- Viršutinė lentelė: kiekviena kontrolė pagal A priedo numerį, būklė, neatitinkančių išteklių skaičius ir paskutinio įrodymo laikas. Duomenys – paskutinio sėkmingo ciklo.
- Apatinė lentelė: paskutinių 24 val. rinkimo ciklai, jų trukmė ir klaidos.

## 2. Įspėjimai (R14)
Kai kontrolė tampa „neatitinka“, į nurodytą el. paštą siunčiamas „Azure Monitor“ įspėjimas „ISO 27001 evidence: control not compliant“ su kontrolės numeriu. Atkūrus konfigūraciją įspėjimas uždaromas automatiškai.

## 3. Įrodymų rinkinio gavimas ir patikra (R10)
Reikia „Storage Blob Data Reader“ rolės konteineriui `evidence` (diegimo metu suteikiama diegėjui).
```bash
python3 tools/verify_evidence.py --account <stevid...> --control A.8.24 --date 2026-12-02 --out build/A.8.24
python3 tools/verify_evidence.py --tamper-test build/A.8.24
```
Pirmoji komanda atsisiunčia vienos kontrolės vienos dienos įrašus ir parodo, kiek maišų sutampa. Pridėjus `--la-export la.json` (užklausa `R10_LA_HASHES`) maiša papildomai lyginama su žurnalo kopija. Antroji komanda pakeičia vieno įrašo kopiją ir parodo, kad pakeitimas aptinkamas.

## 4. Įrodymo įrašo struktūra (R2)
| Laukas | Reikšmė |
| --- | --- |
| schemaVersion | Įrašo schemos versija |
| recordId | Unikalus įrašo ID (UUID) |
| cycleId | Rinkimo ciklo ID |
| controlId, controlName | A priedo kontrolė |
| collectedAt | Surinkimo laikas, UTC |
| source | Duomenų šaltinis („Azure Resource Graph“ lentelė) |
| queryHash | KQL užklausos SHA-256 |
| resourceId | Azure išteklio ID |
| result | „atitinka“ arba „neatitinka“ |
| observed | Įvertintos išteklio savybės |
| sha256 | Įrašo maiša (kanoninis JSON be šio lauko) |

Kelias saugykloje: `evidence/{kontrolė}/{metai}/{mėnuo}/{diena}/{ciklo ID}_{išteklio maiša}.json`.

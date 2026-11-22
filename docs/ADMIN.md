# Diegimo ir administravimo instrukcija

Prototipas diegiamas tik į **savo** „Azure for Students“ prenumeratą. Visi bandymai atliekami tik grupėse `rg-iso-proto` ir `rg-iso-target`.

## 1. Reikalavimai
- Azure CLI 2.60 ar naujesnis, prisijungta `az login`, prenumeratos „Owner“ rolė.
- `az extension add -n resource-graph` (reikia `tools/defender_poll.sh`).
- `zip`, `python3` ≥ 3.10; `pip install -r src/requirements.txt` (patikros įrankiams).

## 2. Diegimas (R15)
```bash
./deploy.sh vardas.pavarde@stud.kauko.lt
```
Scenarijus sukuria abi išteklių grupes, įdiegia `infra/target.bicep`, `infra/main.bicep` ir funkcijos kodą, o pabaigoje išveda trukmę („R15 duration“). Šią eilutę užfiksuokite TF-11 rezultatui.

Pirmieji 1–3 ciklai gali nepavykti, kol įsigalioja rolių priskyrimai; tai matyti lentelėje `EvidenceCycle_CL` (būsena `Failed`).

## 2a. Automatinis testavimas (rekomenduojama)
Paprasčiausia: `bash setup.sh <el. paštas>` atlieka 2 skyriaus diegimą, palaukia pirmo sėkmingo ciklo ir pats paleidžia `tools/runner/start.sh`. Kodo įkėlimas į GitHub: `tools/github_push.sh` (siūloma ir `setup.sh` metu).

Rankiniu būdu: po diegimo palaukite 15 min. ir paleiskite `tools/runner/start.sh`. Jis patikrina, ar prototipas veikia, užrakina nekeičiamumo politiką (paprašys įvesti LOCK), atlieka TS-04–TS-08 jūsų tapatybe, sukuria grupę `rg-iso-runner` (saugykla be raktų, vartotojo priskirta tapatybė, konteineris) ir paleidžia vykdytoją.

Vykdytojo tapatybės rolės: „Owner“ tik `rg-iso-target` grupei (nukrypimai, įskaitant D01), „Reader“ ir „Security Admin“ prenumeratai („Azure Resource Graph“, žurnalai, įspėjimai, „Defender CSPM“ įjungimas ir išjungimas), „Storage Blob Data Contributor“ įrodymų konteineriui (TS-01–TS-03) ir vykdytojo saugyklai.

Eiga (~2 paros): bazinė patikra → TS-01–TS-03 → „Defender CSPM“ įjungimas ir laukimas iki 12 val. → D01–D11 (~13 val.) → K3, TF-10 → 24 val. veikimas → TF-02, TF-07, K1, K2 → „Defender CSPM“ išjungimas. Po kiekvieno žingsnio rezultatai išsaugomi vykdytojo saugykloje.

- El. laiškai (veiksmų grupė `ag-evidence`): STARTED, STAGE, FAILED, DONE; jei 3 val. nėra žinių – priminimas kas valandą („no heartbeat“). Įvykiai kaupiami lentelėje `RunnerStatus_CL`.
- Būsena: `tools/runner/status.sh`. Jei rodoma FAILED, peržiūrėkite `build/runner.log` (`tools/runner/fetch_results.sh` atsisiunčia paskutinę kopiją), ištaisykite priežastį ir paleiskite `tools/runner/start.sh --resume` – darbas tęsiamas nuo nebaigto žingsnio.
- **Jei vykdytojas sustoja su klaida, „Defender CSPM“ lieka įjungtas.** `tools/runner/cleanup.sh` jį išjungia bet kuriuo atveju.
- Rezultatai: `tools/runner/fetch_results.sh` → `results_<data>.zip`.

Toliau aprašyti 3–4 skyriai reikalingi tik vykdant testus rankiniu būdu.

## 3. Prieš eksperimentą
1. **Užrakinkite nekeičiamumo politiką (R3, T7):** `tools/lock_immutability.sh`. **Negrįžtama:** laiko sutrumpinti nebegalima, o saugyklos paskyros neištrinsite, kol galioja įrašai (7 d.).
2. **Įjunkite „Defender CSPM“ (T9)** prenumeratoje: portalas → „Microsoft Defender for Cloud“ → „Environment settings“ → prenumerata → „Defender CSPM“ → On. Kalendoriuje pasižymėkite išjungimo datą prieš baigiantis 30 d. bandomajam laikotarpiui.
3. Patikrinkite konfigūraciją: `tools/config_checks.sh` (TS-04–TS-08).

## 4. Nukrypimų eksperimentas (R7, K3)
Kiekvienam ID nuo D01 iki D11:
```bash
tests/drift/drift.sh apply D02
tools/defender_poll.sh D02 > build/defender_D02.csv     # trunka 1 val.
tests/drift/drift.sh restore D02
sleep 600
```
Po eksperimento eksportuokite `K3_EXPORT` užklausą iš `kql/metrics.kql` į `build/results.json` ir paleiskite:
```bash
python3 tools/compute_k3.py tests/drift/t0.csv build/results.json
```

## 5. K2 matavimas
Prototipas (3 kartus, pateikiama mediana):
1. `EvidenceCycle_CL | order by StartTime desc | take 1` – paimkite naujausio sėkmingo ciklo `CycleId`.
2. Iškart po ciklo pabaigos:
```bash
python3 tools/verify_evidence.py --account <stevid...> --cycle <CycleId> --out build/k2_run1
```
3. Užrašykite eilutę „K2 (nuo ciklo pradžios iki eksporto pabaigos)“ ir patikrinkite, kad „Kontrolių rinkinyje“ = 11.

Rankinis rinkimas (3 kartus): įjunkite chronometrą ir pagal 2.10 lentelę surinkite visų 11 kontrolių įrodymus Azure CLI arba portale į aplanką; sustabdykite, kai išsaugotas paskutinis.

## 6. Stebėsena ir sąnaudos (R6)
- Biudžetas `budget-iso-evidence`: 20 USD, įspėjimai ties 5, 10 ir 20 USD. Biudžeto įspėjimai gali vėluoti iki paros.
- Sąnaudos: portalas → „Cost Management“ → „Cost analysis“, filtras pagal abi išteklių grupes.

## 7. Aplinkos pašalinimas
```bash
az group delete -n rg-iso-target --yes
# rg-iso-proto galima ištrinti tik pasibaigus nekeičiamumo laikui (7 d. nuo paskutinio įrašo):
az functionapp stop -g rg-iso-proto -n <funkcija>     # sustabdo naujų įrašų kūrimą
az group delete -n rg-iso-proto --yes                  # po 7 d.
```
Išjunkite „Defender CSPM“, jei jis įjungtas.

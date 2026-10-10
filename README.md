# Glucklich for iPhone and Apple Watch

Glucklich is a native SwiftUI research prototype for Rutgers Health Hack Challenge 3. It predicts a participant's post-meal glucose trajectory using a model fit to their preceding seven days. This package contains the iOS app, a watchOS companion, an offline Python training pipeline, and deterministic demo data.

## Run on your teammate's Mac

1. Unzip the entire folder. Open **Glucklich.xcodeproj** in **Xcode 16 or later**. No CocoaPods, Expo, API keys or XcodeGen are needed.
2. Select the **Glucklich** scheme and an iPhone Simulator with iOS 17 or later. Press **Run**. The bundled demo works without Health permissions or external data.
3. For real devices, enable Developer Mode on the iPhone (and Watch when prompted). In **Signing & Capabilities**, select your team for **both Glucklich and GlucklichWatch**. Use unique bundle identifiers if your team needs them. The Watch identifier must be the phone identifier plus `.watchkitapp`; also update `WKCompanionAppBundleIdentifier` in `Watch/Info.plist`.
4. Select the connected iPhone and Run. HealthKit is already declared in both targets. Device signing must support the HealthKit entitlement; Apple Developer Program membership may be needed for your signing/distribution route. Check Xcode's signing message before relying on a free Personal Team.
5. Select **GlucklichWatch** and a paired Apple Watch running watchOS 10 or later. Run once to install the companion.
6. On the iPhone, open **Connect → Connect Apple Health** and allow the available data types. On Watch, start a walking session and actually walk. Accept Watch Health permissions. Keep Glucklich open on iPhone for live heart rate. End the walk to save the session.

The bundled app icon, entitlements, property lists, schemes, Watch embedding and sample participant package are included. Simulator cannot verify real Health/Watch sensors.

## A two-minute demo

1. Open **Day 8**. Select a meal. Tap **Predict held-out meal**.
2. Point out 30/60/90/120-minute forecasts, peak, time to peak, positive iAUC, and model contributions.
3. Tap **Reveal observed response**. The orange line and trajectory MAE appear. This is generated demo data until you import a real participant package.
4. Open **Connect**, connect Health and start a walking session on the Watch. On **Forecast**, show the actual Watch heart rate, source and sample age.
5. Log a meal with a photo and confirmed macros. The forecast also appears on the Watch. With no CGM hardware, leave **Use demo glucose** enabled; this is visibly labeled.

## What is implemented

- Native iPhone app and paired Watch companion.
- HealthKit reads recent glucose, heart rate and prior-hour active energy when available.
- Watch live heart-rate transport during an actual user-started walking workout. Workout saved to Health when ended.
- Camera and system photo picker; local meal-photo storage; confirmed macro entry and illustrative presets.
- Offline participant-specific inference for every 5 minutes over two hours, with derived challenge metrics.
- Day 8 forecast versus observed view, with outcomes held out of training.
- Participant JSON import, local forecasts, restored model, deletion of local data.
- Real CSV/ZIP/Parquet ingestion through the included Python pipeline. No raw dataset is loaded into the phone.

## Train on your provided datasets

Download your organizer's CGMacros ZIP or MetaboNet Parquet to your computer. The SharePoint files themselves are not embedded here. Read **docs/DATA.md** for source mapping, timezone, cohort and missing-data details.

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r Pipeline/requirements.txt

# Inspect the ZIP names first.
python3 Pipeline/train.py /path/to/cgmacros.zip --format cgmacros --inspect
python3 Pipeline/train.py /path/to/cgmacros.zip --format cgmacros --participant 001 --timezone America/Los_Angeles --output participant.json

# Choose a source and participant from the Parquet schema/your data dictionary.
python3 Pipeline/train.py /path/to/metabonet.parquet --format metabonet --inspect
python3 Pipeline/train.py /path/to/metabonet.parquet --format metabonet --participant YOUR_ID --source-file YOUR_SOURCE --timezone UTC --output participant.json
```

Use the actual timezone documented for your release, rather than assuming the example timezone is correct. Optionally choose a different local eight-day window with `--start-date YYYY-MM-DD`. Copy the exported `participant.json` to the iPhone using AirDrop or Files. In Glucklich, choose **My model → Import participant JSON**. The file beside it, `participant.metrics.json`, contains validation and Day 8 metrics.

Windows teammates can run the same Python pipeline with Python 3.11+: activate with `.venv\Scripts\activate` and run the `python` equivalent of those commands. Only native iOS/Watch compilation needs the Mac.

## Model and honest limits

The baseline is 24 person-specific ridge regressions predicting change from pre-meal glucose. Training uses only Days 1–7; Day 7 validation uses a separate fit to Days 1–6, then final coefficients are fit to all seven days. Features are scaled using training data only, with training median imputation and explicit missingness indicators. Actual recorded bolus units are a context feature; no medication dose is inferred or suggested.

This is a transparent starting model, not a clinically validated glucose predictor. The shaded spread comes from Day 7 absolute errors with a conservative floor; it has no validated probability coverage. No fabricated confidence percentage is displayed. Contributions describe the fitted model's associations relative to average inputs, not causal effects of walking or medication. Day 8 labels are stored for evaluation and reveal, never used in fitting.

Photos do not automatically produce nutrition in this version. Other medication classes, intervention simulation, automatic adaptation from newly observed meals and watch-side glucose monitoring are not implemented. Retaining photo paths from CGMacros is supported in the exporter; dataset photos are not copied into the iPhone package. Refit/export after new labeled data to update a model.

Imported public-dataset participants and the Watch wearer can be different people. A live Watch demonstration with someone else's participant model does not establish that model's accuracy for the wearer. Use a model trained on the wearer's own records for actual personalization. An Apple Watch alone supplies no CGM glucose, and Health sync is not guaranteed to be immediate.

## Checks

```bash
python3 -m unittest discover -s Tests -p 'test_*.py' -v
bash scripts/check_on_mac.sh
```

The Python checks cover chronological leakage, feature cutoffs, missing modalities, invalid data, ZIP selection and Parquet identity filtering. The Mac script compares Swift inference with Python values, checks contributions/schema failure paths, and builds both Apple targets for Simulator.

**Build status:** Python tests and Swift syntax/project structure checks were run in the creation environment. Xcode, Swift compiler, Simulator, signing and actual Watch hardware were not available there; the Mac script and device checks must run on your teammate's Mac before the demo. Read **docs/VERIFICATION.md**.

## Files

- `Shared/ForecastModel.swift`: portable model schema and inference.
- `iOS/`: SwiftUI screens, HealthKit, WatchConnectivity and local storage.
- `Watch/`: single-target Watch app and walking session.
- `Pipeline/`: participant ingestion and training.
- `Resources/demo_participant.json`: generated sample model and Day 8 cases.
- `Tests/`: Python checks and Mac inference check.
- `scripts/generate_project.py`: optional project regeneration; needs Pillow, separate from runtime dependencies.

Data references and citations are in **docs/DATA.md**. The shipped demo CSV and JSON are entirely generated; no public participant records or meal photographs are redistributed in this package.

# Dataset import and training contract

Glucklich accepts a compact JSON model on iPhone. The Python pipeline processes large source files on a computer. The two organizer datasets are supported through explicit adapters, not a promise that arbitrary unknown file formats can be interpreted without a mapping.

## CGMacros

The adapter reads one `CGMacros-00X.csv` inside a ZIP or an extracted directory. It uses the documented `Timestamp`, `Dexcom GL`, `HR`, `Calories (Activity)`, `Carbs`, `Protein`, `Fat`, `Fiber`, `Meal Type`, and optional `Image Path`. Choose `--glucose-column 'Libre GL'` explicitly to use Libre instead. The two sensors are not mixed by silently filling gaps from the other sensor.

The published dictionary describes activity calories as calories for the last minute; these are summed over the prior hour. Macros describe the consumed meal, so the adapter does not apply `Amount Consumed` a second time. Inspect your organizer release if it differs from the public dictionary. Images are retained as metadata paths. They are not used to infer macro values and are not uploaded or redistributed.

CGMacros has healthy, prediabetic and type 2 diabetes participants. MetaboNet focuses on type 1 diabetes. This pipeline fits participants separately; it does not pool these populations or claim interchangeable physiology.

## MetaboNet

The adapter projects `id`, `source_file`, `date`, `CGM`, `carbs`, `heartrate`, `bolus`, and `meal_label` when present. Reading uses Arrow filters, avoiding loading the entire Parquet release into RAM. Supply both the participant and source when IDs repeat across sources. Source values must match the Parquet values exactly. All timestamps for the selected identity are retained for the chosen window.

Protein, fat, fiber and activity energy are unavailable in the standard mapping and remain missing. `calories_burned` is not mapped automatically because interval/cumulative semantics vary across source studies. `bolus` is the recorded delivered insulin in a time bin and is summed over two hours. If your release encodes a rate or forward-filled value instead of event/bin quantity, normalize it first rather than treating it as a dose. Other medication classes and basal-rate dynamics are not represented by this baseline model.

No event is invented when there is no meal record. If there are not enough recorded meals and valid CGM windows over seven days, the trainer fails with an explanation. Choose a different participant or date window. More source records do not compensate for missing labels or missing meal data.

## Normalized CSV

Required columns: `timestamp`, `glucose`, `carbs`. Optional: `protein`, `fat`, `fiber`, `heart_rate`, `activity_kcal`, `bolus`, `meal_name`, `photo_path`, `participant_id`. One participant per file.

| Field | Unit and meaning |
| --- | --- |
| timestamp | ISO timestamp; timezone-aware preferred |
| glucose | CGM mg/dL; blank when missing |
| carbs, protein, fat, fiber | grams at the meal event, blank on non-meal rows |
| heart_rate | bpm at that timestamp |
| activity_kcal | interval energy, not a running cumulative counter |
| bolus | recorded delivered units for that interval/event, not a rate |
| meal_name | optional event name |
| photo_path | optional relative path; preserved as metadata |

Activity logs, Fitbit exports and Apple Health exports can be converted to this schema. Integrate separate streams by timestamp using only data known before the forecast. Convert mmol/L glucose to mg/dL before import; the script never guesses units. Convert cumulative energy counters to per-interval increments before import.

Use `--timezone` to interpret naive timestamps and define local time-of-day features. Dates shifted for privacy must remain aligned across modalities. UTC is the default, not a claim about the source timezone. Ambiguous/nonexistent DST timestamps fail explicitly. Day 1 starts at the earliest local date or supplied `--start-date`; Day 8 is seven local calendar dates later.

## Leakage and missingness

Features use readings at or before meal time. Baseline is the latest CGM reading no more than 15 minutes old. Trend uses earlier CGM over 30 minutes; heart rate comes from the last 15 minutes. Activity uses interval kcal over one hour; prior carbs and bolus use two hours. All features are captured before any post-meal outcome is read.

The 24 targets are glucose values at 5, 10, …, 120 minutes, minus pre-meal baseline. Outcome interpolation needs valid bracketing CGM with no gap over 15 minutes. It is used only for labeled outcomes. The input baseline is never interpolated using future CGM. Missing target windows are excluded from training, not fabricated.

Meals with another meal inside the next two hours are excluded to avoid attributing combined responses to one meal. Training windows crossing a local midnight are excluded. This prevents Day 8 outcomes from entering Day 7 training and Day 7 outcomes from entering Day 6 validation. Seven local days each require at least one eligible meal; at least eight training meals are required overall.

Features absent from a source remain missing. Training medians are computed using only fitting days and missingness flags are appended. A modality absent throughout fitting gets neutral zero imputation and cannot acquire a learned effect. The app warns when inputs are missing or outside fitting ranges. Bands widen heuristically outside these ranges, without claiming calibrated uncertainty.

Ridge penalty is fixed at 10; no hyperparameters are tuned on Day 8. Day 7 errors are used to describe interval spread, with minimum width 10 mg/dL. When validation is unavailable the fallback width is 25 mg/dL. These widths are engineering safeguards, not clinical error bounds. iAUC is trapezoidal integration of positive excursions above baseline in mg·h/dL. Time-to-peak is on the 5-minute grid within two hours.

## References

- Organizer challenge document: *Predict My Glucose Response: Building a Personalized Metabolic Response Function*, supplied in this conversation.
- CGMacros paper: Das A, Kerr D, Glantz N, et al. *CGMacros: a pilot scientific dataset for personalized nutrition and diet monitoring*. Scientific Data 12, 1557 (2025). https://doi.org/10.1038/s41597-025-05851-7
- Public CGMacros data and dictionary: https://www.physionet.org/content/cgmacros/1.0.0/ and https://www.physionet.org/content/cgmacros/1.0.0/DataDictionary_CGMacros-00X.csv
- MetaboNet: Wolff MK, Calhoun P, Aiello EM, Qin Y, Royston SF. *MetaboNet: The Largest Publicly Available Consolidated Data Set for Type 1 Diabetes Management*. Journal of Diabetes Science and Technology (2026). doi:10.1177/19322968261441637. https://metabo-net.org/data-dictionary and https://metabo-net.org/data
- HealthKit live collection: https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder
- WatchConnectivity: https://developer.apple.com/documentation/watchconnectivity/wcsession

Use the terms/citations of the specific dataset release you download. Public CGMacros on PhysioNet is CC BY-NC-SA 4.0. No downloaded dataset records are included in this source package.

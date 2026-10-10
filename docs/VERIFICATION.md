# Verification and Mac handoff

Completed in the creation environment:

- Ten Python tests of training leakage, pre-meal feature cutoffs, valid target windows, missing modalities, JSON numerical values, ZIP member selection, Parquet participant/source isolation, duplicates and insufficient history.
- Swift syntax parsing of all source files.
- OpenStep parsing of the Xcode project and XML parsing of both schemes/property lists.
- Resource and source membership inspection for both targets.
- A deterministic bundled seven-day fit with three held-out Day 8 meals. Its results describe generated data only.

Not completed here: Apple SDK compilation, Swift typechecking with the Apple SDK, Simulator rendering, camera hardware, signed installation, HealthKit authorization or paired Watch transport. No Mac/Xcode/Apple SDK was available in the creation environment.

On the Mac, run `bash scripts/check_on_mac.sh`. It checks shared Swift/Python inference parity and builds both Simulator targets. Do not treat syntax parsing as a substitute for these builds.

Then validate on actual devices:

1. Install iPhone and Watch targets with a signing team supporting HealthKit.
2. Grant and deny Health permissions separately; missing data must stay unavailable rather than appear as synthetic Watch measurements.
3. Enable demo glucose and verify its source label. Disable it with no CGM; a new forecast must stop with a missing-glucose message.
4. With readable CGM, verify mg/dL, sample age and trend. Old CGM over 15 minutes must block a new live forecast.
5. Start a real walking session, confirm changing heart rate on Watch and iPhone. Take iPhone offline; live samples should cease and old samples become stale.
6. End the walk; confirm it is saved to Health. Verify there is no session running after end/error.
7. Log a photo and confirmed nutrition. Confirm the phone and Watch show the same forecast peak and meal; Watch describes a forecast, not a glucose measurement.
8. Import an exported real participant JSON; check participant ID, provenance, Day 8 cases and validation values. Unsupported schema/malformed JSON must display an import error.
9. Relaunch the iPhone app; model and saved forecasts should remain. Delete local data; forecasts/photos/models should clear and the app should return to its bundled demo.
10. Try larger text accessibility sizes and a small iPhone screen; inspect all four tabs and the meal form.

If Xcode changes recommended settings, keep the platform minimums and both HealthKit entitlements. If a build fails, use the concrete Xcode error to repair it before presenting it as device-tested.

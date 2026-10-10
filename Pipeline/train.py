"""Person-specific ridge trajectory model, chronological 7-day fit / day-8 test.
Raw data stays on the computer. This script exports a small iPhone JSON package.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path, PurePosixPath
import zipfile
import numpy as np
import pandas as pd

FEATURES = ["Carbohydrates", "Protein", "Fat", "Fiber", "Baseline glucose", "Pre-meal trend", "Heart rate", "Activity kcal in prior hour", "Bolus units in prior 2 hours", "Hour sine", "Hour cosine", "Carbs in prior 2 hours"]
CANONICAL = ["carbs", "protein", "fat", "fiber", "glucose", "heart_rate", "activity_kcal", "bolus"]

def load_data(path, fmt, participant=None, source_file=None, glucose_column=None, timezone="UTC"):
    path = Path(path)
    if fmt == "metabonet":
        import pyarrow.dataset as ds
        dataset = ds.dataset(path, format="parquet")
        if not participant:
            raise ValueError("MetaboNet requires --participant. Use --inspect to see columns.")
        idtype = dataset.schema.field("id").type
        import pyarrow as pa
        identity = int(participant) if pa.types.is_integer(idtype) else float(participant) if pa.types.is_floating(idtype) else str(participant)
        filt = ds.field("id") == identity
        if source_file:
            filt = filt & (ds.field("source_file") == source_file)
        cols = [c for c in ["id", "source_file", "date", "CGM", "carbs", "heartrate", "bolus", "meal_label"] if c in dataset.schema.names]
        df = dataset.to_table(columns=cols, filter=filt).to_pandas()
        if "source_file" in df and df.source_file.nunique() > 1:
            raise ValueError("This id occurs in multiple sources. Specify --source-file; do not mix people.")
        df = df.rename(columns={"date": "timestamp", "CGM": "glucose", "heartrate": "heart_rate", "meal_label": "meal_name"})
        # calories_burned varies across source datasets: not automatically treated
        # as interval energy. Protein/fat/fiber and activity are unknown here.
    elif fmt == "cgmacros":
        if not participant:
            raise ValueError("CGMacros requires --participant, for example 001.")
        label = f"CGMacros-{int(participant):03d}.csv"
        if path.suffix.lower() == ".zip":
            with zipfile.ZipFile(path) as archive:
                matches = [n for n in archive.namelist() if PurePosixPath(n).name.lower() == label.lower()]
                if len(matches) != 1:
                    raise ValueError(f"Expected exactly one {label}; found {len(matches)}. Inspect the archive.")
                # Read selected member; never extract arbitrary archive paths.
                with archive.open(matches[0]) as stream:
                    df = pd.read_csv(stream)
        elif path.is_dir():
            matches = list(path.rglob(label))
            if len(matches) != 1:
                raise ValueError(f"Expected exactly one {label}; found {len(matches)}.")
            df = pd.read_csv(matches[0])
        else:
            df = pd.read_csv(path)
        df.columns = df.columns.str.strip()
        chosen = glucose_column or "Dexcom GL"
        if chosen not in df:
            raise ValueError(f"Missing {chosen}. Use --glucose-column 'Libre GL' explicitly if needed.")
        df = df.rename(columns={"Timestamp": "timestamp", chosen: "glucose", "HR": "heart_rate", "Calories (Activity)": "activity_kcal", "Meal Type": "meal_name", "Carbs": "carbs", "Protein": "protein", "Fat": "fat", "Fiber": "fiber", "Image Path": "photo_path"})
    else:
        df = pd.read_csv(path)
        # Normalized CSV must contain exactly one participant.
        if "participant_id" in df and df.participant_id.nunique() != 1:
            raise ValueError("Normalized CSV must contain one participant.")
    if "timestamp" not in df or "glucose" not in df or "carbs" not in df:
        raise ValueError("Need timestamp, glucose and carbs columns. See docs/DATA.md.")
    dt = pd.to_datetime(df.timestamp, errors="raise")
    if dt.dt.tz is None:
        dt = dt.dt.tz_localize(timezone, ambiguous="raise", nonexistent="raise")
    else:
        dt = dt.dt.tz_convert(timezone)
    df["timestamp"] = dt
    for c in CANONICAL:
        if c not in df:
            df[c] = np.nan
        df[c] = pd.to_numeric(df[c], errors="coerce")
        df.loc[~np.isfinite(df[c]), c] = np.nan
    df.loc[(df.glucose < 40) | (df.glucose > 400), "glucose"] = np.nan
    for c in ["carbs", "protein", "fat", "fiber", "activity_kcal", "bolus"]:
        if (df[c].dropna() < 0).any():
            raise ValueError(f"Negative {c} values. Resolve source semantics before training.")
    if "meal_name" not in df:
        df["meal_name"] = "Meal"
    df = df.sort_values("timestamp").reset_index(drop=True)
    if df.empty:
        raise ValueError("No rows match this participant.")
    if df.timestamp.duplicated().any():
        raise ValueError("Duplicate timestamps. Resolve duplicate records before training; no silent aggregation.")
    return df

def sample_targets(cgm, time):
    """Interpolate outcomes only with a <=15 minute bracketing gap."""
    values = []
    for minute in range(5, 121, 5):
        target = time + pd.Timedelta(minutes=minute)
        before = cgm[cgm.timestamp <= target].tail(1)
        after = cgm[cgm.timestamp >= target].head(1)
        if before.empty or after.empty:
            return None
        a, b = before.iloc[0], after.iloc[0]
        span = (b.timestamp - a.timestamp).total_seconds()
        if span > 900:
            return None
        value = a.glucose if span == 0 else a.glucose + (b.glucose-a.glucose)*(target-a.timestamp).total_seconds()/span
        values.append(float(value))
    return np.array(values)

def build_examples(df):
    cgm = df.dropna(subset=["glucose"])[["timestamp", "glucose"]]
    zero_carb_meal = df[["protein", "fat", "fiber"]].notna().any(axis=1) & df.meal_name.notna() & df.meal_name.ne("Meal")
    meals = df[df.carbs.notna() & ((df.carbs > 0) | zero_carb_meal)]
    # Repeated meal labels without nutrition are not repeated meal events.
    start = df.timestamp.iloc[0].normalize()
    examples = []
    skipped = 0
    for index, meal in meals.iterrows():
        t = meal.timestamp
        past = df[(df.timestamp <= t) & (df.timestamp > t-pd.Timedelta(hours=2))]
        g = cgm[(cgm.timestamp <= t) & (cgm.timestamp >= t-pd.Timedelta(minutes=30))]
        if g.empty or (t-g.timestamp.iloc[-1]).total_seconds() > 900:
            skipped += 1
            continue
        baseline = float(g.glucose.iloc[-1])
        trend = None
        if len(g) >= 2:
            gap = (g.timestamp.iloc[-1]-g.timestamp.iloc[0]).total_seconds()/60
            if gap >= 5:
                trend = float((g.glucose.iloc[-1]-g.glucose.iloc[0])*5/gap)
        hrrows = past[(past.timestamp >= t-pd.Timedelta(minutes=15))].heart_rate.dropna()
        hr = float(hrrows.iloc[-1]) if len(hrrows) else None
        act = past[(past.timestamp > t-pd.Timedelta(hours=1))].activity_kcal
        energy = float(act.sum()) if act.notna().any() else None
        bolus = float(past.bolus.sum()) if past.bolus.notna().any() else None
        prior = past[(past.timestamp < t)].carbs
        priorcarbs = float(prior.sum()) if prior.notna().any() else None
        hour = t.hour + t.minute/60
        x = [meal[c] if pd.notna(meal[c]) else None for c in ["carbs", "protein", "fat", "fiber"]]
        x += [baseline, trend, hr, energy, bolus, np.sin(hour*2*np.pi/24), np.cos(hour*2*np.pi/24), priorcarbs]
        day = int((t.normalize()-start).total_seconds()//86400)+1
        # Day numbering uses local calendar dates, including DST transitions.
        day = (t.date()-start.date()).days+1
        y = sample_targets(cgm, t)
        nextmeals = meals[meals.timestamp > t].timestamp
        contaminated = bool(len(nextmeals) and nextmeals.iloc[0] < t+pd.Timedelta(minutes=120))
        if contaminated:
            skipped += 1
            continue
        # Reject training/validation windows crossing the day boundary, so targets
        # from the next day cannot enter fit or interval estimation.
        if day <= 7 and (t+pd.Timedelta(minutes=120)).date() != t.date():
            skipped += 1
            continue
        if day <= 7 and y is None:
            skipped += 1
            continue
        examples.append({"x": x, "y": y, "day": day, "timestamp": t.isoformat(), "name": str(meal.meal_name) if pd.notna(meal.meal_name) else "Meal", "photo": str(meal.get("photo_path")) if pd.notna(meal.get("photo_path")) else None})
    return examples, skipped

def fit(examples, penalty=10.0):
    raw = np.array([e["x"] for e in examples], dtype=float)
    imp = np.array([float(np.median(c[np.isfinite(c)])) if np.isfinite(c).any() else 0 for c in raw.T])
    x = np.column_stack([np.where(np.isfinite(raw), raw, imp), ~np.isfinite(raw)])
    means = x.mean(0)
    scales = x.std(0)
    scales[scales < 1e-8] = 1
    z = (x-means)/scales
    y = np.array([e["y"]-e["x"][4] for e in examples])
    intercepts = y.mean(0)
    weights = np.linalg.solve(z.T@z+penalty*np.eye(z.shape[1]), z.T@(y-intercepts))
    mins = np.array([float(c[np.isfinite(c)].min()) if np.isfinite(c).any() else 0 for c in raw.T])
    maxs = np.array([float(c[np.isfinite(c)].max()) if np.isfinite(c).any() else 0 for c in raw.T])
    return {"imputation": imp.tolist(), "means": means.tolist(), "scales": scales.tolist(), "coefficients": weights.T.tolist(), "intercepts": intercepts.tolist(), "minimums": mins.tolist(), "maximums": maxs.tolist()}

def predict(model, values):
    raw = np.asarray(values, dtype=float)
    x = np.r_[np.where(np.isfinite(raw), raw, model["imputation"]), ~np.isfinite(raw)]
    z = (x-model["means"])/model["scales"]
    return values[4] + np.asarray(model["coefficients"])@z + model["intercepts"]

def train(df, participant_id, provenance, synthetic=False):
    examples, skipped = build_examples(df)
    train7 = [e for e in examples if 1 <= e["day"] <= 7 and e["y"] is not None]
    earlier = [e for e in train7 if e["day"] <= 6]
    validation = [e for e in train7 if e["day"] == 7]
    tests = [e for e in examples if e["day"] == 8]
    if len(train7) < 8 or len({e["day"] for e in train7}) < 7:
        raise ValueError("Need >=8 complete, non-overlapping meals spread over all 7 days. Select another participant/window.")
    widths = np.repeat(25., 24)
    mae = persistence = None
    validation_count = 0
    if len(earlier) >= 8 and validation:
        preliminary = fit(earlier)
        residuals = np.array([predict(preliminary, e["x"])-e["y"] for e in validation])
        # Small-sample empirical spread. This is NOT calibrated probability.
        widths = np.maximum(10, np.quantile(np.abs(residuals), .8, axis=0))
        mae = float(np.abs(residuals).mean())
        persistence = float(np.mean([np.abs(e["y"]-e["x"][4]).mean() for e in validation]))
        validation_count = len(validation)
    model = fit(train7)
    cases = []
    for i, e in enumerate(tests):
        cases.append({"id": f"day8-{i+1}", "input": {"name": e["name"], "timestamp": e["timestamp"], "values": e["x"], "source": provenance}, "observed": e["y"].tolist() if e["y"] is not None else [], "photoPath": e["photo"]})
    model.update(schemaVersion=1, participantID=participant_id, provenance=provenance, synthetic=synthetic, trainingEnd=max(e["timestamp"] for e in train7), trainingCount=len(train7), featureNames=FEATURES, widths=widths.tolist(), validationCount=validation_count, validationMAE=mae, persistenceMAE=persistence, cases=cases)
    report = {"trainingMeals": len(train7), "validationMeals": validation_count, "testMeals": len(tests), "skippedMeals": skipped, "day7MAE": mae, "day7PersistenceMAE": persistence, "day8MAE": float(np.mean([np.abs(predict(model, e["x"])-e["y"]).mean() for e in tests if e["y"] is not None])) if any(e["y"] is not None for e in tests) else None}
    return model, report

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", type=Path)
    p.add_argument("--format", choices=["normalized", "cgmacros", "metabonet"], required=True)
    p.add_argument("--participant")
    p.add_argument("--source-file")
    p.add_argument("--glucose-column")
    p.add_argument("--timezone", default="UTC", help="Timezone of naive source timestamps; preserve local meal hour")
    p.add_argument("--output", type=Path, default=Path("participant.json"))
    p.add_argument("--start-date", help="Local YYYY-MM-DD; default earliest local date")
    p.add_argument("--inspect", action="store_true")
    args = p.parse_args()
    if args.inspect:
        if args.input.suffix.lower() == ".parquet":
            import pyarrow.parquet as pq
            print(pq.read_schema(args.input))
        elif args.input.suffix.lower() == ".zip":
            with zipfile.ZipFile(args.input) as z:
                print("\n".join(n for n in z.namelist() if n.lower().endswith(".csv")))
        else:
            print(pd.read_csv(args.input, nrows=3).to_string(index=False))
        return
    df = load_data(args.input, args.format, args.participant, args.source_file, args.glucose_column, args.timezone)
    if args.start_date:
        start = pd.Timestamp(args.start_date, tz=args.timezone)
        df = df[(df.timestamp >= start) & (df.timestamp < start+pd.DateOffset(days=8))].copy()
        if df.empty or df.timestamp.iloc[0].date() != start.date():
            raise ValueError("Selected start date has no records.")
    model, report = train(df, args.participant or "normalized-participant", args.format)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(model, indent=2, allow_nan=False)+"\n")
    args.output.with_suffix(".metrics.json").write_text(json.dumps(report, indent=2, allow_nan=False)+"\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()

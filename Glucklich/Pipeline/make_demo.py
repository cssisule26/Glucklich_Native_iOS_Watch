"""Generate clearly labeled, deterministic test data, not patient data."""
from pathlib import Path
import json
import numpy as np
import pandas as pd
from train import train

def make_demo():
    rng = np.random.default_rng(47)
    times = pd.date_range("2026-09-01", periods=8*288, freq="5min", tz="UTC")
    df = pd.DataFrame({"timestamp": times})
    baseline = 104+4*np.sin(np.arange(len(times))*2*np.pi/288)
    glucose = baseline.copy()
    df["heart_rate"] = 72+5*np.sin(np.arange(len(times))*.08)+rng.normal(0,2,len(times))
    df["activity_kcal"] = rng.uniform(.3,1.2,len(times))
    df["bolus"] = 0.
    for c in ["carbs", "protein", "fat", "fiber"]:
        df[c] = np.nan
    df["meal_name"] = None
    for day in range(8):
        for hour, name in [(8,"Oats and berries"),(13,"Rice bowl"),(19,"Pasta and vegetables")]:
            index = day*288+hour*12
            carbs = float(rng.uniform(25,90))
            protein, fat, fiber = rng.uniform(10,40), rng.uniform(5,30), rng.uniform(3,12)
            df.loc[index,["carbs","protein","fat","fiber","meal_name"]] = [carbs,protein,fat,fiber,name]
            amplitude = .70*carbs+.12*fat-.8*fiber+6*(hour>17)
            tpeak = 45+.8*fat
            mins = np.arange(len(times)-index)*5.
            fraction = (mins/tpeak)*np.exp(1-mins/tpeak)
            glucose[index:] += amplitude*fraction
    df["glucose"] = glucose+rng.normal(0,2,len(times))
    return df

if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    df = make_demo()
    df.to_csv(root/"Pipeline/demo.csv", index=False)
    model, report = train(df, "demo-person-001", "Generated demo · not a patient", synthetic=True)
    (root/"Resources/demo_participant.json").write_text(json.dumps(model, indent=2, allow_nan=False)+"\n")
    (root/"Tests/demo_expected.json").write_text(json.dumps({"report":report,"values":model["cases"][0]["input"]["values"]}, indent=2)+"\n")
    print(json.dumps(report, indent=2))

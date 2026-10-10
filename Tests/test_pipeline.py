import json
import sys
import tempfile
import unittest
from pathlib import Path
import zipfile
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"Pipeline"))
from train import train, predict, load_data, build_examples
from make_demo import make_demo

class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.df = make_demo()
        cls.model, cls.report = train(cls.df, "test", "unit-test", synthetic=True)

    def test_day8_labels_do_not_change_model_or_forecasts(self):
        altered = self.df.copy()
        cutoff = altered.timestamp.iloc[0]+pd.Timedelta(days=7)
        # Edit only post-meal labels on Day 8; preserve pre-meal input windows.
        for h in [8,13,19]:
            t = cutoff+pd.Timedelta(hours=h)
            altered.loc[(altered.timestamp > t)&(altered.timestamp <= t+pd.Timedelta(minutes=120)), "glucose"] += 70
        modified, _ = train(altered, "test", "unit-test", synthetic=True)
        for field in ["coefficients","intercepts","means","scales","widths","validationMAE"]:
            self.assertEqual(self.model[field], modified[field])
        for a,b in zip(self.model["cases"], modified["cases"]):
            np.testing.assert_array_equal(predict(self.model,a["input"]["values"]),predict(modified,b["input"]["values"]))
            self.assertNotEqual(a["observed"],b["observed"])

    def test_feature_snapshot_never_reads_future(self):
        examples, _ = build_examples(self.df)
        first = examples[0]
        t = pd.Timestamp(first["timestamp"])
        edited = self.df.copy()
        edited.loc[edited.timestamp>t,["heart_rate","activity_kcal","bolus"]] = 999
        rebuilt, _ = build_examples(edited)
        self.assertEqual(first["x"],rebuilt[0]["x"])

    def test_sparse_gaps_are_rejected(self):
        df = self.df.copy()
        time = df.timestamp.iloc[0]+pd.Timedelta(hours=8)
        df.loc[(df.timestamp>time+pd.Timedelta(minutes=20))&(df.timestamp<time+pd.Timedelta(minutes=60)),"glucose"] = np.nan
        examples, skipped = build_examples(df)
        self.assertFalse(any(pd.Timestamp(e["timestamp"])==time for e in examples))
        self.assertGreaterEqual(skipped,1)

    def test_overlapping_meals_excluded(self):
        df = self.df.copy()
        i = 8*12+10
        df.loc[i,["carbs","meal_name"]] = [20,"Snack"]
        examples, skipped = build_examples(df)
        original_meal_time = df.timestamp.iloc[0]+pd.Timedelta(hours=8)
        self.assertFalse(any(pd.Timestamp(e["timestamp"])==original_meal_time for e in examples))
        self.assertGreaterEqual(skipped,1)

    def test_json_is_finite_and_matches_contract(self):
        json.dumps(self.model, allow_nan=False)
        self.assertEqual(len(self.model["coefficients"]),24)
        self.assertEqual(len(self.model["coefficients"][0]),24)
        self.assertEqual(len(self.model["featureNames"]),12)
        self.assertEqual(self.model["trainingCount"],21)
        self.assertEqual(len(self.model["cases"]),3)
        for item in self.model["cases"]:
            result = predict(self.model,item["input"]["values"])
            self.assertTrue(np.isfinite(result).all())
        self.assertLess(self.report["day7MAE"],self.report["day7PersistenceMAE"])

    def test_missing_modalities_are_recorded_not_synthetic(self):
        df = self.df.copy()
        df[["heart_rate","activity_kcal","bolus"]] = np.nan
        model, _ = train(df,"test","unit-test")
        self.assertIsNone(model["cases"][0]["input"]["values"][6])
        self.assertIsNone(model["cases"][0]["input"]["values"][7])
        self.assertTrue(np.isfinite(predict(model,model["cases"][0]["input"]["values"])).all())

    def test_parquet_loader_filters_identity_and_source(self):
        df = self.df.rename(columns={"timestamp":"date","glucose":"CGM","heart_rate":"heartrate"}).copy()
        df["id"] = "1"
        df["source_file"] = "A"
        b = df.copy()
        b["source_file"] = "B"
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"data.parquet"
            pd.concat([df,b]).to_parquet(path,index=False)
            with self.assertRaisesRegex(ValueError,"multiple sources"):
                load_data(path,"metabonet",participant="1")
            loaded = load_data(path,"metabonet",participant="1",source_file="A")
            self.assertEqual(len(loaded),len(df))
            self.assertTrue(loaded.protein.isna().all())
            self.assertTrue(loaded.activity_kcal.isna().all())

    def test_zip_loader_reads_only_selected_csv(self):
        cg = self.df.rename(columns={"timestamp":"Timestamp","glucose":"Dexcom GL","heart_rate":"HR","activity_kcal":"Calories (Activity)","meal_name":"Meal Type","carbs":"Carbs","protein":"Protein","fat":"Fat","fiber":"Fiber"})
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"data.zip"
            with zipfile.ZipFile(path,"w") as z:
                z.writestr("nested/CGMacros-001/CGMacros-001.csv",cg.to_csv(index=False))
                z.writestr("../../unsafe.txt","do not extract")
            loaded = load_data(path,"cgmacros",participant="001")
            model, _ = train(loaded,"001","CGMacros fixture")
            self.assertEqual(model["trainingCount"],21)
            self.assertFalse((Path(folder)/"unsafe.txt").exists())

    def test_duplicates_and_insufficient_days_fail_clearly(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/"duplicate.csv"
            pd.concat([self.df,self.df.head(1)]).to_csv(path,index=False)
            with self.assertRaisesRegex(ValueError,"Duplicate"):
                load_data(path,"normalized")
        with self.assertRaisesRegex(ValueError,"all 7 days"):
            train(self.df.iloc[:6*288],"test","test")

    def test_day7_cross_boundary_labels_never_enter_training(self):
        df = self.df.copy()
        t = df.timestamp.iloc[0]+pd.Timedelta(days=6,hours=23)
        df.loc[df.timestamp==t,["carbs","meal_name"]]=[40,"Late meal"]
        examples,_ = build_examples(df)
        self.assertFalse(any(pd.Timestamp(e["timestamp"])==t for e in examples))

if __name__ == "__main__": unittest.main()

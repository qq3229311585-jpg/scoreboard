"""
对我们自己采集的 IMU JSON 文件做球技分类预测。
用法：
  python predict.py --model model/ --file /path/to/imu_TIMESTAMP_杀球.json
"""

import argparse, json
import numpy as np
import joblib
from train import extract_features


def predict_our_file(model_dir, imu_path):
    clf   = joblib.load(f"{model_dir}/classifier.joblib")
    scaler = joblib.load(f"{model_dir}/scaler.joblib")
    le    = joblib.load(f"{model_dir}/label_encoder.joblib")

    with open(imu_path, encoding="utf-8") as f:
        data = json.load(f)

    version = data.get("version", 1)

    if version == 2:
        # 我们的新格式（双流）
        dm = data["streams"]["device_motion"]
        cols = dm["columns"]  # ["t","uax","uay","uaz","gx","gy","gz","grav_x","grav_y","grav_z","pitch","roll","yaw"]
        samples = np.array(dm["samples"])

        def col_idx(name):
            return cols.index(name) if name in cols else -1

        # 构造 BadminSense 风格的 Data 字典
        def get_axes(names):
            idxs = [col_idx(n) for n in names if col_idx(n) >= 0]
            return samples[:, idxs] if idxs else np.empty((0, 0))

        fake_data = {
            "ACCELEROMETER":   get_axes(["uax", "uay", "uaz"]),
            "GYROSCOPE":       get_axes(["gx", "gy", "gz"]),
            "ROTATION_VECTOR": get_axes(["pitch", "roll", "yaw"]),
        }
    else:
        # 老格式（version 1，单流）
        samples = np.array(data["samples"])
        cols = data["columns"]

        def get_axes(names):
            idxs = [cols.index(n) for n in names if n in cols]
            return samples[:, idxs] if idxs else np.empty((0, 0))

        fake_data = {
            "ACCELEROMETER": get_axes(["ax", "ay", "az"]),
            "GYROSCOPE":     get_axes(["gx", "gy", "gz"]),
            "ROTATION_VECTOR": np.empty((0, 0)),
        }

    feats = extract_features(fake_data).reshape(1, -1)
    feats_scaled = scaler.transform(feats)

    pred_enc = clf.predict(feats_scaled)[0]
    label = le.inverse_transform([pred_enc])[0]

    if hasattr(clf, "predict_proba"):
        probs = clf.predict_proba(feats_scaled)[0]
        print(f"\n文件：{imu_path}")
        print(f"预测结果：{label}")
        print("置信度分布：")
        for cls, prob in sorted(zip(le.classes_, probs), key=lambda x: -x[1]):
            bar = "█" * int(prob * 20)
            print(f"  {cls:8s}  {prob:.1%}  {bar}")
    else:
        print(f"预测结果：{label}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="model", help="模型目录")
    ap.add_argument("--file", required=True, help="我们采集的 IMU JSON 文件")
    args = ap.parse_args()
    predict_our_file(args.model, args.file)

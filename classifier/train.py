"""
BadminSense 击球分类器
用法：
  python train.py --data /path/to/BADS_CLL

依赖：pip install scikit-learn numpy joblib
"""

import os, json, argparse, warnings
import numpy as np
import joblib
from sklearn.ensemble import RandomForestClassifier
from sklearn.svm import SVC
from sklearn.preprocessing import StandardScaler, LabelEncoder
from sklearn.model_selection import LeaveOneGroupOut
from sklearn.metrics import classification_report, accuracy_score

warnings.filterwarnings("ignore")

LABEL_MAP = {
    "ForehandKill":       "杀球",
    "ForehandHigh":       "高远球",
    "ForehandLob":        "吊球",
    "BackhandTransition": "平抽",
}


# ─── 特征提取 ──────────────────────────────────────────────────────────────────

def get_axes(sensor_dict, axis_keys):
    """从 BadminSense 字典格式传感器数据提取指定轴，返回 (N, len(axis_keys)) numpy 数组。"""
    if not sensor_dict:
        return np.empty((0, len(axis_keys)))
    cols = []
    for k in axis_keys:
        v = sensor_dict.get(k)
        if v is None:
            return np.empty((0, len(axis_keys)))
        cols.append(np.array(v, dtype=float))
    min_len = min(len(c) for c in cols)
    return np.column_stack([c[:min_len] for c in cols])


def axis_features(col):
    """从单轴时间序列提取 6 个时域特征 + 10 个 FFT 幅度特征 = 16 维。"""
    if len(col) == 0:
        return [0.0] * 16
    col = np.array(col, dtype=float)
    feats = [
        float(np.mean(col)),
        float(np.std(col)),
        float(np.max(col)),
        float(np.min(col)),
        float(np.sqrt(np.mean(col ** 2))),
        float(np.max(col) - np.min(col)),
    ]
    fft = np.abs(np.fft.rfft(col))
    fft /= (fft.sum() + 1e-8)
    feats += list(fft[:10]) + [0.0] * max(0, 10 - len(fft))
    return feats[:16]


def extract_features(stroke_data):
    """
    从一条 stroke 的 data 字段提取特征向量。
    ACCELEROMETER (Gx/Gy/Gz) + GYROSCOPE (angularSpeedX/Y/Z)，每轴 16 维 = 96 维。
    ROTATION_VECTOR 前 3 轴均值 = 3 维。共 99 维。
    """
    feats = []

    accel = get_axes(stroke_data.get("ACCELEROMETER"),
                     ["Gx", "Gy", "Gz"])
    gyro  = get_axes(stroke_data.get("GYROSCOPE"),
                     ["angularSpeedX", "angularSpeedY", "angularSpeedZ"])

    for arr in (accel, gyro):
        if arr.shape[0] == 0:
            feats += [0.0] * (3 * 16)
        else:
            for axis in range(3):
                feats += axis_features(arr[:, axis] if arr.shape[1] > axis else [])

    rot = get_axes(stroke_data.get("ROTATION_VECTOR"),
                   ["vectorX", "vectorY", "vectorZ"])
    if rot.shape[0] > 0:
        feats += list(np.mean(rot, axis=0))
    else:
        feats += [0.0, 0.0, 0.0]

    return np.array(feats, dtype=float)


# ─── 数据加载 ──────────────────────────────────────────────────────────────────

def load_dataset(dataset_path):
    X, y, groups = [], [], []
    skipped = 0

    for folder in sorted(os.listdir(dataset_path)):
        folder_path = os.path.join(dataset_path, folder)
        if not os.path.isdir(folder_path):
            continue

        # 文件夹名：Gender_Exp_StrokeType_PlayerCode_Section_Device
        parts = folder.split("_")
        player_code = parts[3] if len(parts) >= 4 else folder

        json_files = [f for f in os.listdir(folder_path) if f.endswith(".json")]
        if not json_files:
            continue

        json_path = os.path.join(folder_path, json_files[0])
        with open(json_path, encoding="utf-8") as f:
            content = json.load(f)

        strokes = content if isinstance(content, list) else [content]

        for stroke in strokes:
            try:
                label_raw = stroke["label"]["actionType"]
                label = LABEL_MAP.get(label_raw, label_raw)
                feats = extract_features(stroke["data"])
                if np.all(feats == 0):
                    skipped += 1
                    continue
                X.append(feats)
                y.append(label)
                groups.append(player_code)
            except Exception as e:
                skipped += 1
                print(f"  跳过 {folder}: {e}")

    print(f"加载完成：{len(X)} 条样本，{skipped} 条跳过")
    return np.array(X), np.array(y), np.array(groups)


# ─── 训练与评估 ────────────────────────────────────────────────────────────────

def train_and_evaluate(X, y, groups):
    le = LabelEncoder()
    y_enc = le.fit_transform(y)
    print(f"球技类别：{list(le.classes_)}")
    print(f"样本分布：{ {c: int((y==c).sum()) for c in le.classes_} }\n")

    logo = LeaveOneGroupOut()
    all_true, all_pred = [], []

    for fold, (train_idx, test_idx) in enumerate(logo.split(X, y_enc, groups)):
        X_tr, X_te = X[train_idx], X[test_idx]
        y_tr, y_te = y_enc[train_idx], y_enc[test_idx]

        scaler = StandardScaler()
        X_tr = scaler.fit_transform(X_tr)
        X_te = scaler.transform(X_te)

        clf = SVC(kernel="rbf", C=10, gamma="scale", class_weight="balanced")
        clf.fit(X_tr, y_tr)
        preds = clf.predict(X_te)

        all_true.extend(y_te)
        all_pred.extend(preds)

    all_true = np.array(all_true)
    all_pred = np.array(all_pred)
    acc = accuracy_score(all_true, all_pred)
    print(f"留一球员交叉验证准确率：{acc:.1%}\n")
    print(classification_report(all_true, all_pred, target_names=le.classes_))
    return acc


def train_final_model(X, y, out_dir):
    """用全量数据训练最终模型并保存。"""
    le = LabelEncoder()
    y_enc = le.fit_transform(y)

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    clf = SVC(kernel="rbf", C=10, gamma="scale", class_weight="balanced", probability=True)
    clf.fit(X_scaled, y_enc)

    os.makedirs(out_dir, exist_ok=True)
    joblib.dump(clf,    os.path.join(out_dir, "classifier.joblib"))
    joblib.dump(scaler, os.path.join(out_dir, "scaler.joblib"))
    joblib.dump(le,     os.path.join(out_dir, "label_encoder.joblib"))
    print(f"\n模型已保存到 {out_dir}/")


# ─── 入口 ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="BADS_CLL 数据集路径")
    ap.add_argument("--save", default="model", help="模型输出目录")
    args = ap.parse_args()

    print("=== 加载数据 ===")
    X, y, groups = load_dataset(args.data)
    if len(X) == 0:
        print("未找到任何样本，请确认 --data 路径指向 BADS_CLL 根目录")
        return

    print("\n=== 交叉验证 ===")
    train_and_evaluate(X, y, groups)

    print("\n=== 训练最终模型 ===")
    train_final_model(X, y, args.save)


if __name__ == "__main__":
    main()

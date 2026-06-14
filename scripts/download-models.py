#!/usr/bin/env python3
import argparse
from pathlib import Path


DEFAULT_MODELS = [
    (
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
        "Qwen3-TTS-12Hz-1.7B-Base-8bit",
    ),
    (
        "mlx-community/Qwen3-ASR-1.7B-4bit",
        "Qwen3-ASR-1.7B-4bit",
    ),
]


def is_complete_model_dir(path: Path) -> bool:
    return (
        path.is_dir()
        and (path / "config.json").is_file()
        and any(path.glob("*.safetensors"))
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Download iVox MLX models from ModelScope.")
    parser.add_argument(
        "--model-root",
        default="~/.config/ivox/model",
        help="Local directory that stores iVox models.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Download even when the target model directory looks complete.",
    )
    args = parser.parse_args()

    model_root = Path(args.model_root).expanduser()
    model_root.mkdir(parents=True, exist_ok=True)

    try:
        from modelscope.hub.snapshot_download import snapshot_download
    except ImportError:
        print("✗  缺少 ModelScope SDK，请先运行: python3 -m pip install modelscope")
        return 1

    for model_id, dirname in DEFAULT_MODELS:
        target = model_root / dirname
        if not args.force and is_complete_model_dir(target):
            print(f"[i] 模型已存在: {target}")
            continue

        print(f"↓  从 ModelScope 下载 {model_id}")
        snapshot_download(
            model_id=model_id,
            local_dir=str(target),
            repo_type="model",
        )
        if not is_complete_model_dir(target):
            print(f"✗  模型目录不完整: {target}")
            return 1
        print(f"✓  模型已就绪: {target}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

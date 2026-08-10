"""
Points Open WebUI's image generation at this stack's own ComfyUI container
and the SDXL checkpoint install.sh just downloaded, instead of leaving it on
Open WebUI's out-of-the-box default (engine "openai", no API key, which fails
immediately - "Enable Image Generation" would otherwise error every time with
no obvious cause, since the request never even reaches ComfyUI to log
anything). Safe to re-run: every value here is upserted, not appended.

Run inside the openwebui container by install.sh - see the bottom of this
file for the expected environment variables if running standalone.

The workflow/node mapping was verified against this exact Open WebUI image's
own source (open_webui/utils/images/comfyui.py: ComfyUINodeInput and
_apply_workflow_nodes), not guessed - each node's "key" is the literal input
name on that node in the workflow below, and node ids 3/4/5/6/7 are this
workflow's own KSampler / CheckpointLoaderSimple / EmptyLatentImage /
positive CLIPTextEncode / negative CLIPTextEncode.
"""
import asyncio
import json
import os

with open("/app/backend/.webui_secret_key") as f:
    os.environ["WEBUI_SECRET_KEY"] = f.read().strip()

from open_webui.models.config import Config

CHECKPOINT_NAME = os.environ["CHECKPOINT_NAME"]
COMFYUI_BASE_URL = os.environ.get("COMFYUI_BASE_URL", "http://comfyui:8188")

WORKFLOW = {
    "3": {
        "inputs": {
            "seed": 0, "steps": 20, "cfg": 8, "sampler_name": "dpmpp_2m",
            "scheduler": "karras", "denoise": 1,
            "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0],
            "latent_image": ["5", 0],
        },
        "class_type": "KSampler",
        "_meta": {"title": "KSampler"},
    },
    "4": {
        "inputs": {"ckpt_name": CHECKPOINT_NAME},
        "class_type": "CheckpointLoaderSimple",
        "_meta": {"title": "Load Checkpoint"},
    },
    "5": {
        "inputs": {"width": 1024, "height": 1024, "batch_size": 1},
        "class_type": "EmptyLatentImage",
        "_meta": {"title": "Empty Latent Image"},
    },
    "6": {
        "inputs": {"text": "Prompt", "clip": ["4", 1]},
        "class_type": "CLIPTextEncode",
        "_meta": {"title": "CLIP Text Encode (Prompt)"},
    },
    "7": {
        "inputs": {"text": "", "clip": ["4", 1]},
        "class_type": "CLIPTextEncode",
        "_meta": {"title": "CLIP Text Encode (Negative)"},
    },
    "8": {
        "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
        "class_type": "VAEDecode",
        "_meta": {"title": "VAE Decode"},
    },
    "9": {
        "inputs": {"filename_prefix": "ComfyUI", "images": ["8", 0]},
        "class_type": "SaveImage",
        "_meta": {"title": "Save Image"},
    },
}

# Each entry maps a semantic field to the node(s)/input key that should
# receive it at generation time - this is what actually overrides "4"'s
# ckpt_name, "6"/"7"'s text, etc. per request, on top of the static WORKFLOW
# above. Without this the workflow's literal values above never change.
NODES = [
    {"type": "model", "node_ids": ["4"], "key": "ckpt_name"},
    {"type": "prompt", "node_ids": ["6"], "key": "text"},
    {"type": "negative_prompt", "node_ids": ["7"], "key": "text"},
    {"type": "width", "node_ids": ["5"], "key": "width"},
    {"type": "height", "node_ids": ["5"], "key": "height"},
    {"type": "steps", "node_ids": ["3"], "key": "steps"},
    {"type": "seed", "node_ids": ["3"], "key": "seed"},
]


async def main():
    await Config.upsert(
        {
            "image_generation.enable": True,
            "image_generation.engine": "comfyui",
            "image_generation.model": CHECKPOINT_NAME,
            "image_generation.comfyui.base_url": COMFYUI_BASE_URL,
            "image_generation.comfyui.workflow": json.dumps(WORKFLOW),
            "image_generation.comfyui.nodes": NODES,
        }
    )
    print(f"Image generation wired to ComfyUI at {COMFYUI_BASE_URL} using {CHECKPOINT_NAME}")


asyncio.run(main())

# Expected environment variables when run standalone (already set for you
# when install.sh calls this automatically):
#   CHECKPOINT_NAME   - filename of the SDXL checkpoint already sitting in
#                        this stack's ComfyUI/models/checkpoints/ folder,
#                        e.g. animagine-xl-3.1.safetensors
#   COMFYUI_BASE_URL  - defaults to http://comfyui:8188, this stack's own
#                        ComfyUI container on the compose network

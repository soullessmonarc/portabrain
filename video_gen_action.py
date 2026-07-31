"""
title: Generate Video (LTX)
description: Generates a short video clip via ComfyUI's native LTX-Video pipeline and attaches it to the chat. Animates the most recently attached image if one is found on the message (or an earlier message in the chat); otherwise generates from the message text alone.
"""

import asyncio
import base64
import io
import json
import logging
import random
import re
import urllib.parse

import aiohttp
from fastapi import Request, UploadFile
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

log = logging.getLogger(__name__)

COMFYUI_BASE_URL = "http://comfyui:8188"

NEGATIVE_PROMPT = "blurry, low quality, watermark, text, static"


def build_workflow(
    prompt_text: str,
    seed: int,
    width: int,
    height: int,
    length: int,
    steps: int,
    image_filename: str | None = None,
    image_strength: float = 1.0,
) -> dict:
    workflow = {
        "1": {
            "class_type": "CheckpointLoaderSimple",
            "inputs": {"ckpt_name": "ltxv-2b-0.9.8-distilled-fp8.safetensors"},
        },
        "2": {
            "class_type": "CLIPLoader",
            "inputs": {"clip_name": "t5xxl_fp8_e4m3fn.safetensors", "type": "ltxv"},
        },
        "3": {
            "class_type": "CLIPTextEncode",
            "inputs": {"clip": ["2", 0], "text": prompt_text},
        },
        "4": {
            "class_type": "CLIPTextEncode",
            "inputs": {"clip": ["2", 0], "text": NEGATIVE_PROMPT},
        },
        "6": {
            "class_type": "LTXVConditioning",
            "inputs": {"positive": ["3", 0], "negative": ["4", 0], "frame_rate": 24.0},
        },
    }

    if image_filename:
        # Image-to-video: LTXVImgToVideo takes the text conditioning plus a
        # starting image and produces augmented conditioning + a starting
        # latent (encoding the image as the first frame), replacing the
        # empty latent used in the text-only path.
        workflow["11"] = {
            "class_type": "LoadImage",
            "inputs": {"image": image_filename},
        }
        workflow["12"] = {
            "class_type": "LTXVImgToVideo",
            "inputs": {
                "positive": ["6", 0],
                "negative": ["6", 1],
                "vae": ["1", 2],
                "image": ["11", 0],
                "width": width,
                "height": height,
                "length": length,
                "batch_size": 1,
                "strength": image_strength,
            },
        }
        sampling_latent = ["12", 2]
        sampler_positive = ["12", 0]
        sampler_negative = ["12", 1]
    else:
        workflow["5"] = {
            "class_type": "EmptyLTXVLatentVideo",
            "inputs": {"width": width, "height": height, "length": length, "batch_size": 1},
        }
        sampling_latent = ["5", 0]
        sampler_positive = ["6", 0]
        sampler_negative = ["6", 1]

    workflow["7"] = {
        "class_type": "ModelSamplingLTXV",
        "inputs": {"model": ["1", 0], "max_shift": 2.05, "base_shift": 0.95, "latent": sampling_latent},
    }
    workflow["8"] = {
        "class_type": "KSampler",
        "inputs": {
            "model": ["7", 0],
            "seed": seed,
            "steps": steps,
            "cfg": 1.0,
            "sampler_name": "euler",
            "scheduler": "normal",
            "positive": sampler_positive,
            "negative": sampler_negative,
            "latent_image": sampling_latent,
            "denoise": 1.0,
        },
    }
    workflow["9"] = {
        "class_type": "VAEDecode",
        "inputs": {"samples": ["8", 0], "vae": ["1", 2]},
    }
    workflow["10"] = {
        "class_type": "SaveWEBM",
        "inputs": {"images": ["9", 0], "filename_prefix": "openwebui_video", "codec": "vp9", "fps": 24.0, "crf": 32.0},
    }
    return workflow


FILE_URL_ID_RE = re.compile(r"/api/v1/files/([^/]+)/content")


async def get_source_image(messages: list) -> tuple[bytes, str] | None:
    """Find the most recently attached image, scanning from the newest
    message backward - covers both "generate an image then animate this
    reply" and "I uploaded a photo earlier, animate it" flows. Reads the
    file directly off local storage rather than over HTTP."""
    from open_webui.models.files import Files
    from open_webui.storage.provider import Storage

    for message in reversed(messages):
        for file in message.get("files", []) or []:
            is_image = file.get("type") == "image" or str(file.get("content_type", "")).startswith("image/")
            if not is_image:
                continue
            file_id = file.get("id")
            if not file_id:
                # Generated images (from the "Enable Image Generation"
                # toggle) show up with a "url" like
                # /api/v1/files/{id}/content and no separate "id" field.
                url_match = FILE_URL_ID_RE.search(str(file.get("url", "")))
                file_id = url_match.group(1) if url_match else None
            if not file_id:
                continue
            file_record = await Files.get_file_by_id(file_id)
            if not file_record or not file_record.path:
                continue
            local_path = await asyncio.to_thread(Storage.get_file, file_record.path)
            with open(local_path, "rb") as f:
                return f.read(), file_record.filename or "source.png"
    return None


async def upload_image_to_comfyui(session: aiohttp.ClientSession, image_bytes: bytes, filename: str) -> str:
    form = aiohttp.FormData()
    form.add_field("image", image_bytes, filename=filename, content_type="application/octet-stream")
    form.add_field("overwrite", "true")
    async with session.post(f"{COMFYUI_BASE_URL}/upload/image", data=form) as r:
        r.raise_for_status()
        data = await r.json()
        subfolder = data.get("subfolder", "")
        return f"{subfolder}/{data['name']}" if subfolder else data["name"]


async def queue_prompt(session: aiohttp.ClientSession, workflow: dict, client_id: str) -> str:
    async with session.post(
        f"{COMFYUI_BASE_URL}/prompt",
        json={"prompt": workflow, "client_id": client_id},
    ) as r:
        r.raise_for_status()
        data = await r.json()
        if data.get("node_errors"):
            raise RuntimeError(f"ComfyUI rejected the workflow: {data['node_errors']}")
        return data["prompt_id"]


async def wait_for_completion(
    session: aiohttp.ClientSession,
    client_id: str,
    prompt_id: str,
    status_callback=None,
    timeout_s: int = 600,
):
    ws_url = COMFYUI_BASE_URL.replace("http://", "ws://").replace("https://", "wss://")
    async with session.ws_connect(f"{ws_url}/ws?clientId={client_id}", timeout=timeout_s) as ws:
        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                message = json.loads(msg.data)
                msg_type = message.get("type")
                data = message.get("data", {})

                if msg_type == "progress" and status_callback:
                    value, max_value = data.get("value"), data.get("max")
                    if value is not None and max_value:
                        pct = round(100 * value / max_value)
                        await status_callback(f"Rendering video: {pct}% ({value}/{max_value} steps)...")

                elif msg_type == "executing":
                    if data.get("node") is None and data.get("prompt_id") == prompt_id:
                        return
                    if data.get("node") is not None and status_callback:
                        await status_callback("Rendering video (loading model components)...")

            elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                raise RuntimeError("ComfyUI websocket closed unexpectedly")


async def get_output_file(session: aiohttp.ClientSession, prompt_id: str):
    async with session.get(f"{COMFYUI_BASE_URL}/history/{prompt_id}") as r:
        r.raise_for_status()
        history = (await r.json())[prompt_id]

    for node_output in history["outputs"].values():
        for image in node_output.get("images", []):
            if image["filename"].endswith(".webm"):
                params = urllib.parse.urlencode(
                    {"filename": image["filename"], "subfolder": image["subfolder"], "type": image["type"]}
                )
                async with session.get(f"{COMFYUI_BASE_URL}/view?{params}") as r2:
                    r2.raise_for_status()
                    return await r2.read(), image["filename"]

    raise RuntimeError("No video output found in ComfyUI history for this job")


class Action:
    class Valves(BaseModel):
        width: int = 512
        height: int = 320
        length: int = 33
        steps: int = 8
        image_strength: float = 1.0

    def __init__(self):
        self.valves = self.Valves()

    async def action(
        self,
        body: dict,
        __user__: dict = None,
        __event_emitter__=None,
        __request__: Request = None,
    ):
        from open_webui.models.chats import Chats
        from open_webui.models.users import Users
        from open_webui.routers.files import upload_file_handler

        messages = body.get("messages", [])
        prompt_text = messages[-1].get("content", "").strip() if messages else ""
        chat_id = body.get("chat_id")
        message_id = body.get("id")

        if not prompt_text:
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": "No message text to use as a video prompt.", "done": True}}
                )
            return

        # The messages array the action endpoint hands us doesn't carry each
        # message's "files" - it's a plain OpenAI-style {role, content} list.
        # Rebuild the real branch from the DB (which does keep files) by
        # walking parentId back from the clicked message, so get_source_image
        # can actually find an image generated earlier in the conversation.
        image_lookup_messages = messages
        if chat_id and message_id:
            try:
                messages_map = await Chats.get_messages_map_by_chat_id(chat_id)
            except Exception:
                messages_map = None
            if messages_map:
                ordered, seen, mid = [], set(), message_id
                while mid and mid in messages_map and mid not in seen:
                    seen.add(mid)
                    ordered.append(messages_map[mid])
                    mid = messages_map[mid].get("parentId")
                if ordered:
                    image_lookup_messages = list(reversed(ordered))

        try:
            source_image = await get_source_image(image_lookup_messages)
        except Exception:
            log.exception("Failed to read a source image, falling back to text-to-video")
            source_image = None

        if __event_emitter__:
            await __event_emitter__(
                {
                    "type": "status",
                    "data": {
                        "description": "Animating the attached image..." if source_image else "Queuing video generation...",
                        "done": False,
                    },
                }
            )

        client_id = str(random.randint(0, 2**31))

        try:
            async with aiohttp.ClientSession() as session:
                image_filename = None
                if source_image:
                    image_bytes, source_filename = source_image
                    image_filename = await upload_image_to_comfyui(session, image_bytes, source_filename)

                workflow = build_workflow(
                    prompt_text,
                    random.randint(0, 2**48),
                    self.valves.width,
                    self.valves.height,
                    self.valves.length,
                    self.valves.steps,
                    image_filename=image_filename,
                    image_strength=self.valves.image_strength,
                )

                prompt_id = await queue_prompt(session, workflow, client_id)

                if __event_emitter__:
                    await __event_emitter__(
                        {
                            "type": "status",
                            "data": {
                                "description": "Rendering video (checkpoint load + sampling, can take a few minutes)...",
                                "done": False,
                            },
                        }
                    )

                async def report_progress(description: str):
                    if __event_emitter__:
                        await __event_emitter__({"type": "status", "data": {"description": description, "done": False}})

                await wait_for_completion(session, client_id, prompt_id, status_callback=report_progress)
                video_bytes, filename = await get_output_file(session, prompt_id)
        except Exception as e:
            log.exception("Video generation failed")
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": f"Video generation failed: {e}", "done": True}}
                )
            return

        file = UploadFile(
            file=io.BytesIO(video_bytes),
            filename=filename,
            headers={"content-type": "video/webm"},
        )

        user = await Users.get_user_by_id(__user__["id"]) if __user__ else None

        file_item = await upload_file_handler(
            __request__,
            file=file,
            metadata={"chat_id": chat_id, "message_id": message_id},
            process=False,
            user=user,
        )

        if chat_id and message_id and file_item:
            await Chats.insert_chat_files(
                chat_id=chat_id,
                message_id=message_id,
                file_ids=[file_item.id],
                user_id=user.id,
            )

        if __event_emitter__:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Video ready.", "done": True}}
            )

        # Embed the video inline as a data URI rather than pointing at the
        # authenticated /api/v1/files/.../content URL: this iframe is
        # sandboxed without allow-same-origin (deliberately, for isolation),
        # which gives it an opaque origin - any request it makes to that URL
        # is cross-site, so the SameSite-restricted auth cookie never gets
        # sent and a bare <video src="..."> tag can't attach a Bearer header
        # either. The clips are small enough (tens of KB) that inlining them
        # is cheap, and it sidesteps the auth problem entirely rather than
        # working around it.
        video_b64 = base64.b64encode(video_bytes).decode("ascii")
        html = (
            f'<video controls autoplay muted loop '
            f'style="max-width:100%;max-height:280px" src="data:video/webm;base64,{video_b64}"></video>'
        )
        return HTMLResponse(content=html, headers={"Content-Disposition": "inline"})

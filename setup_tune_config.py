"""
Applies GPU-tier-based defaults to Open WebUI's image-generation config.

Run inside the openwebui container by install.sh, which passes the target values
as environment variables. install.sh picks those values from the amount of VRAM
it actually finds on the machine, so a 24GB card gets 1024x1024/40 steps and an
8GB one gets 512x512/20 - the difference between an image in ten seconds and an
out-of-memory error.

Without this step install.sh still *computes* those values and then throws them
away, which is exactly what it did before this file existed: shellcheck flagged
IMAGE_SIZE, IMAGE_STEPS and the four VIDEO_* variables as assigned-but-never-used,
and they were. The tiering looked implemented and did nothing.

The video valves at the end apply to an optional LTX-Video generation Action. A
stock install doesn't have it, and that is not an error - the update is skipped
with a note.
"""
import asyncio
import os

# Open WebUI refuses to import its own modules without this, and running
# python3 directly (rather than through start.sh) means nothing has set it.
# It's already on disk next to the app, so read it from there rather than
# making the caller pass a secret on the command line.
with open("/app/backend/.webui_secret_key") as f:
    os.environ["WEBUI_SECRET_KEY"] = f.read().strip()

from open_webui.models.config import Config
from open_webui.models.functions import Functions

IMAGE_SIZE = os.environ["IMAGE_SIZE"]
IMAGE_STEPS = int(os.environ["IMAGE_STEPS"])
VIDEO_WIDTH = int(os.environ["VIDEO_WIDTH"])
VIDEO_HEIGHT = int(os.environ["VIDEO_HEIGHT"])
VIDEO_LENGTH = int(os.environ["VIDEO_LENGTH"])
VIDEO_STEPS = int(os.environ["VIDEO_STEPS"])

VIDEO_ACTION_ID = "generate_video_ltx"


async def main():
    await Config.upsert(
        {
            "image_generation.size": IMAGE_SIZE,
            "image_generation.steps": IMAGE_STEPS,
        }
    )
    print(f"Image defaults applied: size={IMAGE_SIZE} steps={IMAGE_STEPS}")

    valves = {
        "width": VIDEO_WIDTH,
        "height": VIDEO_HEIGHT,
        "length": VIDEO_LENGTH,
        "steps": VIDEO_STEPS,
    }
    result = await Functions.update_function_valves_by_id(VIDEO_ACTION_ID, valves)
    if result:
        print(f"Video defaults applied: {valves}")
    else:
        print(
            f"No '{VIDEO_ACTION_ID}' action installed - skipping video defaults "
            "(this is normal for a stock install)."
        )


asyncio.run(main())

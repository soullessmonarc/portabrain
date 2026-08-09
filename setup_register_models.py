"""
Registers the currently-active chat/coder models in Open WebUI under a
chosen display name, with a neutral system prompt and image-generation
toggle support. Safe to re-run: creates the entry if missing, updates it
in place if it already exists. Run inside the openwebui container by
install.sh (or standalone - see the bottom of this file for the expected
environment variables).
"""
import asyncio
import os

with open("/app/backend/.webui_secret_key") as f:
    os.environ["WEBUI_SECRET_KEY"] = f.read().strip()

from open_webui.models.models import Models, ModelForm, ModelMeta, ModelParams
from open_webui.models.users import Users
from open_webui.models.config import Config

AGENT_NAME = os.environ.get("AGENT_NAME", "PortaBrain")
CHAT_MODEL = os.environ["CHAT_MODEL"]
CODER_MODEL = os.environ["CODER_MODEL"]

DEFAULT_SYSTEM_PROMPT = """You are {AGENT_NAME}, a private AI assistant running entirely on this device - no internet access, no data leaving this machine.

You cannot generate images or video yourself and have no tool or function call available for either - do not emit tool-call syntax, XML, or JSON trying to invoke "generate_image", "generate_video", or anything similar, since no such callable tool exists and it will simply fail. Both run through operator-controlled UI controls in this chat interface instead: the operator can turn on "Enable Image Generation" before sending a message to render an image from it, and can click the "Generate Video (LTX)" button beneath any of your replies to turn that reply's text into a short video clip - if an image was generated in that reply, or attached earlier in the chat, the button animates that image as the starting frame instead of generating from text alone. If asked whether you can generate an image or video, describe this in plain prose rather than flatly denying the capability exists or attempting to call it as a function.

Never claim to have generated, saved, or attached a file unless a tool actually returned a path. Never invent a URL or file path - you have no web access, so any link you write yourself is fabricated and broken. If you lack a capability, say so plainly."""

# A rig can supply its own prompt instead of editing this file. install.sh reads
# system_prompt.txt (next to it, or on the drive) and passes it in here, so a
# personalised rig stays a data file on that drive rather than a forked copy of
# this script that then misses every later fix made here.
#
# Substituted with .replace rather than .format so a custom prompt can contain
# braces (JSON examples, code) without needing them escaped - a trap that would
# otherwise only show up as a crash for whoever wrote the prompt.
_custom = os.environ.get("AGENT_SYSTEM_PROMPT", "").strip()
SYSTEM_PROMPT = (_custom or DEFAULT_SYSTEM_PROMPT).replace("{AGENT_NAME}", AGENT_NAME)
if _custom:
    print(f"using a custom system prompt ({len(_custom)} chars)")

CAPABILITIES = {
    "file_context": True,
    "vision": True,
    "file_upload": True,
    "web_search": True,
    "image_generation": True,
    "code_interpreter": True,
    "terminal": True,
    "citations": True,
    "status_updates": True,
    "memory": True,
    "builtin_tools": True,
}

# function_calling="legacy" (not just the builtin_tools flag above) is what
# actually routes the "Enable Image Generation" toggle to Open WebUI's
# deterministic direct handler instead of depending on the model correctly
# emitting a native generate_image tool call - small quantized 7B models'
# native tool-calling is unreliable enough that this matters in practice,
# not just in theory (see the main, non-template copy of this repo's own
# setup_register_models.py for the live debugging that found this).
FUNCTION_CALLING = "legacy"


async def upsert_model(model_id: str, display_name: str, admin_user_id: str):
    form = ModelForm(
        id=model_id,
        name=display_name,
        params=ModelParams(system=SYSTEM_PROMPT, function_calling=FUNCTION_CALLING),
        # actionIds is what actually surfaces the "Generate Video (LTX)" button
        # beneath a reply. Installing the Action itself is not enough - without
        # the model referencing it here, the Action exists in Admin Settings and
        # is simply never shown to the user.
        meta=ModelMeta(capabilities=CAPABILITIES, actionIds=["generate_video_ltx"]),
        access_grants=[],
        is_active=True,
    )
    existing = await Models.get_model_by_id(model_id)
    if existing:
        result = await Models.update_model_by_id(model_id, form)
        print(f"updated: {model_id} -> '{display_name}'" if result else f"FAILED to update: {model_id}")
    else:
        result = await Models.insert_new_model(form, admin_user_id)
        print(f"created: {model_id} -> '{display_name}'" if result else f"FAILED to create: {model_id}")


async def main():
    admin = await Users.get_super_admin_user()
    if not admin:
        print("No admin user found, cannot register models")
        return
    await upsert_model(CHAT_MODEL, AGENT_NAME, admin.id)
    await upsert_model(CODER_MODEL, f"{AGENT_NAME} (Coder)", admin.id)

    # Registering the model does not make it the DEFAULT for a new chat -
    # that is a separate setting (config key "ui.default_models") nothing here
    # ever touched. Confirmed live on the non-template copy of this rig: it
    # sat at None indefinitely, so every new chat needed the model picked by
    # hand despite it being correctly named and registered. Verified against
    # the actual router source (open_webui/routers/configs.py) rather than
    # guessed - DEFAULT_MODELS maps to "ui.default_models" and is a single
    # model id string, not a list.
    await Config.upsert({"ui.default_models": CHAT_MODEL})
    print(f"default model for new chats: {CHAT_MODEL}")


asyncio.run(main())

# Expected environment variables when run standalone (already set for you
# when install.sh calls this automatically):
#   AGENT_NAME  - display name you chose during install (defaults to "PortaBrain")
#   CHAT_MODEL  - the Ollama model tag used for chat, e.g. qwen2.5:7b-instruct-q4_K_M
#   CODER_MODEL - the Ollama model tag used for coding, e.g. qwen2.5-coder:7b-instruct-q4_K_M

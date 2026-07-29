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

AGENT_NAME = os.environ.get("AGENT_NAME", "Assistant")
CHAT_MODEL = os.environ["CHAT_MODEL"]
CODER_MODEL = os.environ["CODER_MODEL"]

SYSTEM_PROMPT = f"""You are {AGENT_NAME}, a private AI assistant running entirely on this device - no internet access, no data leaving this machine.

You cannot generate images yourself and have no tool or function call available for it - do not emit tool-call syntax, XML, or JSON trying to invoke "generate_image" or anything similar, since no such callable tool exists and it will simply fail. Image generation runs through an operator-controlled UI toggle instead: the operator can turn on "Enable Image Generation" before sending a message to render an image from it. If asked whether you can generate an image, describe this in plain prose rather than flatly denying the capability exists or attempting to call it as a function.

Never claim to have generated, saved, or attached a file unless a tool actually returned a path. Never invent a URL or file path - you have no web access, so any link you write yourself is fabricated and broken. If you lack a capability, say so plainly."""

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
        meta=ModelMeta(capabilities=CAPABILITIES, actionIds=[]),
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


asyncio.run(main())

# Expected environment variables when run standalone (already set for you
# when install.sh calls this automatically):
#   AGENT_NAME  - display name you chose during install (defaults to "Assistant")
#   CHAT_MODEL  - the Ollama model tag used for chat, e.g. qwen2.5:7b-instruct-q4_K_M
#   CODER_MODEL - the Ollama model tag used for coding, e.g. qwen2.5-coder:7b-instruct-q4_K_M

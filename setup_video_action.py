"""
Installs the "Generate Video (LTX)" Action into Open WebUI.

Run inside the openwebui container by install.sh. Safe to re-run: creates the
Action if it is missing, updates its source in place if it already exists.

This exists because Open WebUI has no supported way to install an Action from
disk - the UI expects you to paste Python into a web form. The non-template copy
of this project had a deploy script that could only *update* an Action that a
human had already created by hand ("ERROR: function does not exist, use the API
create endpoint first"), which meant video generation could never be part of an
automated install. The create path below is the missing half.

Expected environment variables (install.sh sets these for you):
  ACTION_SOURCE - path to the action's .py file inside the container
"""
import asyncio
import os
import sys

with open("/app/backend/.webui_secret_key") as f:
    os.environ["WEBUI_SECRET_KEY"] = f.read().strip()

from open_webui.models.functions import Functions, FunctionForm, FunctionMeta
from open_webui.models.users import Users

FUNCTION_ID = "generate_video_ltx"
FUNCTION_NAME = "Generate Video (LTX)"
FUNCTION_TYPE = "action"
DESCRIPTION = (
    "Generates a short video clip via ComfyUI's LTX-Video pipeline and attaches "
    "it to the chat. Animates the most recently attached image if there is one, "
    "otherwise generates from the message text."
)

ACTION_SOURCE = os.environ.get("ACTION_SOURCE", "/app/backend/video_gen_action.py")


async def main():
    if not os.path.exists(ACTION_SOURCE):
        print(f"ERROR: action source not found at {ACTION_SOURCE}")
        sys.exit(1)

    with open(ACTION_SOURCE) as f:
        content = f.read()

    admin = await Users.get_super_admin_user()
    if not admin:
        # Not fatal to the install as a whole - the stack still works, there is
        # just no video button until an admin account exists. Open WebUI creates
        # the admin on first visit, so a fresh rig legitimately hits this.
        print("No admin user yet - skipping video action install.")
        print("Create your admin account at http://localhost:8080, then re-run:")
        print("  docker exec -w /app/backend openwebui python3 setup_video_action.py")
        return

    meta = FunctionMeta(description=DESCRIPTION, manifest={})

    existing = await Functions.get_function_by_id(FUNCTION_ID)
    if existing:
        # update_function_by_id takes a dict of COLUMN VALUES, not a
        # FunctionForm - it does `.values(**updated)` internally. Passing a
        # pydantic model there raises, and the method swallows every exception
        # and returns None, so the mistake shows up as a bland "FAILED" with no
        # traceback. Verified by reading the installed implementation rather
        # than assuming, because the equivalent script in the non-template copy
        # of this project passes a form and is therefore broken.
        result = await Functions.update_function_by_id(
            FUNCTION_ID,
            {
                "name": FUNCTION_NAME,
                "content": content,
                "meta": meta.model_dump(),
                "type": FUNCTION_TYPE,
                # Actions are inert until active. Without this the Action exists
                # in Admin Settings and the button never appears, which looks
                # exactly like the install having done nothing at all.
                "is_active": True,
            },
        )
        print(f"updated: {FUNCTION_ID}" if result else f"FAILED to update {FUNCTION_ID}")
    else:
        form = FunctionForm(
            id=FUNCTION_ID, name=FUNCTION_NAME, content=content, meta=meta
        )
        result = await Functions.insert_new_function(admin.id, FUNCTION_TYPE, form)
        if result:
            # insert_new_function does not take is_active, so activate after.
            await Functions.update_function_by_id(FUNCTION_ID, {"is_active": True})
            print(f"created: {FUNCTION_ID}")
        else:
            print(f"FAILED to create {FUNCTION_ID}")

    final = await Functions.get_function_by_id(FUNCTION_ID)
    if final:
        print(f"  active={final.is_active} type={final.type} name='{final.name}'")
    else:
        print("  action is not present after install - check the errors above.")


asyncio.run(main())

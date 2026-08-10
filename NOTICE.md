# Third-Party Notices

This repository's own code is MIT-licensed (see [LICENSE](LICENSE)) - a handful of
installer scripts, not a bundled application. It does not ship, vendor, or redistribute
any of the software or model weights below. Running the installer directs *your own
machine* to download them from their original sources, at your own choice, under
*their* terms - the same as if you had typed the `docker pull` or `curl` command
yourself. Nothing here relicenses any of it, and nothing here is a substitute for
reading the actual license of anything you choose to download and use.

Where a license was checked directly against the upstream source while writing this
file, that's noted below. Where it wasn't, that's noted too, plainly, rather than
guessed at - check the linked source yourself before relying on the terms.

## Software

| Project | Role here | License | Checked? |
|---|---|---|---|
| [Ollama](https://github.com/ollama/ollama) | Serves the chat/coder LLMs | MIT | Verified against upstream `LICENSE` |
| [ComfyUI](https://github.com/comfyanonymous/ComfyUI) | Image/video generation engine | GPL-3.0 | Verified against upstream `LICENSE` |
| [`yanwk/comfyui-boot`](https://github.com/YanWenKun/ComfyUI-Docker) | Docker image this project pins for ComfyUI - bundles ComfyUI itself plus ComfyUI-Manager and its own launch tooling | Not independently verified for the wrapper/tooling itself - see the image's own repo | Not checked |
| [Open WebUI](https://github.com/open-webui/open-webui) | Chat frontend | **Modified BSD-3-Clause** - not plain BSD. It prohibits removing or altering "Open WebUI" branding *except* for deployments under 50 users in any 30-day period, or under a separate commercial agreement. If you deploy this to more than 50 people, that clause applies to you, not just this project's maintainer | Verified against upstream `LICENSE` |

## Model weights

None of these are hosted in this repo. `install.sh` downloads them, on request, from
the sources below - CivitAI checkpoints in particular carry real, legally meaningful
usage restrictions that go beyond this project's own MIT code.

| Weights | Source | License | Checked? |
|---|---|---|---|
| Chat/coder LLMs, standard variants (`qwen2.5*`) | [Qwen](https://huggingface.co/Qwen) via Ollama's registry | Apache 2.0 for the sizes this project uses (7B/14B) | Verified against upstream model card |
| Chat/coder LLMs, uncensored/abliterated variants (`huihui_ai/qwen2.5-abliterate*`, `huihui_ai/qwen3-abliterated*`) | [huihui_ai](https://huggingface.co/huihui-ai) via Ollama's registry | Base model license as above (Apache 2.0); the abliteration fine-tune itself is a separate derivative work, and this project has not independently verified whether huihui_ai attaches any additional terms | Base license only |
| Pony Diffusion V6 XL (SDXL checkpoint) | [CivitAI](https://civitai.com/models/257749) | **Fair AI Public License 1.0-SD** - explicitly **prohibits monetized inference** ("You are not permitted to run inference of this model on websites or applications allowing any form of monetization"), with a specific exception granted to CivitAI/Hugging Face's own hosted inference. This is a real legal restriction on commercial use, not just this project's own advisory one | Verified against the model page |
| Juggernaut XL v9 (SDXL checkpoint) | [CivitAI](https://civitai.com/models/133005) | CreativeML Open RAIL++-M plus the creator's own addendum, which as stated on the model page explicitly **permits commercial use and selling outputs**, and asks for (not requires) a credit. The full addendum text was not independently reviewed beyond the model page's own summary | Partially verified |
| LTX-Video (checkpoint + text encoder) | [Lightricks](https://huggingface.co/Lightricks/LTX-Video) | A **custom "LTX-Video Open Weights License"** specific to the model version - terms differ between versions and were not independently reviewed in full | Not fully checked |
| T5-XXL text encoder | [comfyanonymous/flux_text_encoders](https://huggingface.co/comfyanonymous/flux_text_encoders) | Repackaged Google T5 weights, typically Apache 2.0 upstream | Not independently checked for this specific repackaging |

**If you intend to use anything this stack generates for more than personal
curiosity** - and especially anything commercial - read the actual license of
whichever checkpoint produced it. Pony Diffusion V6 XL's restriction above is the
one most likely to matter and easiest to miss.

---

<sub><img src="docs/logo-icon.png" width="16" height="16" alt="PortaBrain icon" style="vertical-align:middle"> PortaBrain · soullessmonarcs · made with the help of AI</sub>

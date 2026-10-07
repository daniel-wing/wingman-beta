#!/usr/bin/env python3
"""Generates THIRD_PARTY_NOTICES.md from the resolved Swift packages.

License texts are copied verbatim from each package checkout, so rerun this
after updating dependencies:  python3 scripts/make-notices.py
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKOUTS = ROOT / ".build" / "checkouts"

# What each library is, its license and copyright holder (as stated in its license file).
LIBRARIES = {
    "fluidaudio": ("FluidAudio", "Speech recognition, voice detection and speaker separation runtime", "Apache-2.0", "Fluid Inference"),
    "whisperkit": ("WhisperKit", "Whisper speech recognition (language review after meetings)", "MIT", "argmax, inc."),
    "swift-transformers": ("swift-transformers", "Model downloading and tokenizers (WhisperKit dependency)", "Apache-2.0", "Hugging Face"),
    "swift-jinja": ("swift-jinja", "Template engine (swift-transformers dependency)", "Apache-2.0", "Hugging Face"),
    "yyjson": ("yyjson", "JSON parser (swift-transformers dependency)", "MIT", "YaoYuan"),
    "swift-argument-parser": ("Swift Argument Parser", "Command-line parsing (dependency)", "Apache-2.0", "Apple Inc. and the Swift project authors"),
    "swift-collections": ("Swift Collections", "Data structures (dependency)", "Apache-2.0", "Apple Inc. and the Swift project authors"),
    "swift-crypto": ("Swift Crypto", "Cryptography (dependency)", "Apache-2.0", "Apple Inc. and the SwiftCrypto project authors"),
    "swift-asn1": ("Swift ASN.1", "ASN.1 encoding (Swift Crypto dependency)", "Apache-2.0", "Apple Inc. and the SwiftASN1 project authors"),
    "sparkle": ("Sparkle", "Automatic updates (direct-download build)", "MIT", "Andy Matuschak and the Sparkle Project contributors"),
}

MODELS = """\
## AI models

Wingman downloads these models the first time they're needed and runs them on
this Mac. Core ML versions were converted by Fluid Inference and are modified
(converted, re-shaped and quantized) from the originals.

| Model | Used for | Original authors | License |
| --- | --- | --- | --- |
| [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) — [Core ML conversion](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | Speech recognition (live transcript) | moondream (based on NVIDIA Parakeet v3); conversion by Fluid Inference | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| [Whisper large-v3 turbo](https://github.com/openai/whisper) — [Core ML conversion](https://huggingface.co/argmaxinc/whisperkit-coreml) | Language review after each meeting | OpenAI; conversion by argmax | MIT |
| [Silero VAD](https://github.com/snakers4/silero-vad) — [Core ML conversion](https://huggingface.co/FluidInference/silero-vad-coreml) | Detecting when someone is speaking | Silero Team; conversion by Fluid Inference | MIT |
| [pyannote speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) — [Core ML conversion](https://huggingface.co/FluidInference/speaker-diarization-coreml) | Telling speakers apart (Them 1, Them 2…) | pyannote; WeSpeaker (speaker embedding); Brno University of Technology / BUT Speech@FIT (PLDA parameters); conversion by Fluid Inference | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — [Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | The model Parakeet Ultra is built on (also used by the developer's engine comparison tool, not included in the app) | NVIDIA; conversion by Fluid Inference | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Apple's on-device speech recognition and language detection are part of macOS.
"""


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").strip()


def license_file(package: pathlib.Path):
    for name in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"):
        if (package / name).exists():
            return package / name
    return None


def main() -> None:
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    # Notices copied from checkouts that aren't there would silently go missing.
    missing = [p["identity"] for p in pins
               if not (CHECKOUTS / p["location"].rstrip("/").removesuffix(".git").split("/")[-1]).is_dir()]
    if missing:
        raise SystemExit(f"Missing package checkouts ({', '.join(missing)}): run `swift build --disable-keychain` first.")
    out = [
        "# Third-party notices",
        "",
        "Wingman is proprietary software (see LICENSE). It is built with the open-source",
        "components and models below, used under their licenses. Thank you to everyone who made them.",
        "",
        MODELS,
        "## Software libraries",
        "",
        "| Library | Version | Used for | License | Copyright |",
        "| --- | --- | --- | --- | --- |",
    ]
    for pin in sorted(pins, key=lambda p: list(LIBRARIES).index(p["identity"]) if p["identity"] in LIBRARIES else 99):
        name, use, lic, holder = LIBRARIES.get(pin["identity"], (pin["identity"], "Dependency", "see below", ""))
        url = pin["location"].removesuffix(".git")
        out.append(f"| [{name}]({url}) | {pin['state'].get('version', '')} | {use} | {lic} | {holder} |")

    out += ["", "FluidAudio includes these third-party works:", ""]
    fluid = CHECKOUTS / "FluidAudio" / "ThirdPartyLicenses"
    bundled = sorted(fluid.glob("*")) if fluid.exists() else []
    for f in bundled:
        out.append(f"- {f.stem.replace('-LICENSE', '')} (full text below)")

    out += ["", "---", "", "# License texts", ""]

    # Apache-2.0 once, then each package's NOTICE file as Apache-2.0 §4(d) requires.
    apache = license_file(CHECKOUTS / "FluidAudio")
    out += ["## Apache License 2.0", "",
            "Applies to: " + ", ".join(LIBRARIES[p][0] for p in LIBRARIES if LIBRARIES[p][2] == "Apache-2.0") + ".", "",
            "```", read(apache) if apache else "https://www.apache.org/licenses/LICENSE-2.0", "```", ""]
    for pin in pins:
        package = CHECKOUTS / pin["location"].rstrip("/").removesuffix(".git").split("/")[-1]
        for notice in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
            if (package / notice).exists():
                name = LIBRARIES.get(pin["identity"], (pin["identity"],))[0]
                out += [f"## NOTICE — {name}", "", "```", read(package / notice), "```", ""]

    for identity in ("whisperkit", "yyjson", "sparkle"):
        package = CHECKOUTS / {"whisperkit": "WhisperKit", "yyjson": "yyjson", "sparkle": "Sparkle"}[identity]
        f = license_file(package)
        if f:
            out += [f"## MIT License — {LIBRARIES[identity][0]}", "", "```", read(f), "```", ""]

    for f in bundled:
        out += [f"## {f.stem.replace('-LICENSE', '')} (bundled in FluidAudio)", "", read(f), ""]

    out += ["## Creative Commons Attribution 4.0 International",
            "",
            "Full text: https://creativecommons.org/licenses/by/4.0/legalcode",
            ""]

    (ROOT / "THIRD_PARTY_NOTICES.md").write_text("\n".join(out), encoding="utf-8")
    print(f"Wrote THIRD_PARTY_NOTICES.md ({len(pins)} libraries, {len(bundled)} bundled notices)")


if __name__ == "__main__":
    main()

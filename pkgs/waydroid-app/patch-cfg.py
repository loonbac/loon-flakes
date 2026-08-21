# Asegura en /var/lib/waydroid/waydroid.cfg las props para que las apps
# salgan como ventanas de escritorio, sin el marco de Android.
from pathlib import Path

CFG = Path("/var/lib/waydroid/waydroid.cfg")
WANTED = {
    "persist.waydroid.multi_windows": "true",
    "qemu.hw.mainkeys": "1",
}


def main() -> None:
    if not CFG.is_file():
        return
    lines = CFG.read_text().splitlines()
    in_props = False
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_props:
                for key, val in WANTED.items():
                    if key not in seen:
                        out.append(f"{key} = {val}")
            in_props = stripped == "[properties]"
            out.append(line)
            continue
        if in_props:
            key = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
            if key in WANTED:
                out.append(f"{key} = {WANTED[key]}")
                seen.add(key)
                continue
        out.append(line)
    if in_props:
        for key, val in WANTED.items():
            if key not in seen:
                out.append(f"{key} = {val}")
    elif seen != set(WANTED):
        out.append("")
        out.append("[properties]")
        for key, val in WANTED.items():
            if key not in seen:
                out.append(f"{key} = {val}")
    text = "\n".join(out) + "\n"
    if text != CFG.read_text():
        CFG.write_text(text)


if __name__ == "__main__":
    main()

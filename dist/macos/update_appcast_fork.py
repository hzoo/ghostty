"""
Generate or update a Sparkle appcast for a fork-owned release flow.

Environment:
    PRODUCT_NAME
    PRODUCT_VERSION
    PRODUCT_BUILD
    PRODUCT_COMMIT
    PRODUCT_COMMIT_LONG
    PRODUCT_MINIMUM_SYSTEM_VERSION
    PRODUCT_REPOSITORY_URL
    PRODUCT_RELEASE_NOTES_URL_TEMPLATE
    PRODUCT_DOWNLOAD_URL

Optional environment:
    APPCAST_FILE          (default: appcast.xml)
    APPCAST_OUTPUT        (default: appcast.xml)
    APPCAST_MAX_ITEMS     (default: 15)
"""

from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

NAMESPACES = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
PUBDATE_FORMAT = "%a, %d %b %Y %H:%M:%S %z"

for prefix, uri in NAMESPACES.items():
    ET.register_namespace(prefix, uri)


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        raise KeyError(f"missing required environment variable: {name}")
    return value


def read_sign_update_attrs(path: Path) -> dict[str, str]:
    attrs: dict[str, str] = {}
    for pair in path.read_text().split(" "):
        key, value = pair.split("=", 1)
        value = value.strip()
        if value and value[0] == '"':
            value = value[1:-1]
        attrs[key] = value
    return attrs


def ensure_appcast(path: Path) -> ET.ElementTree:
    if path.exists():
        return ET.parse(path)

    rss = ET.Element("rss", version="2.0")
    rss.set("xmlns:sparkle", NAMESPACES["sparkle"])
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = env("PRODUCT_NAME")
    ET.SubElement(channel, "link").text = env("PRODUCT_REPOSITORY_URL")
    ET.SubElement(channel, "description").text = f"{env('PRODUCT_NAME')} updates"
    return ET.ElementTree(rss)


def main() -> None:
    now = datetime.now(timezone.utc)
    product_name = env("PRODUCT_NAME")
    version = env("PRODUCT_VERSION")
    version_dash = version.replace(".", "-")
    build = env("PRODUCT_BUILD")
    commit = env("PRODUCT_COMMIT")
    commit_long = env("PRODUCT_COMMIT_LONG")
    minimum_system_version = env("PRODUCT_MINIMUM_SYSTEM_VERSION", "13.0.0")
    repo = env("PRODUCT_REPOSITORY_URL")
    release_notes_template = env("PRODUCT_RELEASE_NOTES_URL_TEMPLATE")
    download_url = env("PRODUCT_DOWNLOAD_URL")

    appcast_path = Path(env("APPCAST_FILE", "appcast.xml"))
    output_path = Path(env("APPCAST_OUTPUT", "appcast.xml"))
    prune_amount = int(env("APPCAST_MAX_ITEMS", "15"))

    attrs = read_sign_update_attrs(Path("sign_update.txt"))
    tree = ensure_appcast(appcast_path)
    channel = tree.find("channel")
    if channel is None:
        raise RuntimeError("appcast channel not found")

    release_notes_url = (
        release_notes_template.replace("{version}", version).replace("{version-dash}", version_dash)
    )

    for item in list(channel.findall("item")):
        sparkle_version = item.find("sparkle:version", NAMESPACES)
        if sparkle_version is not None and sparkle_version.text == build:
            channel.remove(item)
            continue
        if item.find("pubDate") is None:
            channel.remove(item)

    items = channel.findall("item")
    items.sort(key=lambda item: datetime.strptime(item.find("pubDate").text, PUBDATE_FORMAT))
    if len(items) > prune_amount:
        for item in items[:-prune_amount]:
            channel.remove(item)

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"{product_name} {version}"
    ET.SubElement(item, "pubDate").text = now.strftime(PUBDATE_FORMAT)
    ET.SubElement(item, "sparkle:version").text = build
    ET.SubElement(item, "sparkle:shortVersionString").text = version
    ET.SubElement(item, "sparkle:minimumSystemVersion").text = minimum_system_version
    ET.SubElement(item, "sparkle:fullReleaseNotesLink").text = release_notes_url
    ET.SubElement(item, "description").text = f"""
<h1>{product_name} v{version}</h1>
<p>
This release was built from commit <code><a href="{repo}/commit/{commit_long}">{commit}</a></code>
on {now.strftime('%Y-%m-%d')}.
</p>
<p>
View release notes at <a href="{release_notes_url}">{release_notes_url}</a>.
</p>
"""

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", download_url)
    enclosure.set("type", "application/octet-stream")
    for key, value in attrs.items():
        enclosure.set(key, value)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(output_path, xml_declaration=True, encoding="utf-8")


if __name__ == "__main__":
    main()

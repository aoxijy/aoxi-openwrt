#!/usr/bin/env python3
"""Safely validate and optionally extract an J-Box tar archive."""

from pathlib import Path, PurePosixPath
import posixpath
import sys
import tarfile


def reject(message: str) -> None:
    raise ValueError(message)


def safe_member_path(name: str) -> str:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        reject(f"危险归档路径: {name}")
    normalized = posixpath.normpath(name)
    if normalized in ("", "."):
        return normalized
    if normalized == ".." or normalized.startswith("../"):
        reject(f"越界归档路径: {name}")
    return normalized


def validate_members(members: list[tarfile.TarInfo]) -> None:
    for member in members:
        member_name = safe_member_path(member.name)
        if member.isdev() or member.isfifo():
            reject(f"归档包含设备或 FIFO: {member.name}")
        if member.issym() or member.islnk():
            if PurePosixPath(member.linkname).is_absolute():
                reject(f"归档包含绝对链接: {member.name} -> {member.linkname}")
            base = posixpath.dirname(member_name) if member.issym() else ""
            resolved = posixpath.normpath(posixpath.join(base, member.linkname))
            if resolved == ".." or resolved.startswith("../"):
                reject(f"归档链接越界: {member.name} -> {member.linkname}")


def main() -> int:
    if len(sys.argv) == 2:
        archive, destination = sys.argv[1], None
    elif len(sys.argv) == 4 and sys.argv[1] == "--extract":
        destination, archive = sys.argv[2], sys.argv[3]
    else:
        print(f"用法: {sys.argv[0]} [--extract <目录>] <archive.tar.gz>", file=sys.stderr)
        return 2

    try:
        with tarfile.open(archive, "r:gz") as bundle:
            members = bundle.getmembers()
            validate_members(members)
            if destination is not None:
                Path(destination).mkdir(parents=True, exist_ok=True)
                # Validation and extraction use the same parser and member list.
                bundle.extractall(path=destination, members=members)
    except (OSError, tarfile.TarError, ValueError) as exc:
        print(f"J-Box 归档安全校验失败: {exc}", file=sys.stderr)
        return 1

    print("J-Box 归档路径校验通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

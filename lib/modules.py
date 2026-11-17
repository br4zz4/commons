#!/usr/bin/env python3
import json
import os
import re
import sys

NAME = re.compile(r"^[a-z][a-z0-9_]*$")


def fail(message):
    print("commons: " + message, file=sys.stderr)
    sys.exit(1)


def load(root):
    path = os.path.join(root, ".github", "modules.json")
    if not os.path.isfile(path):
        fail("sem .github/modules.json")
    try:
        with open(path) as handle:
            data = json.load(handle)
    except ValueError as error:
        fail("modules.json inválido: %s" % error)
    modules = data.get("modules")
    if not isinstance(modules, dict) or not modules:
        fail("modules.json sem modules")
    for name in modules:
        if not NAME.match(name):
            fail("módulo %s fora de [a-z][a-z0-9_]*" % name)
    return modules


def module(modules, name):
    if name not in modules:
        fail("módulo %s desconhecido" % name)
    return modules[name] or {}


def side_dir(modules, name, side):
    if side not in ("code", "infra"):
        fail("lado %s inválido" % side)
    entry = module(modules, name)
    custom = (entry.get(side) or {}).get("dir")
    return custom or "modules/%s/%s" % (name, side)


def main(argv):
    if len(argv) < 3:
        fail("uso: modules.py <root> list|dir|services ...")
    root, command, args = argv[1], argv[2], argv[3:]
    modules = load(root)
    if command == "list":
        for name in sorted(modules):
            print(name)
    elif command == "dir" and len(args) == 2:
        print(side_dir(modules, args[0], args[1]))
    elif command == "services" and len(args) == 1:
        for service in module(modules, args[0]).get("services", []):
            print(service)
    else:
        fail("uso: modules.py <root> list|dir <m> <side>|services <m>")


if __name__ == "__main__":
    main(sys.argv)

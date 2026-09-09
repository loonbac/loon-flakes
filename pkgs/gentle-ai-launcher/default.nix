{ writeShellApplication
, nodejs
}:

writeShellApplication {
  name = "gentle-ai";
  runtimeInputs = [ nodejs ];

  text = ''
    agent_dir="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    package_root="$agent_dir/npm/node_modules/gentle-pi"
    resolver="$package_root/runtime/gentle-ai-binary.mjs"

    if [ ! -f "$resolver" ]; then
      echo "gentle-ai: gentle-pi is not installed in $agent_dir" >&2
      echo "Run: pi install npm:gentle-pi" >&2
      exit 1
    fi

    binary="$(${nodejs}/bin/node --input-type=module - "$package_root" <<'NODE'
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const packageRoot = process.argv[2];
const moduleUrl = pathToFileURL(join(packageRoot, "runtime", "gentle-ai-binary.mjs"));
const { resolveGentleAiBinary } = await import(moduleUrl.href);
process.stdout.write(resolveGentleAiBinary(packageRoot));
NODE
    )"

    exec "$binary" "$@"
  '';
}

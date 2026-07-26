import { parseArgs } from "node:util";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { releaseUrl, resolveZignapiSources, runZig, errMessage } from "./zig.js";

// The template tree lives at the package root (as `templates/`), so it resolves
// the same whether we run from the compiled `dist/` or the source `src/`.
const TEMPLATES_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "templates",
);
const PLACEHOLDER = /__NAME__/g;

const NEW_HELP = `zignapi new — scaffold a new addon project

Usage:
  zignapi new <name> [--local]

Creates ./<name> from the built-in template, substituting the project name,
then wires up the zignapi Zig dependency with "zig fetch --save" (pinned by
content hash). By default it fetches the hosted release tarball, so the project
is portable across machines/CI; if that's unreachable it falls back to the Zig
sources shipped alongside the CLI (only present in a monorepo checkout — they
are not published to npm).

Options:
  --local     Use the local Zig sources (monorepo checkout) instead of the
              hosted release
  -h, --help  Show this help

<name> must be a valid Zig identifier (letters, digits, underscore; not
starting with a digit).
`;

export async function runNew(argv: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      local: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });

  if (values.help || positionals.length === 0) {
    process.stdout.write(NEW_HELP);
    return;
  }

  const name = positionals[0];
  validateName(name);

  const target = join(process.cwd(), name);
  if (existsSync(target)) {
    throw new Error(`directory '${name}' already exists`);
  }

  copyTemplate(TEMPLATES_DIR, target, name);
  addZignapiDependency(target, { local: values.local ?? false });

  process.stdout.write(
    `✔ created ${name}/\n\n` +
      `Next steps:\n` +
      `  cd ${name}\n` +
      `  zignapi build      # produces ${name}.node\n` +
      `  node --test\n`,
  );
}

/**
 * Add the `zignapi` Zig dependency to the freshly scaffolded project via
 * `zig fetch --save`, pinning it by content hash. Prefers the hosted release
 * tarball (portable across machines) and falls back to the Zig sources bundled
 * with the CLI if that's unreachable or `local` is set. Non-fatal: if Zig isn't
 * available at all, tell the user how to finish the wiring later.
 */
function addZignapiDependency(target: string, { local }: { local: boolean }): void {
  const repairZon = join(target, "build.zig.zon");

  if (!local) {
    const url = releaseUrl();
    try {
      runZig(target, ["fetch", "--save=zignapi", url], { repairZon });
      process.stdout.write(`✔ added zignapi dependency from ${url}\n`);
      return;
    } catch (err) {
      process.stderr.write(
        `note: could not fetch the hosted zignapi release (${errMessage(err)}); ` +
          `falling back to the bundled sources.\n`,
      );
    }
  }

  let sources: string | undefined;
  try {
    sources = resolveZignapiSources();
    runZig(target, ["fetch", "--save=zignapi", sources], { repairZon });
    process.stdout.write("✔ added zignapi dependency from bundled sources\n");
  } catch (err) {
    process.stderr.write(
      `warning: could not add the zignapi dependency automatically ` +
        `(${errMessage(err)}).\nRun this inside the project once Zig 0.16.0 is ` +
        `available:\n  zig fetch --save=zignapi ${sources ?? releaseUrl()}\n`,
    );
  }
}

/**
 * Recursively copy the template tree, substituting the project name in both
 * file contents and file/directory names. `dot-` prefixed template names are
 * emitted as dotfiles (so e.g. `dot-gitignore` becomes `.gitignore`), which
 * also sidesteps npm's habit of renaming a packaged `.gitignore`.
 */
function copyTemplate(srcDir: string, destDir: string, name: string): void {
  mkdirSync(destDir, { recursive: true });
  for (const entry of readdirSync(srcDir, { withFileTypes: true })) {
    const outName = entry.name.replace(PLACEHOLDER, name).replace(/^dot-/, ".");
    const src = join(srcDir, entry.name);
    const dest = join(destDir, outName);
    if (entry.isDirectory()) {
      copyTemplate(src, dest, name);
    } else {
      const content = readFileSync(src, "utf8").replace(PLACEHOLDER, name);
      writeFileSync(dest, content);
    }
  }
}

function validateName(name: string): void {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    throw new Error(
      `invalid project name '${name}' (use letters, digits and underscores; ` +
        `must not start with a digit)`,
    );
  }
}
